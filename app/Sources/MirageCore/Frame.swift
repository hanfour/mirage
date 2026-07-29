import Foundation

public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: Data
    /// 這一幀在 transport 層被建構的時刻——也就是它抵達 Mirage 的時間。
    ///
    /// 用途只有一個：量「抵達 → present」這段延遲（`MIRAGE_LATENCY_LOG=1`）。
    /// 輸入延遲 <80ms 是母計畫 §7 Phase-1 的驗收線，而 2026-07-29 用 Python
    /// harness 量到的 78.1ms 完全不經過 Mirage，是下界；沒有這個時間戳就無法
    /// 知道 Mirage 這一段貢獻多少，也就無法判斷該優化傳輸還是渲染。
    ///
    /// **不參與 `Equatable`**（見下方自訂的 `==`）：兩幀內容相同就是相同的一幀，
    /// 抵達時刻只是量測用的旁註。讓它參與比較會讓既有測試（例如
    /// `LatestFrameBoxTests` 比對取出的幀）無故失敗。
    public let receivedAt: ContinuousClock.Instant

    public init(width: Int, height: Int, rgba: Data,
                receivedAt: ContinuousClock.Instant = .now) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.receivedAt = receivedAt
    }

    public static func == (lhs: Frame, rhs: Frame) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.rgba == rhs.rgba
    }

    public var isValid: Bool {
        width > 0 && height > 0 && rgba.count == width * height * 4
    }
}
