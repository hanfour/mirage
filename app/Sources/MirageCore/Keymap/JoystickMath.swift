import Foundation

/// 方向鍵集合 → 正規化向量。y 向下為正（對齊 guest）；對角長度正規化為 1；相反鍵相消。
public enum JoystickMath {
    public static func vector(up: Bool, down: Bool, left: Bool, right: Bool)
        -> (dx: Double, dy: Double)
    {
        let x = (right ? 1.0 : 0.0) - (left ? 1.0 : 0.0)
        let y = (down ? 1.0 : 0.0) - (up ? 1.0 : 0.0)
        let mag = (x * x + y * y).squareRoot()
        guard mag > 0 else { return (0, 0) }
        return (x / mag, y / mag)
    }
}
