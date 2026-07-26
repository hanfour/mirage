/// 幀與可視區域的幾何換算。單位無關——呼叫端餵 point 就得到 point，餵 pixel 就得到 pixel
/// （只做比例運算）。MirageCore 不得 import AppKit，故不用 CGRect。
public struct FitRect: Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let zero = FitRect(x: 0, y: 0, width: 0, height: 0)
}

public enum ViewportFit {
    /// 把 frame 的長寬比 aspect-fit 進 bounds，回傳置中的內容矩形。
    ///
    /// 長寬比相同時黑邊為 0（退化成滿版）——這條性質保證視窗模式行為零回歸，
    /// 全螢幕與視窗因此走同一條路徑，沒有「全螢幕模式」分支。
    ///
    /// 任一維度 <= 0 → `.zero`，呼叫端據此不佈局（不崩、不畫）。
    public static func fit(frame: (w: Int, h: Int), in bounds: (w: Int, h: Int)) -> FitRect {
        guard frame.w > 0, frame.h > 0, bounds.w > 0, bounds.h > 0 else { return .zero }
        // 交叉相乘比較長寬比，避免浮點誤差讓「比例相同」判成不同、多出 1px 黑邊。
        if frame.w * bounds.h >= bounds.w * frame.h {
            let h = frame.h * bounds.w / frame.w          // 寬受限：左右填滿，上下黑邊
            return FitRect(x: 0, y: (bounds.h - h) / 2, width: bounds.w, height: h)
        }
        let w = frame.w * bounds.h / frame.h              // 高受限：上下填滿，左右黑邊
        return FitRect(x: (bounds.w - w) / 2, y: 0, width: w, height: bounds.h)
    }
}
