import CryptoKit
import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
@testable import MirageCore

@Suite("PackageInstaller")
struct PackageInstallerTests {
    @Test func downloadsVerifiesInstallsRecordsAndPreservesExecutableMode() async throws {
        let temporary = try TestDirectory()
        let archive = try ZipFixture.create(
            under: temporary.url,
            files: ["package-root/bin/adb": Data("#!/bin/sh\nexit 0\n".utf8)],
            executablePaths: ["package-root/bin/adb"],
            zipEntries: ["package-root"])
        let server = try LocalPackageHTTPServer(body: archive.bytes)
        defer { try? server.stop() }
        let roots = try InstallRoots(under: temporary.url)
        let package = makePackage(url: server.url, installPath: "platform-tools", archive: archive.bytes)
        let progress = ProgressLog()
        let existingRecords = roots.sdk.appendingPathComponent(".mirage-provision.json")
        try Data("{\"emulator\":\"37.1.11\"}".utf8).write(to: existingRecords)

        try await roots.installer.install(package) { written, expected in
            progress.record(written: written, expected: expected)
        }

        let installedTool = roots.sdk.appendingPathComponent("platform-tools/bin/adb")
        let attributes = try FileManager.default.attributesOfItem(atPath: installedTool.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((mode & 0o111) != 0)
        #expect(progress.count > 0)
        #expect(!FileManager.default.fileExists(
            atPath: roots.downloads.appendingPathComponent("payload.zip.part").path))
        let recordsURL = roots.sdk.appendingPathComponent(".mirage-provision.json")
        let records = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: recordsURL))
        #expect(records[package.installPath] == package.revision)
        #expect(records["emulator"] == "37.1.11")
    }

    @Test func sha1MismatchDeletesPartAndLeavesInstallUntouched() async throws {
        let temporary = try TestDirectory()
        let archive = try ZipFixture.create(
            under: temporary.url,
            files: ["package-root/file": Data("contents".utf8)],
            executablePaths: [],
            zipEntries: ["package-root"])
        let server = try LocalPackageHTTPServer(body: archive.bytes)
        defer { try? server.stop() }
        let roots = try InstallRoots(under: temporary.url)
        let package = makePackage(url: server.url, installPath: "sample", archive: archive.bytes,
                                  sha1: String(repeating: "0", count: 40))
        let marker = try roots.makeExistingInstall("sample")

        var observedError: PackageInstallerError?
        do {
            try await roots.installer.install(package)
        } catch let error as PackageInstallerError {
            observedError = error
        } catch {
            Issue.record("收到非預期錯誤：\(error)")
        }

        #expect(observedError == .sha1Mismatch(expected: package.sha1, actual: sha1(archive.bytes)))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "previous install")
        #expect(!FileManager.default.fileExists(
            atPath: roots.downloads.appendingPathComponent("payload.zip.part").path))
    }

    @Test func rejectsArchivesWithMultipleTopLevelEntries() async throws {
        let temporary = try TestDirectory()
        let archive = try ZipFixture.create(
            under: temporary.url,
            files: ["first/one": Data([1]), "second/two": Data([2])],
            executablePaths: [],
            zipEntries: ["first", "second"])
        let server = try LocalPackageHTTPServer(body: archive.bytes)
        defer { try? server.stop() }
        let roots = try InstallRoots(under: temporary.url)
        let package = makePackage(url: server.url, installPath: "sample", archive: archive.bytes)
        let marker = try roots.makeExistingInstall("sample")

        var observedEntries: [String]?
        do {
            try await roots.installer.install(package)
        } catch PackageInstallerError.invalidArchiveContents(let entries) {
            observedEntries = entries
        } catch {
            Issue.record("收到非預期錯誤：\(error)")
        }

        #expect(observedEntries?.count == 2)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "previous install")
    }

    @Test func extractionFailureKeepsThePreviousInstallInPlace() async throws {
        let temporary = try TestDirectory()
        let archive = try ZipFixture.create(
            under: temporary.url,
            files: ["package-root/file": Data("new version".utf8)],
            executablePaths: [],
            zipEntries: ["package-root"])
        let server = try LocalPackageHTTPServer(body: archive.bytes)
        defer { try? server.stop() }
        let roots = try InstallRoots(under: temporary.url)
        let failingDitto = try ZipFixture.failingExtractor(under: temporary.url)
        let installer = PackageInstaller(
            sdkRoot: roots.sdk,
            downloadsDirectory: roots.downloads,
            dittoExecutable: failingDitto)
        let package = makePackage(url: server.url, installPath: "sample", archive: archive.bytes)
        let marker = try roots.makeExistingInstall("sample")

        var extractionFailed = false
        do {
            try await installer.install(package)
        } catch PackageInstallerError.extractionFailed(_) {
            extractionFailed = true
        } catch {
            Issue.record("收到非預期錯誤：\(error)")
        }

        #expect(extractionFailed)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "previous install")
    }

    @Test func cancellationStopsDittoAndPreservesThePreviousInstall() async throws {
        let temporary = try TestDirectory()
        let archive = try ZipFixture.create(
            under: temporary.url,
            files: ["package-root/file": Data("new version".utf8)],
            executablePaths: [],
            zipEntries: ["package-root"])
        let server = try LocalPackageHTTPServer(body: archive.bytes)
        defer { try? server.stop() }
        let roots = try InstallRoots(under: temporary.url)
        let pidFile = temporary.url.appendingPathComponent("ditto.pid")
        let sleepingDitto = try ZipFixture.sleepingExtractor(under: temporary.url, pidFile: pidFile)
        let installer = PackageInstaller(
            sdkRoot: roots.sdk,
            downloadsDirectory: roots.downloads,
            dittoExecutable: sleepingDitto)
        let package = makePackage(url: server.url, installPath: "sample", archive: archive.bytes)
        let marker = try roots.makeExistingInstall("sample")
        let installation = Task { try await installer.install(package) }
        defer { installation.cancel() }

        let foundProcessID = await processID(from: pidFile, timeout: .seconds(5))
        let processID = try #require(foundProcessID)
        #expect(processIsRunning(processID))
        let cancelledAt = ContinuousClock.now
        installation.cancel()
        let outcome = await awaitWithWatchdog(.seconds(3)) {
            do {
                try await installation.value
                return InstallerTaskOutcome.succeeded
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        #expect(outcome == .finished(.cancelled))
        #expect(cancelledAt.duration(to: .now) < .seconds(3))
        #expect(!processIsRunning(processID))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "previous install")
        #expect(!FileManager.default.fileExists(
            atPath: roots.downloads.appendingPathComponent("payload.zip.part").path))
    }
}

private enum InstallerTaskOutcome: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

private struct ArchiveData {
    let url: URL
    let bytes: Data
}

private enum ZipFixture {
    static func create(
        under root: URL,
        files: [String: Data],
        executablePaths: Set<String>,
        zipEntries: [String]
    ) throws -> ArchiveData {
        let source = root.appendingPathComponent("zip-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            let file = source.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file)
            if executablePaths.contains(relativePath) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }

        let zip = root.appendingPathComponent("payload.zip", isDirectory: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", zip.path] + zipEntries
        process.currentDirectoryURL = source
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ZipFixtureError.zipFailed }
        return ArchiveData(url: zip, bytes: try Data(contentsOf: zip))
    }

    static func failingExtractor(under root: URL) throws -> URL {
        let script = root.appendingPathComponent("failing-ditto")
        try Data("#!/bin/sh\nexit 17\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    static func sleepingExtractor(under root: URL, pidFile: URL) throws -> URL {
        let escapedPath = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = root.appendingPathComponent("sleeping-ditto")
        let body = "#!/bin/sh\nprintf '%s\\n' \"$$\" > '\(escapedPath)'\nexec /bin/sleep 30\n"
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private enum ZipFixtureError: Error {
    case zipFailed
}

private struct InstallRoots {
    let sdk: URL
    let downloads: URL
    let installer: PackageInstaller

    init(under root: URL) throws {
        sdk = root.appendingPathComponent("sdk", isDirectory: true)
        downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        installer = PackageInstaller(sdkRoot: sdk, downloadsDirectory: downloads)
    }

    func makeExistingInstall(_ path: String) throws -> URL {
        let directory = sdk.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("marker.txt")
        try Data("previous install".utf8).write(to: marker)
        return marker
    }
}

private final class TestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }

    func record(written: Int64, expected: Int64) {
        lock.lock(); defer { lock.unlock() }
        writes += 1
    }
}

private final class LocalPackageHTTPServer {
    private let channel: any Channel
    let url: URL

    init(body: Data) throws {
        let channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(FixedPackageResponseHandler(body: body))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        guard let port = channel.localAddress?.port,
              let url = URL(string: "http://127.0.0.1:\(port)/payload.zip")
        else { throw LocalServerError.noAddress }
        self.channel = channel
        self.url = url
    }

    func stop() throws { try channel.close().wait() }
}

private enum LocalServerError: Error {
    case noAddress
}

private final class FixedPackageResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let body: Data

    init(body: Data) { self.body = body }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(_):
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: String(body.count))
            headers.add(name: "Connection", value: "close")
            let response = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        case .body(_), .end(_):
            return
        }
    }
}

private func makePackage(
    url: URL,
    installPath: String,
    archive: Data,
    sha1 expectedSHA1: String? = nil
) -> SdkPackageSpec {
    SdkPackageSpec(
        manifestKey: "repo",
        path: "test-package",
        channel: "stable",
        revision: "1.0",
        sha1: expectedSHA1 ?? sha1(archive),
        size: Int64(archive.count),
        installPath: installPath,
        url: url)
}

private func sha1(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func processID(from file: URL, timeout: Duration) async -> Int32? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let contents = try? String(contentsOf: file, encoding: .utf8),
           let processID = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return processID
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

private func processIsRunning(_ processID: Int32) -> Bool {
    Darwin.kill(processID, 0) == 0 || errno == EPERM
}
