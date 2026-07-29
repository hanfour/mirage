import Foundation

/// 正規化座標（0–1，左上原點對齊 guest）。越界由 isValid 暴露，載入期拒絕。
public struct NormPoint: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public var isValid: Bool { (0...1).contains(x) && (0...1).contains(y) }

    /// 換算為 guest 像素。
    ///
    /// **`width`/`height` 必須是 guest 的實體螢幕解析度**，來自健康探測回報的
    /// `EmulatorClient.guestDisplay`——**不是**串流幀尺寸、不是 `renderer.lastFrameSize`。
    /// proto 明載 `Touch.x/y` 的座標系是 "physical location on the screen"。
    ///
    /// > **更正（2026-07-29）**：本行原本寫「呼叫端傳實際幀尺寸——沿用 P1-a 的實際幀尺寸換算」。
    /// > **那正是 bug 本體**：串流幀（540×1200）與 guest 實體（本機 1080×2400）差兩倍，
    /// > 照著傳會讓每個觸點落在目標的左上一半處。整條路徑其他六處註解在修 §10 時都改了，
    /// > 唯獨這個函式自己沒改——而下一個人讀的就是這一句。
    /// > 現在唯一的產品呼叫端 `EmulatorClient.buildTouchEvent` 傳的是 `guestDisplay`，
    /// > 且 `sendTouches` 已拿掉 `width:height:` 參數，呼叫端沒有機會再傳錯。
    public func guestPixel(width: Int, height: Int) -> (x: Int, y: Int) {
        (Int((x * Double(width)).rounded()), Int((y * Double(height)).rounded()))
    }
}
