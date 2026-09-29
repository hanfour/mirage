import CryptoKit
import Darwin
import Foundation

public enum PackageInstallerError: Error, Equatable, LocalizedError, Sendable {
    case downloadFailed(String)
    case httpStatus(Int)
    case insufficientSpace(path: String, required: Int64, available: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case sha1Mismatch(expected: String, actual: String)
    case extractionTimedOut(seconds: Int)
    case extractionFailed(String)
    case invalidArchiveContents([String])
    case installationFailed(String)
    case rollbackFailed(installation: String, restoration: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail): "下載失敗：\(detail)"
        case .httpStatus(let status): "下載伺服器回傳 HTTP \(status)"
        case .insufficientSpace(let path, let required, let available):
            "\(path) 可用空間 \(available) bytes，安裝需要 \(required) bytes"
        case .sizeMismatch(let expected, let actual):
            "下載檔案大小為 \(actual) bytes，預期 \(expected) bytes"
        case .sha1Mismatch(let expected, let actual):
            "下載檔案 SHA-1 為 \(actual)，預期 \(expected)"
        case .extractionTimedOut(let seconds): "ditto 解壓超過 \(seconds) 秒"
        case .extractionFailed(let detail): "ditto 解壓失敗：\(detail)"
        case .invalidArchiveContents(let entries):
            "壓縮檔最上層必須恰好有一個目錄，實際項目：\(entries.joined(separator: ", "))"
        case .installationFailed(let detail): "套件就位失敗：\(detail)"
        case .rollbackFailed(let installation, let restoration):
            "套件就位失敗：\(installation)；還原舊版本也失敗：\(restoration)"
        }
    }
}

public struct PackageInstaller: Sendable {
    private let sdkRoot: URL
    private let downloadsDirectory: URL
    private let dittoExecutable: URL
    private let dittoTimeoutSeconds: TimeInterval

    public init(
        sdkRoot: URL,
        downloadsDirectory: URL,
        dittoExecutable: URL = URL(fileURLWithPath: "/usr/bin/ditto"),
        dittoTimeoutSeconds: TimeInterval = 1_800
    ) {
        self.sdkRoot = sdkRoot
        self.downloadsDirectory = downloadsDirectory
        self.dittoExecutable = dittoExecutable
        self.dittoTimeoutSeconds = dittoTimeoutSeconds
    }

    public func install(
        _ package: SdkPackageSpec,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws {
        let fileManager = FileManager.default
        let zipURL = downloadsDirectory.appendingPathComponent(package.url.lastPathComponent + ".part")
        let installURL = sdkRoot.appendingPathComponent(package.installPath, isDirectory: true)
        let installParent = installURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: zipURL.path) { try fileManager.removeItem(at: zipURL) }

        var stagingDirectory: URL?
        defer {
            if let stagingDirectory, fileManager.fileExists(atPath: stagingDirectory.path) {
                try? fileManager.removeItem(at: stagingDirectory)
            }
            if fileManager.fileExists(atPath: zipURL.path) { try? fileManager.removeItem(at: zipURL) }
        }

        try fileManager.createDirectory(at: installParent, withIntermediateDirectories: true)
        try Task.checkCancellation()
        let requiredSpace = SetupSpace.required(forPackageSize: package.size)
        for directory in [downloadsDirectory, installParent] {
            let availableSpace = try availableCapacity(at: directory)
            guard availableSpace >= requiredSpace else {
                throw PackageInstallerError.insufficientSpace(
                    path: directory.path, required: requiredSpace, available: availableSpace)
            }
        }

        let downloader = URLSessionPackageDownload(url: package.url, destination: zipURL, progress: progress)
        do {
            try await downloader.run()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PackageInstallerError {
            throw error
        } catch {
            throw PackageInstallerError.downloadFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let actualSize = try fileSize(at: zipURL)
        guard actualSize == package.size else {
            throw PackageInstallerError.sizeMismatch(expected: package.size, actual: actualSize)
        }
        let actualSHA1 = try sha1(at: zipURL)
        guard actualSHA1.caseInsensitiveCompare(package.sha1) == .orderedSame else {
            throw PackageInstallerError.sha1Mismatch(expected: package.sha1, actual: actualSHA1)
        }

        let extractionDirectory = installParent.appendingPathComponent(
            ".mirage-install-\(UUID().uuidString)", isDirectory: true)
        stagingDirectory = extractionDirectory
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: false)
        try extract(zipURL, into: extractionDirectory)
        try Task.checkCancellation()
        let entries = try fileManager.contentsOfDirectory(
            at: extractionDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        guard entries.count == 1, isDirectory(entries[0]) else {
            throw PackageInstallerError.invalidArchiveContents(entries.map(\.lastPathComponent))
        }

        try installDirectory(entries[0], at: installURL)
        try writeProvenance(package)
    }

    private func availableCapacity(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw PackageInstallerError.downloadFailed("無法讀取下載檔案大小")
        }
        return size.int64Value
    }

    private func sha1(at url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = Insecure.SHA1()
        while true {
            let chunk = try file.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func extract(_ zip: URL, into directory: URL) throws {
        let fileManager = FileManager.default
        let errorLog = directory.deletingLastPathComponent()
            .appendingPathComponent(".mirage-ditto-\(UUID().uuidString).log")
        try Data().write(to: errorLog, options: .atomic)
        defer { try? fileManager.removeItem(at: errorLog) }
        let errorOutput = try FileHandle(forWritingTo: errorLog)
        let process = Process()
        process.executableURL = dittoExecutable
        process.arguments = ["-x", "-k", zip.path, directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput
        do {
            try process.run()
        } catch {
            try? errorOutput.close()
            throw PackageInstallerError.extractionFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(dittoTimeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? errorOutput.close()
            throw PackageInstallerError.extractionTimedOut(seconds: Int(dittoTimeoutSeconds))
        }

        process.waitUntilExit()
        try? errorOutput.close()
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errorLog, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.flatMap { $0.isEmpty ? nil : $0 }
                ?? "ditto 結束碼 \(process.terminationStatus)"
            throw PackageInstallerError.extractionFailed(
                message)
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func installDirectory(_ staged: URL, at installURL: URL) throws {
        let fileManager = FileManager.default
        let backupURL = URL(fileURLWithPath: installURL.path + ".mirage-old", isDirectory: true)
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }

        var movedOldInstall = false
        if fileManager.fileExists(atPath: installURL.path) {
            do {
                try fileManager.moveItem(at: installURL, to: backupURL)
                movedOldInstall = true
            } catch {
                throw PackageInstallerError.installationFailed(error.localizedDescription)
            }
        }

        do {
            try fileManager.moveItem(at: staged, to: installURL)
        } catch {
            let installationError = error.localizedDescription
            guard movedOldInstall else {
                throw PackageInstallerError.installationFailed(installationError)
            }
            do {
                try fileManager.moveItem(at: backupURL, to: installURL)
            } catch {
                throw PackageInstallerError.rollbackFailed(
                    installation: installationError,
                    restoration: error.localizedDescription)
            }
            throw PackageInstallerError.installationFailed(installationError)
        }

        if movedOldInstall {
            do {
                try fileManager.removeItem(at: backupURL)
            } catch {
                let installationError = error.localizedDescription
                do {
                    try fileManager.moveItem(at: installURL, to: staged)
                    try fileManager.moveItem(at: backupURL, to: installURL)
                } catch {
                    throw PackageInstallerError.rollbackFailed(
                        installation: installationError, restoration: error.localizedDescription)
                }
                throw PackageInstallerError.installationFailed(installationError)
            }
        }
    }

    private func writeProvenance(_ package: SdkPackageSpec) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sdkRoot, withIntermediateDirectories: true)
        let recordURL = sdkRoot.appendingPathComponent(".mirage-provision.json", isDirectory: false)
        var records: [String: String] = [:]
        if let data = try? Data(contentsOf: recordURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            records = decoded
        }
        records[package.installPath] = package.revision
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(records)
        data.append(0x0A)
        try data.write(to: recordURL, options: .atomic)
    }
}

private final class URLSessionPackageDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private var isFinished = false

    init(url: URL, destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.progress = progress
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                begin(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func begin(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: destination)
        continuation?.resume(throwing: CancellationError())
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let shouldReport = !isFinished
        lock.unlock()
        if shouldReport { progress(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let moveError = self.moveError
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let hasDownloadedFile = FileManager.default.fileExists(atPath: destination.path)
        let downloadSession = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        downloadSession?.finishTasksAndInvalidate()

        let result: Result<Void, Error>
        if let error {
            if (error as? URLError)?.code == .cancelled {
                result = .failure(CancellationError())
            } else {
                result = .failure(PackageInstallerError.downloadFailed(error.localizedDescription))
            }
        } else if let status, !(200..<300).contains(status) {
            result = .failure(PackageInstallerError.httpStatus(status))
        } else if status == nil {
            result = .failure(PackageInstallerError.downloadFailed("HTTP 回應缺少狀態碼"))
        } else if let moveError {
            result = .failure(PackageInstallerError.downloadFailed(moveError.localizedDescription))
        } else if !hasDownloadedFile {
            result = .failure(PackageInstallerError.downloadFailed("URLSession 沒有提供下載檔案"))
        } else {
            result = .success(())
        }

        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        continuation?.resume(with: result)
    }
}
