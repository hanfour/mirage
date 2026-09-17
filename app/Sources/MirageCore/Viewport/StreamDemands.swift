/// 串流解析度的兩個需求來源。emulator 一次只給一條串流，視窗與手機遙控共用，
/// 所以請求取兩者中像素較多的；手機斷線時清掉 `remote`，請求退回視窗的需求。
public struct StreamDemands: Sendable {
    public var window: (w: Int, h: Int)?
    public var remote: (w: Int, h: Int)?

    public init() {}

    /// 兩個需求都沒有時用 `fallback`（背景模式沒有視窗、手機也還沒連上）。
    public func request(fallback: (w: Int, h: Int)) -> (w: Int, h: Int) {
        [window, remote].compactMap { $0 }.max { $0.w * $0.h < $1.w * $1.h } ?? fallback
    }
}
