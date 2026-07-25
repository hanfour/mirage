import AppKit

/// 前景遊戲偵測：Timer 輪詢 adb，package 變動時回呼（nil=無前景/adb 失敗）。
@MainActor
final class GameDetector {
    private let adb: AdbClient
    private let interval: TimeInterval
    private let onChange: (String?) -> Void
    private var timer: Timer?
    private var last: String??            // 尚未偵測=nil；已偵測=Optional(package/nil)
    private var polling = false

    init(adb: AdbClient, interval: Duration = .milliseconds(1500),
         onChange: @escaping (String?) -> Void) {
        self.adb = adb
        self.interval = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        self.onChange = onChange
    }

    func start() {
        stop()
        // ADAPTATION (-strict-concurrency=complete): 同 P1-b ClipboardWatcher——Timer 的
        // block 參數是 `@escaping @Sendable (Timer) -> Void`，但 tick() 是 @MainActor
        // 隔離且會變動非 Sendable 狀態（polling/timer/last）。閉包只捕捉 weak self（跨界
        // 的僅為 Optional 弱參照），`MainActor.assumeIsolated` 同步重新進入 MainActor 隔離——
        // 安全，因為 Foundation 的 run-loop-based Timer 回呼固定在主執行緒/主 run loop 觸發。
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = interval * 0.3
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard !polling else { return }    // 上一輪未回，跳過（adb 慢時不堆疊）
        polling = true
        let adb = self.adb
        Task { @MainActor [weak self] in
            let pkg = await adb.dumpsysForegroundPackage()
            defer { self?.polling = false }
            guard let self else { return }
            if self.last == nil || self.last! != pkg {   // 首次或變動
                self.last = pkg
                self.onChange(pkg)
            }
        }
    }
}
