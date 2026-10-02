import Foundation

/// Android 顯示方向與轉正座標之間的換算。
public enum DisplayRotation {
    /// 將使用者看到的正向座標換成面板座標。
    public static func panelPoint(fromUpright point: NormPoint, rotation: Int) -> NormPoint {
        switch normalized(rotation) {
        case 1: return NormPoint(x: 1 - point.y, y: point.x)
        case 2: return NormPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: return NormPoint(x: point.y, y: 1 - point.x)
        default: return point
        }
    }

    /// 將面板座標換成使用者看到的正向座標。
    public static func uprightPoint(fromPanel point: NormPoint, rotation: Int) -> NormPoint {
        switch normalized(rotation) {
        case 1: return NormPoint(x: point.y, y: 1 - point.x)
        case 2: return NormPoint(x: 1 - point.x, y: 1 - point.y)
        case 3: return NormPoint(x: 1 - point.y, y: point.x)
        default: return point
        }
    }

    /// 旋轉後顯示的畫面尺寸；四分之一圈時寬高互換。
    public static func upright(size: (w: Int, h: Int), rotation: Int) -> (w: Int, h: Int) {
        switch normalized(rotation) {
        case 1, 3: return (w: size.h, h: size.w)
        default: return size
        }
    }

    private static func normalized(_ rotation: Int) -> Int {
        let value = rotation % 4
        return value < 0 ? value + 4 : value
    }
}
