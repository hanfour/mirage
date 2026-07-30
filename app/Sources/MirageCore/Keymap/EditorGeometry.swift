import Foundation

/// 正規化座標（0–1，對齊 guest 畫面）↔ **letterbox 後內容矩形內**的視圖座標。
///
/// **為什麼不能用整個視窗的尺寸換算**：guest 畫面被 `MirrorContainerView` 依
/// `ViewportFit.fit(...)` 置中進內容矩形，黑邊不屬於 guest。用視窗尺寸換算，只要有黑邊
/// 標記就與真正的觸點位置錯開——視窗模式下 `contentAspectRatio` 把黑邊壓到接近 0 所以
/// 看不太出來，但**全螢幕時 macOS 忽略 `contentAspectRatio`，黑邊是真的**。
///
/// 純函式放這裡的理由同 `KeyTranslate`／`StreamSize`／`ViewportFit`：算術逐條測試，
/// SwiftUI 那層只負責手勢與繪製。
public enum EditorGeometry {
    /// 正規化座標 → 視圖座標（相對於**容器**，已含內容矩形的偏移）。
    public static func viewPoint(for p: NormPoint, in rect: FitRect) -> (x: Double, y: Double) {
        (x: Double(rect.x) + p.x * Double(rect.width),
         y: Double(rect.y) + p.y * Double(rect.height))
    }

    /// 視圖座標 → 正規化座標，**夾在 0…1**。矩形退化（尚未收到幀）時回 nil。
    ///
    /// 夾取而非拒絕，理由同 D7：拖到黑邊上仍要得到一個合法座標，
    /// 送越界座標比不送更糟——畫面會有反應但點在錯的地方。
    public static func normPoint(x: Double, y: Double, in rect: FitRect) -> NormPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return NormPoint.clamped(x: (x - Double(rect.x)) / Double(rect.width),
                                 y: (y - Double(rect.y)) / Double(rect.height))
    }

    /// 搖桿半徑 → 點數。**基準是寬度**，沿用 `KeymapOverlay` 既有慣例
    /// （圓的直徑用 `radius * width * 2` 同時當寬與高）。改成高度或對角線會讓既有
    /// profile 的搖桿在畫面上換一個大小。
    public static func radiusInPoints(_ radius: Double, in rect: FitRect) -> Double {
        radius * Double(rect.width)
    }

    /// 點數 → 搖桿半徑。矩形退化時回 nil。
    public static func radius(fromPoints d: Double, in rect: FitRect) -> Double? {
        guard rect.width > 0 else { return nil }
        return d / Double(rect.width)
    }
}
