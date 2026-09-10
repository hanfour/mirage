import Foundation
import MirageCore

/// adb 子行程薄封裝：抽出共用 `run`（並發排空 pipe 避免大輸出死鎖、逾時砍行程），
/// dumpsys 前景偵測與 APK 安裝各自轉換結果。非 @MainActor（純執行）。
struct AdbClient: Sendable {
    let adbPath: URL
    let serial: String
    typealias Runner = @Sendable (URL, [String], Duration, Bool) async -> (exit: Int32, stdout: String)?
    private let runner: Runner

    init(adbPath: URL, serial: String, runner: @escaping Runner = AdbClient.runProcess) {
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
        guard let r = await runner(
            adbPath, ["-s", serial, "shell", "dumpsys", "activity", "activities"], timeout, false
        ) else { return nil }
        return AdbOutcome.packageOrNil(exitCode: r.exit, stdout: r.stdout)
    }

    /// 安裝 APK：`adb -s <serial> install -r <path>`。失敗原因在 stderr，故合流。
    /// run 回 nil（adb 無法啟動/逾時砍）→ 降級為明確 failure，不崩。
    func install(apkURL: URL, timeout: Duration = .seconds(120)) async -> InstallResult {
        guard let r = await runner(
            adbPath, ["-s", serial, "install", "-r", apkURL.path], timeout, true
        ) else { return .failure("adb 執行失敗或逾時") }
        return InstallResult.parse(r.stdout)
    }

    /// 跑 adb，背景並發排空 stdout（避免大輸出塞爆 pipe buffer 死鎖），逾時砍行程。
    /// launch 失敗/逾時 → nil。mergeStderr:true 時 stderr 併入同一 pipe（等同 2>&1）。
    private static func runProcess(
        _ adbPath: URL, _ args: [String], _ timeout: Duration, _ mergeStderr: Bool
    ) async -> (exit: Int32, stdout: String)? {
        let proc = Process()
        proc.executableURL = adbPath
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        let box = OutcomeBox(process: proc)

        return await withCheckedContinuation {
            (cont: CheckedContinuation<(exit: Int32, stdout: String)?, Never>) in
            box.attach(cont)
            do {
                try proc.run()
            } catch {
                box.finish(nil)
                return
            }
            // 邊跑邊讀持續排空 pipe，子行程才不會卡在 write()（見 OutcomeBox 註解）。
            box.drainAndFinish(pipe: pipe)
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                box.timeoutIfStillRunning()
            }
            box.attach(watchdog)
        }
    }
}

/// 確保 continuation 只 resume 一次（逾時 vs 正常結束競態），並在逾時時終止子行程。
/// 泛化為回 `(exit, stdout)?`，讓 dumpsys/install 各自轉換（原本烘死 AdbOutcome）。
///
/// 設計備註（strict concurrency 適配）：`Process` 不是 `Sendable`，直接在
/// `@Sendable` closure 捕捉會警告；改用單一 `@unchecked Sendable` box、內部用鎖
/// 保護所有可變狀態，對外只暴露「完成一次」與「逾時終止」兩個動作。
private final class OutcomeBox: @unchecked Sendable {
    typealias Output = (exit: Int32, stdout: String)
    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<Output?, Never>?
    private var watchdog: Task<Void, Never>?
    private var done = false

    init(process: Process) { self.process = process }

    func attach(_ cont: CheckedContinuation<Output?, Never>) {
        lock.lock(); defer { lock.unlock() }
        continuation = cont
    }

    func attach(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if done { task.cancel() } else { watchdog = task }
    }

    /// 背景並發排空 pipe（取代只在 terminationHandler 裡讀的死鎖作法）。
    /// `readToEnd()` 阻塞到 EOF（子行程關閉自己的 stdout）；隨後 waitUntilExit()
    /// 拿真正的 terminationStatus。finish 走與 timeoutIfStillRunning 相同的鎖保護
    /// done 旗標，兩者哪個先到就贏——resume-once 保證未變。
    func drainAndFinish(pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            finish((exit: process.terminationStatus, stdout: out))
        }
    }

    /// 逾時觸發：仍在跑就殺掉子行程並降級回 nil；已完成則忽略。
    func timeoutIfStillRunning() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let cont = continuation
        continuation = nil
        let proc = process
        lock.unlock()
        if proc.isRunning { proc.terminate() }
        cont?.resume(returning: nil)
    }

    func finish(_ v: Output?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let cont = continuation
        continuation = nil
        let task = watchdog
        watchdog = nil
        lock.unlock()
        task?.cancel()
        cont?.resume(returning: v)
    }
}
