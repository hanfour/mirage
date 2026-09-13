import AppKit

/// 偵測器只需要前景查詢能力，行程執行由實作負責。
protocol ForegroundPackageProviding: Sendable {
    func dumpsysForegroundPackage(timeout: Duration) async -> String?
    func foregroundResult(timeout: Duration) async -> ForegroundResult
}

enum ForegroundResult: Sendable {
    case success(String?)
    case timeout
    case failure

    var package: String? {
        if case .success(let package) = self { return package }
        return nil
    }
}

extension ForegroundPackageProviding {
    func foregroundResult(timeout: Duration) async -> ForegroundResult {
        .success(await dumpsysForegroundPackage(timeout: timeout))
    }
}

extension AdbClient: ForegroundPackageProviding {}

/// 前景遊戲偵測：Timer 輪詢 adb，package 變動時回呼（nil=無前景/adb 失敗）。
@MainActor
final class GameDetector {
    private let adb: any ForegroundPackageProviding
    private let interval: TimeInterval
    private let onChange: (String?) -> Void
    private var timer: Timer?
    private var last: String??            // 尚未偵測=nil；已偵測=Optional(package/nil)
    private var polling = false
    private(set) var consecutiveTimeouts = 0
    var scheduledPollingInterval: TimeInterval? { timer?.timeInterval }
    var pollingInterval: TimeInterval { consecutiveTimeouts >= 3 ? max(interval, 10) : interval }

    init(adb: any ForegroundPackageProviding, interval: Duration = .milliseconds(1500),
         onChange: @escaping (String?) -> Void) {
        self.adb = adb
        self.interval = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        self.onChange = onChange
    }

    func start() {
        stop()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = pollingInterval
        // ADAPTATION (-strict-concurrency=complete): 同 P1-b ClipboardWatcher——Timer 的
        // block 參數是 `@escaping @Sendable (Timer) -> Void`，但 tick() 是 @MainActor
        // 隔離且會變動非 Sendable 狀態（polling/timer/last）。閉包只捕捉 weak self（跨界
        // 的僅為 Optional 弱參照），`MainActor.assumeIsolated` 同步重新進入 MainActor 隔離——
        // 安全，因為 Foundation 的 run-loop-based Timer 回呼固定在主執行緒/主 run loop 觸發。
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.tick() }
        }
        timer?.tolerance = interval * 0.3
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Timer 只負責排程；測試直接等待單輪工作，不依賴時鐘或 run loop。
    @discardableResult
    func tick() -> Task<Void, Never>? {
        guard !polling else { return nil }    // 上一輪未回，跳過（adb 慢時不堆疊）
        polling = true
        let adb = self.adb
        return Task { @MainActor [weak self] in
            let result = await adb.foregroundResult(timeout: .seconds(2))
            defer { self?.polling = false }
            guard let self else { return }
            let previousInterval = self.pollingInterval
            let previousTimeouts = self.consecutiveTimeouts
            switch result {
            case .timeout:
                self.consecutiveTimeouts = min(self.consecutiveTimeouts + 1, 3)
                if self.consecutiveTimeouts == 3 && previousTimeouts < 3 {
                    NSLog("[adb] 連續三次逾時，前景輪詢間隔調整為 %.1f 秒", self.pollingInterval)
                }
            case .success: self.consecutiveTimeouts = 0
            case .failure:
                // 一般失敗不算逾時；已進入退避則等成功才恢復。
                if self.consecutiveTimeouts < 3 { self.consecutiveTimeouts = 0 }
            }
            if previousInterval != self.pollingInterval && self.timer != nil { self.scheduleTimer() }
            let pkg = result.package
            if self.last == nil || self.last! != pkg {   // 首次或變動
                self.last = pkg
                self.onChange(pkg)
            }
        }
    }
}
