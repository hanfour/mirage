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

            do {
                try proc.run()
            } catch {
                box.finish(nil)
                return
            }

            // AUTHORIZED FIX（P1-d 終審 Important：pipe 死鎖）—— `dumpsys activity
            // activities` 的輸出常態超過 macOS pipe buffer（16–64 KB）。原本只在
            // terminationHandler 裡才讀 pipe：子行程一旦把 buffer 塞滿就卡在 write()
            // 永遠不會結束，terminationHandler 因此永遠不會觸發，只能靠下面的 watchdog
            // 逾時砍掉——偵測因而間歇性失效（2 秒逾時、悄悄降級回 nil）。改成
            // box.drainAndFinish：在背景執行緒「邊跑邊讀」持續排空 pipe，子行程就不會
            // 被 buffer 卡住；讀到 EOF（=子行程結束、關閉自己的 stdout）後再
            // waitUntilExit() 拿真正的 terminationStatus 收尾。
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

    /// AUTHORIZED FIX（P1-d 終審 Important：pipe 死鎖）——並發排空 pipe，取代原本
    /// 只在 terminationHandler 裡讀的作法（見 dumpsysForegroundPackage 內註解）。
    ///
    /// 放在 box 內部而不是呼叫端自己開一個外部獨立 closure，是因為要
    /// 在背景執行緒的 `@Sendable` closure 裡用到 `process`——`Process` 本身不是
    /// `Sendable`，若直接從外部捕捉會如上方類別註解所述產生「非 Sendable 型別跨
    /// Sendable 邊界捕捉」警告；這裡改成讀取 box 內部既有的 `self.process`
    /// （box 已經是 `@unchecked Sendable`），不需要新增一個外部捕捉點。
    ///
    /// `readToEnd()` 是同步阻塞呼叫，會一路擋到 EOF 才返回；EOF 代表子行程已經
    /// 關閉自己的 stdout（正常結束、或被 timeoutIfStillRunning() 的 terminate()
    /// 訊號殺掉都會關 fd 觸發 EOF），此時子行程要嘛已經結束要嘛正在結束，
    /// waitUntilExit() 頂多再等一瞬間就能拿到真正的 terminationStatus。
    /// 最終呼叫 finish(_:) 走跟 timeoutIfStillRunning() 完全相同的鎖保護 done 旗標，
    /// 兩者哪個先到就贏、另一個變 no-op——resume-once 保證未變動。
    func drainAndFinish(pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            finish(AdbOutcome.packageOrNil(exitCode: process.terminationStatus, stdout: out))
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
