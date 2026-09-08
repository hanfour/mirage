import Foundation

public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: Data
    /// 這一幀在 transport 層被建構的時刻——也就是它抵達 Mirage 的時間。
    ///
    /// 用途只有一個：量「抵達 → present」這段延遲（`MIRAGE_LATENCY_LOG=1`）。
    /// 驗收線 2 只加總輸入注入、傳輸與抵達到 present，guest 反應另列未量項。
    /// 舊 Python harness 的 78.1ms 由壞掉的偵測器量出，已作廢。
    /// 三段分開量才能知道各段貢獻，判斷該優化輸入、傳輸還是渲染。
    ///
    /// **不參與 `Equatable`**（見下方自訂的 `==`）：兩幀內容相同就是相同的一幀，
    /// 抵達時刻只是量測用的旁註。讓它參與比較會讓既有測試（例如
    /// `LatestFrameBoxTests` 比對取出的幀）無故失敗。
    public let receivedAt: ContinuousClock.Instant
    /// 傳輸層以 Unix 時間與 emulator 時間戳計算一次傳輸毫秒數。
    /// timestampUs 不可與 receivedAt 相減，ContinuousClock 是單調時鐘，並非 Unix 時間。
    /// nil 表示無法量測，負值表示時鐘樣本無效；量測資訊不參與相等比較。
    /// gRPC 的 timestampUs 為 0 代表缺少時間戳，傳 nil 以免巨大的正值污染統計。
    public let transitMs: Double?

    public init(width: Int, height: Int, rgba: Data,
                receivedAt: ContinuousClock.Instant = .now, transitMs: Double? = nil) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.receivedAt = receivedAt
        self.transitMs = transitMs
    }

    public static func == (lhs: Frame, rhs: Frame) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.rgba == rhs.rgba
    }

    public var isValid: Bool {
        width > 0 && height > 0 && rgba.count == width * height * 4
    }
}
