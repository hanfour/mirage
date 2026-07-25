import Foundation
import MirageCore

/// adb 子行程薄封裝：跑 `adb -s <serial> shell dumpsys activity activities`，
/// 逾時/失敗降級回 nil（AdbOutcome）。非 @MainActor——純執行。
struct AdbClient: Sendable {
    let adbPath: URL
    let serial: String

    /// 由 ANDROID_SDK_ROOT/ANDROID_HOME 推導 adb；serial 預設 emulator-5554。
    static func standard(serial: String = "emulator-5554") -> AdbClient? {
        let env = ProcessInfo.processInfo.environment
        let sdk = env["ANDROID_SDK_ROOT"] ?? env["ANDROID_HOME"]
            ?? (NSHomeDirectory() + "/Library/Android/sdk")
        let adb = URL(fileURLWithPath: sdk).appendingPathComponent("platform-tools/adb")
        guard FileManager.default.isExecutableFile(atPath: adb.path) else { return nil }
        return AdbClient(adbPath: adb, serial: serial)
    }

    /// 回前景 package 或 nil（降級）。逾時內未完成 → 殺行程回 nil。
    func dumpsysForegroundPackage(timeout: Duration = .seconds(2)) async -> String? {
        let proc = Process()
        proc.executableURL = adbPath
        proc.arguments = ["-s", serial, "shell", "dumpsys", "activity", "activities"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let box = OutcomeBox(process: proc)

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            box.attach(cont)

            proc.terminationHandler = { p in
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let out = String(data: data, encoding: .utf8) ?? ""
                box.finish(AdbOutcome.packageOrNil(exitCode: p.terminationStatus, stdout: out))
            }

            do {
                try proc.run()
            } catch {
                box.finish(nil)
                return
            }

            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                box.timeoutIfStillRunning()
            }
            box.attach(watchdog)
        }
    }
}

/// 確保 continuation 只 resume 一次（逾時 vs 正常結束競態），並在逾時時終止子行程。
///
/// 設計備註（strict concurrency 適配）：`Process`／`DispatchWorkItem` 都不是 `Sendable`，
/// 直接在 `terminationHandler`（`@Sendable` closure）或 `Task {}` 內捕捉會在
/// `-strict-concurrency=complete` 下產生「非 Sendable 型別跨 Sendable 邊界捕捉」警告。
/// 改用單一 `@unchecked Sendable` box、內部用鎖保護所有可變狀態（process 參照、逾時 task、
/// 是否已完成），對外只暴露「完成一次」與「逾時終止」兩個動作，把非 Sendable 值鎖在
/// box 內部而不外洩到多個 closure 的捕捉列表中。
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<String?, Never>?
    private var watchdog: Task<Void, Never>?
    private var done = false

    init(process: Process) {
        self.process = process
    }

    func attach(_ cont: CheckedContinuation<String?, Never>) {
        lock.lock(); defer { lock.unlock() }
        continuation = cont
    }

    func attach(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if done {
            task.cancel()
        } else {
            watchdog = task
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

    func finish(_ v: String?) {
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
