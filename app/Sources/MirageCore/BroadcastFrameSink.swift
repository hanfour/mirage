/// 幀扇出 decorator（手機遙控，spec 第 2 節設計決定 1）。
///
/// `put()` 把同一個 `Frame` 值交給 Renderer 用的 `primary` 與編碼器用的 `secondary`；
/// `takeLatest()`／`stats()` 只代理 `primary`，所以 `FramePump` 與 `Renderer` 看到的行為
/// 與直接用 `primary` 完全相同。遙控關閉時 `AppModel` 不建這個型別、直接用原本的 sink。
///
/// `Frame.rgba` 是 `Data`，兩邊持有同一份底層儲存，不多一次像素拷貝。
/// `secondary` 固定是 `LatestFrameBox`：編碼器依自己的節奏取最新幀，drop-late 是它要的語意。
/// 本型別自己沒有任何可變狀態，兩個子 sink 各自負責自己的鎖。
public final class BroadcastFrameSink: FrameSink, @unchecked Sendable {
    public let primary: any FrameSink
    public let secondary: LatestFrameBox

    public init(primary: any FrameSink, secondary: LatestFrameBox = LatestFrameBox()) {
        self.primary = primary
        self.secondary = secondary
    }

    public func put(_ frame: Frame) {
        primary.put(frame)
        secondary.put(frame)
    }

    public func takeLatest() -> Frame? {
        primary.takeLatest()
    }

    public func stats() -> FrameCounterSnapshot {
        primary.stats()
    }
}
