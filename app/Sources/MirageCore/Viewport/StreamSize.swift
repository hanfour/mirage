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
    /// 取 1.8 MP（9:20 下約 900×2000，貼近 spec 自己的數字）。
    ///
    /// **更正（2026-07-29）**：本段原本寫「此值尚未經 fps 實測校準——驗收線 7 仍是
    /// pending-human（需解鎖螢幕的 GUI session）」。兩點都要修：
    ///
    /// 1. **已經有實測了**（`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §11.2，
    ///    同機同內容不同掃描解析度）：
    ///
    ///    | 解析度 | 像素 | fps |
    ///    |---|---|---|
    ///    | 270×600 | 0.16 MP | 32.3 |
    ///    | 540×1200 | 0.65 MP | 30.4 |
    ///    | 1080×2400 | 2.59 MP | 22.0 |
    ///
    ///    **解析度降到 1/4，fps 只從 30.4 升到 32.3**——在 0.65 MP 以下，縮像素預算
    ///    幾乎買不到 fps。所以「偏保守＝保護 fps」這個理由在低端**不成立**。
    ///    但 2.59 MP 確實掉到 22.0，**上限本身仍有價值**，只是價值在防住高端而非愈小愈好。
    ///    注意 1.8 MP 這個值**本身沒有對應的量測點**（介於 0.65 與 2.59 之間），
    ///    要調整它得先補量。
    ///
    /// 2. **驗收線 7 的 pending 歸因是錯的**。它不是「需解鎖螢幕」——鏡像顯示當時根本
    ///    沒在運作（`AVAudioEngine` 的 NSException 打死 MainActor），與螢幕鎖定無關。
    ///    防護已在樹上（`MirageShell/Audio/AudioPlayer.swift:29`），該驗收線現在量得了。
    ///
    /// **瓶頸推論**：§11.2 判定瓶頸在 guest 端的畫面產生速率，不在傳輸或渲染。
    /// 但該文件自己標明**這仍是推論——沒有直接量到 guest 的 render fps**，引用時別當定論。
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

    /// 請求串流用的長寬比。guest 實體解析度已知時一律用它，依幀的方向對調；幀只用來判斷直橫。
    ///
    /// 不能直接用幀尺寸：emulator 回傳的幀會自行縮 1 到 2px 且長寬比跟著變（實測請求
    /// 860×1910 回 859×1910），拿它算下一次請求會換到另一個尺寸，視窗高度與手機遙控畫面
    /// 在兩個尺寸間無限來回（2026-09-17）。
    public static func aspect(guest: (w: Int, h: Int)?, frame: (w: Int, h: Int)?) -> (w: Int, h: Int) {
        guard let frame, frame.w > 0, frame.h > 0 else { return guest ?? (w: 9, h: 20) }
        guard let guest, guest.w > 0, guest.h > 0 else { return frame }
        let long = max(guest.w, guest.h), short = min(guest.w, guest.h)
        return frame.w > frame.h ? (w: long, h: short) : (w: short, h: long)
    }

    /// 由寬與長寬比推回高度（偶數對齊，下限 2）。
    public static func height(forWidth width: Int, aspect: (w: Int, h: Int)) -> Int {
        guard aspect.w > 0, aspect.h > 0 else { return 2 }
        return max(aspect.h * width / aspect.w, 2) & ~1
    }
}
