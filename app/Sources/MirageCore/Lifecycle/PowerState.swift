/// 電源純狀態機：凍結/喚醒轉移可窮舉測試，實際 gRPC 由 EmulatorClient 執行。
public enum PowerState: Equatable, Sendable {
    case active, suspending, suspended, waking
}

public enum PowerEvent: Equatable, Sendable {
    case suspendRequested, snapshotSaved, wakeRequested, snapshotLoaded
}

public enum PowerReducer {
    public static func reduce(_ state: PowerState, _ event: PowerEvent) -> PowerState {
        switch (state, event) {
        case (.active, .suspendRequested):    return .suspending
        case (.suspending, .snapshotSaved):   return .suspended
        case (.suspended, .wakeRequested):    return .waking
        case (.waking, .snapshotLoaded):      return .active
        default:                              return state   // 非法轉移 no-op
        }
    }
}
