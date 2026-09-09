/// 電源狀態由 EmulatorClient.setPower 直接指派，從不經過 reducer。
/// 2026-09-09（D14／D31）刪除 PowerEvent 與 PowerReducer：原事件語意
/// （.snapshotSaved → .suspended、.snapshotLoaded → .active）與實作相反，
/// 實作刻意不存不載快照。保留 PowerState 與既有路徑供生產端使用。
public enum PowerState: Equatable, Sendable {
    case active, suspending, suspended, waking
}
