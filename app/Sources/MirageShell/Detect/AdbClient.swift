import Darwin
import Foundation
import MirageCore

/// adb 子行程薄封裝：抽出共用 `run`（並發排空 pipe 避免大輸出死鎖、逾時砍行程），
/// dumpsys 前景偵測與 APK 安裝各自轉換結果。非 @MainActor（純執行）。
struct AdbClient: Sendable {
    let adbPath: URL
    let serial: String
    typealias Runner = @Sendable (URL, [String], Duration, Bool) async -> (exit: Int32, stdout: String)?
    private let runner: Runner?

    init(adbPath: URL, serial: String, runner: Runner? = nil) {
        self.adbPath = adbPath
        self.serial = serial
        self.runner = runner
    }

    /// 由 ANDROID_SDK_ROOT/ANDROID_HOME 推導 adb；serial 預設 emulator-5554。
    static func standard(
        serial: String = "emulator-5554",
        environment env: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AdbClient? {
        let sdk = env["ANDROID_SDK_ROOT"] ?? env["ANDROID_HOME"]
            ?? (NSHomeDirectory() + "/Library/Android/sdk")
        let adb = URL(fileURLWithPath: sdk).appendingPathComponent("platform-tools/adb")
        guard isExecutable(adb.path) else { return nil }
        return AdbClient(adbPath: adb, serial: serial)
    }

    /// 回前景 package 或 nil（降級）。逾時內未完成 → 殺行程回 nil。
    /// 語意/輸出與重構前位元等價（mergeStderr:false → stderr→nullDevice）。
    func dumpsysForegroundPackage(timeout: Duration = .seconds(2)) async -> String? {
        await foregroundResult(timeout: timeout).package
    }

    func foregroundResult(timeout: Duration) async -> ForegroundResult {
        switch await execute(["-s", serial, "shell", "dumpsys", "activity", "activities"], timeout, false) {
        case .completed(let exit, let stdout):
            return exit == 0 ? .success(AdbOutcome.packageOrNil(exitCode: exit, stdout: stdout)) : .failure
        case .timedOut: return .timeout
        case .failed: return .failure
        }
    }

    /// 安裝 APK：`adb -s <serial> install -r <path>`。失敗原因在 stderr，故合流。
    /// run 回 nil（adb 無法啟動/逾時砍）→ 降級為明確 failure，不崩。
    func install(apkURL: URL, timeout: Duration = .seconds(120)) async -> InstallResult {
        guard case .completed(_, let stdout) = await execute(
            ["-s", serial, "install", "-r", apkURL.path], timeout, true
        ) else { return .failure("adb 執行失敗或逾時") }
        return InstallResult.parse(stdout)
    }

    private func execute(_ args: [String], _ timeout: Duration, _ merge: Bool) async -> ProcessOutcome {
        if let runner {
            guard let result = await runner(adbPath, args, timeout, merge) else { return .timedOut }
            return .completed(result.exit, result.stdout)
        }
        await AdbServerStartup.shared.prepare(adbPath)
        return await Self.runDetailed(adbPath, args, timeout, merge)
    }

    /// 原始執行器不預啟動 server，供 shell fixture 直接測試資源生命週期。
    static func runProcess(
        _ path: URL, _ args: [String], _ timeout: Duration, _ merge: Bool,
        drainFinished: @escaping @Sendable () -> Void = {}
    ) async -> (exit: Int32, stdout: String)? {
        guard case .completed(let exit, let stdout) = await runDetailed(
            path, args, timeout, merge, drainFinished: drainFinished
        ) else { return nil }
        return (exit, stdout)
    }

    fileprivate static func runDetailed(
        _ path: URL, _ args: [String], _ timeout: Duration, _ merge: Bool,
        captureOutput: Bool = true, drainFinished: @escaping @Sendable () -> Void = {}
    ) async -> ProcessOutcome {
        let process = Process()
        process.executableURL = path
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let pipe = captureOutput ? Pipe() : nil
        process.standardOutput = pipe.map { $0 as Any } ?? FileHandle.nullDevice
        process.standardError = merge ? process.standardOutput : FileHandle.nullDevice
        let box = OutcomeBox(process: process, pipe: pipe)
        return await withCheckedContinuation { continuation in
            box.attach(continuation)
            guard box.configureReader() else { box.finish(.failed); return }
            do { try process.run() }
            catch { box.finish(.failed); return }
            // 父行程不保留寫端；否則自己的 fd 也會阻止 EOF。
            box.closeWriter()
            box.drainAndFinish(onFinish: drainFinished)
            box.attach(Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                await box.timeout()
            })
        }
    }
}

fileprivate enum ProcessOutcome: Sendable {
    case completed(Int32, String)
    case timedOut
    case failed
}

/// 同一 adb 路徑只嘗試一次；actor 在 await 前保存 Task，並行首次使用也會等同一份工作。
actor AdbServerStartup {
    static let shared = AdbServerStartup()
    private var attempts: [URL: Task<Void, Never>] = [:]

    func prepare(_ path: URL) async {
        if let attempt = attempts[path] { await attempt.value; return }
        let attempt = Task {
            let result = await AdbClient.runDetailed(
                path, ["start-server"], .seconds(2), false, captureOutput: false
            )
            if case .completed(0, _) = result { return }
            NSLog("[adb] start-server 失敗或逾時，繼續嘗試 client 呼叫")
        }
        attempts[path] = attempt
        await attempt.value
    }
}

/// read 與 close 共用鎖，且 read 為非阻塞：不跨執行緒關閉阻塞中的 FileHandle，
/// 也不讓已重用的 fd 被舊 drain 讀取。Process 的等待不使用 waitUntilExit()。
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let pipe: Pipe?
    private var readerClosed = false
    private var writerClosed = false
    private var continuation: CheckedContinuation<ProcessOutcome, Never>?
    private var watchdog: Task<Void, Never>?
    private var done = false

    init(process: Process, pipe: Pipe?) { self.process = process; self.pipe = pipe }

    func configureReader() -> Bool {
        guard let pipe else { return true }
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    func attach(_ cont: CheckedContinuation<ProcessOutcome, Never>) {
        lock.lock(); defer { lock.unlock() }
        continuation = cont
    }

    func attach(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if done { task.cancel() } else { watchdog = task }
    }

    func closeWriter() {
        lock.lock(); defer { lock.unlock() }
        closeWriterLocked()
    }

    private func closeWriterLocked() {
        guard !writerClosed else { return }
        writerClosed = true
        pipe?.fileHandleForWriting.closeFile()
    }

    private func closeReaderLocked() {
        guard !readerClosed else { return }
        readerClosed = true
        pipe?.fileHandleForReading.closeFile()
    }

    private var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

    /// nil = 本輪沒有資料，空 Data = EOF／已關閉。單次 read 最多 64 KiB。
    private func readChunk() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !done, !readerClosed, let pipe else { return Data() }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(pipe.fileHandleForReading.fileDescriptor, buffer.baseAddress, buffer.count)
        }
        if count > 0 { return Data(bytes.prefix(count)) }
        if count < 0 && (errno == EAGAIN || errno == EINTR) { return nil }
        return Data()
    }

    func drainAndFinish(onFinish: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { onFinish() }
            var data = Data()
            if pipe != nil {
                while !isDone {
                    if let chunk = readChunk() {
                        if chunk.isEmpty { break }
                        data.append(chunk)
                    } else { Thread.sleep(forTimeInterval: 0.01) }
                }
                // EOF 不代表 Process 已退出；最多等一秒，剩下交 watchdog 終止。
                let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                while !isDone && process.isRunning && ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            } else {
                // start-server 不使用 pipe；watchdog 同樣限制這段等待。
                while !isDone && process.isRunning { Thread.sleep(forTimeInterval: 0.01) }
            }
            guard !isDone, !process.isRunning else { return }
            finish(.completed(process.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
        }
    }

    private func claimTimeout() -> CheckedContinuation<ProcessOutcome, Never>? {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return nil }
        done = true
        let cont = continuation
        continuation = nil
        watchdog = nil
        return cont
    }

    func timeout() async {
        guard let cont = claimTimeout() else { return }
        if process.isRunning {
            process.terminate()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while process.isRunning && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        closeReader()
        cont.resume(returning: .timedOut)
    }

    private func closeReader() {
        lock.lock(); defer { lock.unlock() }
        closeReaderLocked()
    }

    func finish(_ value: ProcessOutcome) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        closeReaderLocked()
        closeWriterLocked()
        let cont = continuation
        continuation = nil
        let task = watchdog
        watchdog = nil
        lock.unlock()
        task?.cancel()
        cont?.resume(returning: value)
    }
}
