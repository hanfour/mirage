/// 內容矩形寬 → 要跟 emulator 請求的串流尺寸。純算術，與 AppKit 無關，故放 MirageCore
/// 讓它可被單元測試（`MirrorView.Coordinator` 其餘部分綁在 AppKit/SwiftUI 上不可測，
/// 但這段沒有理由跟著陪葬）。
public enum StreamSize {
    /// 視窗最小寬（`MirrorMTKView` 的下限），同時是本函式的輸出下限。
    public static let minWidth = 270

    /// 寬度上限。全螢幕會把內容矩形放大到螢幕高度，不設限會請求超大幀。
    public static let maxWidth = 1080

    /// 總像素上限（P1-e 終審 Minor 4）：單靠寬度上限守不住成本——9:20 直向 guest 在
    /// `maxWidth` 下會算到 1080×2400 ≈ **2.6 MP**，比 spec §4.3 用來論證這個上限的
    /// 880×1960（≈1.7 MP）多出 50%，等於實際放行量遠超論證基礎。
    ///
    /// 取 1.8 MP（9:20 下約 900×2000，貼近 spec 自己的數字）。偏保守是刻意的：spec 的
    /// 顧慮是掉 fps，而 fps ≥55 是硬性驗收線；畫面銳利度沒有數值要求。
    /// **此值尚未經 fps 實測校準**——驗收線 7 仍是 pending-human（需解鎖螢幕的 GUI
    /// session），拿到真實 fps 後應回頭調整。
    public static let maxPixels = 1_800_000

    /// 依序套用：下限、寬度上限、總像素上限，最後偶數對齊（proto 縮放要求）。
    /// `aspect` 任一維度 <= 0 時只套用寬度限制（無法推算高度，不猜）。
    public static func width(forContentWidth contentWidth: Int, aspect: (w: Int, h: Int)) -> Int {
        let byWidth = min(max(contentWidth, minWidth), maxWidth)
        guard aspect.w > 0, aspect.h > 0 else { return max(byWidth, minWidth) & ~1 }
        // w * (aspect.h / aspect.w) * w <= maxPixels
        //   → w <= sqrt(maxPixels * aspect.w / aspect.h)
        let byPixels = Int((Double(maxPixels) * Double(aspect.w) / Double(aspect.h)).squareRoot())
        return max(min(byWidth, byPixels), minWidth) & ~1
    }

    /// 由寬與長寬比推回高度（偶數對齊，下限 2）。
    public static func height(forWidth width: Int, aspect: (w: Int, h: Int)) -> Int {
        guard aspect.w > 0, aspect.h > 0 else { return 2 }
        return max(aspect.h * width / aspect.w, 2) & ~1
    }
}
