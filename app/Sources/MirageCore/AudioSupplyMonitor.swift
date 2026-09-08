/// 判斷 emulator 的音訊交付是不是塌了（D44），依據是 `AppModel+Audio` 每秒算出的
/// 封包數與供應率。
///
/// **三種狀態的實測值**（用 Mirage 自己的 `[audio] pkt=` 那行量的，不是用 harness 探針）：
///
/// | 狀態 | 每秒封包數 | 供應率 |
/// | --- | --- | --- |
/// | 健康 | 45 到 92 | 89 到 107% |
/// | 崩潰 | 3 到 13 | 4 到 8% |
/// | guest 沒放音訊 | 0 | 0% |
///
/// ⚠️ **不要拿 harness 的 `audio_amplitude_probe.py` 的封包數來定這裡的門檻。**
/// 那支探針在崩潰與健康狀態下都量到每秒約 88 個封包，而 Mirage 的 `writes` 數的是
/// 進環形緩衝的次數，崩潰時只有 3 到 13。兩把尺量的不是同一件事，混用會讓判準失效
/// （第一版就是這樣寫的，實跑時 degraded 永遠不出現）。
///
/// **為什麼沒有封包數門檻**：低供應率的秒數裡封包數從 3 到 94 都出現過，
/// 那條線沒有鑑別力。真正分得開的只有兩件事：`packets == 0` 分辨「guest 沒放音訊」，
/// 供應率分辨崩潰。多一個門檻只會多一個要維護的特殊情況。
public struct AudioSupplyMonitor: Sendable {
    public enum State: Sendable, Equatable {
        case idle
        case healthy
        case degraded
    }

    public let supplyThresholdPercent: Int
    public let consecutiveSecondsToDegrade: Int
    public let state: State
    public let consecutiveLowSupplySeconds: Int

    /// 供應率穩定落在 4 到 8% 與 89 到 107% 兩端，中間沒有值，所以 50% 這個位置不敏感。
    /// 連續 5 秒是為了跨過狀態轉換當下的過渡秒：實測崩潰會持續 55 秒以上，
    /// 而遊戲音訊剛啟動的過渡只有 2 秒。
    public init(supplyThresholdPercent: Int = 50,
                consecutiveSecondsToDegrade: Int = 5) {
        precondition(consecutiveSecondsToDegrade > 0)
        self.supplyThresholdPercent = supplyThresholdPercent
        self.consecutiveSecondsToDegrade = consecutiveSecondsToDegrade
        self.state = .idle
        self.consecutiveLowSupplySeconds = 0
    }

    private init(previous: Self, state: State, consecutiveLowSupplySeconds: Int) {
        self.supplyThresholdPercent = previous.supplyThresholdPercent
        self.consecutiveSecondsToDegrade = previous.consecutiveSecondsToDegrade
        self.state = state
        self.consecutiveLowSupplySeconds = consecutiveLowSupplySeconds
    }

    /// 狀態轉換時該留哪一行日誌。
    ///
    /// 抽成純函式而不是寫在呼叫端的 if 裡，是因為離開 `degraded` 有兩條路，
    /// 而它們的意思完全不同，寫在一起就會說謊：
    ///
    /// - 轉 `healthy`：供應率真的回來了，是 `recovered`。
    /// - 轉 `idle`：guest 不放音訊了，供應率沒有被驗證過，只是判定條件不再成立。
    ///
    /// 這個區別在實務上不是理論問題：這條缺陷唯一已知的重設是停掉 guest 全部音訊、
    /// 等 emulator 關閉主機輸出裝置再重播，**也就是每一次真實的恢復都會先經過 `idle`**。
    /// 把兩者併成一個 `recovered` 會讓日誌在音訊還沒被驗證時就報喜；
    /// 只認 `degraded` 直接轉 `healthy` 則會讓結束標記永遠不出現，日誌上只有開頭沒有結尾。
    public enum TransitionNotice: Sendable, Equatable {
        case degraded
        /// 供應率回到門檻之上。
        case recovered
        /// guest 停止輸出音訊，判定條件不再成立，但供應率沒有被驗證。
        case cleared
        case none
    }

    public static func notice(from previous: State, to current: State) -> TransitionNotice {
        guard previous != current else { return .none }
        if current == .degraded { return .degraded }
        guard previous == .degraded else { return .none }
        return current == .healthy ? .recovered : .cleared
    }

    /// 供應率不含門檻：剛好等於門檻時視為健康。
    public func observing(packets: Int, supplyPercent: Int) -> Self {
        guard packets != 0 else {
            return Self(previous: self, state: .idle, consecutiveLowSupplySeconds: 0)
        }
        guard supplyPercent < supplyThresholdPercent else {
            return Self(previous: self, state: .healthy, consecutiveLowSupplySeconds: 0)
        }
        // 達標後不再增加，讓長時間異常也不會使計數溢位。
        let count = consecutiveLowSupplySeconds < consecutiveSecondsToDegrade
            ? consecutiveLowSupplySeconds + 1 : consecutiveSecondsToDegrade
        return Self(previous: self,
                    state: count == consecutiveSecondsToDegrade ? .degraded : .healthy,
                    consecutiveLowSupplySeconds: count)
    }
}
