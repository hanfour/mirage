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

    /// AppKit 視圖座標（左下原點）→ 正規化座標（左上原點，對齊 guest），**夾在 0…1**。
    ///
    /// 抽成純函式的理由同 `KeyTranslate`：`MirrorMTKView` 只負責從 `NSEvent` 取欄位，
    /// 算術本身在這裡逐條測試。`nil` 只代表「視圖尺寸退化（寬或高 ≤ 0）」，沒有別的意思。
    ///
    /// **為什麼是夾住而不是拒絕（D7）**：呼叫端原本對越界回傳 nil、事件整個丟掉。
    /// `mouseDown` 一定落在界內（黑邊屬於 `MirrorContainerView`，它不處理滑鼠），但 drag
    /// 一開始，AppKit 就會把後續的 `mouseDragged`／`mouseUp` **繼續投遞給同一個 view**，
    /// 即使游標已經離開。於是「拖到黑邊或視窗外放開」= up 被丟掉 = guest 端一根永遠按著
    /// 的手指，而且沒有自癒路徑（與 D6 同一族）。
    ///
    /// 夾住讓這個特殊情況整個消失，不必為「按著沒放」多維護一份狀態：真實觸控螢幕上
    /// 手指本來就不可能離開螢幕，停在邊緣是最接近的類比。**越界必須夾而不是原樣送出**
    /// ——送一個越界座標比不送更糟，畫面會有反應但點在錯的地方，而使用者會以為是遊戲的問題。
    public static func fromViewPoint(x: Double, y: Double,
                                     width: Double, height: Double) -> NormPoint?
    {
        guard width > 0, height > 0 else { return nil }
        return NormPoint(x: min(max(x / width, 0), 1),
                         y: min(max(1.0 - y / height, 0), 1))
    }
}
