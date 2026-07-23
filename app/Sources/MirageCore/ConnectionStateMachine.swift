/// 連線狀態的純 reducer——所有轉移可窮舉測試，效果由 EmulatorClient 執行。
public enum ConnState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

public enum ConnEvent: Equatable, Sendable {
    case connectRequested
    case connectSucceeded
    case connectFailed
    case streamBroken
    case stopRequested
}

public enum ConnEffect: Equatable, Sendable {
    case startConnect
    case scheduleReconnect(attempt: Int)
    case none
}

public enum ConnReducer {
    public static func reduce(_ state: ConnState, _ event: ConnEvent)
        -> (ConnState, ConnEffect)
    {
        switch (state, event) {
        case (.disconnected, .connectRequested):
            return (.connecting, .startConnect)
        case (.connecting, .connectSucceeded),
             (.reconnecting, .connectSucceeded):
            return (.connected, .none)
        case (.connecting, .connectFailed):
            return (.reconnecting(attempt: 0), .scheduleReconnect(attempt: 0))
        case (.reconnecting(let n), .connectFailed):
            return (.reconnecting(attempt: n + 1), .scheduleReconnect(attempt: n + 1))
        case (.connected, .streamBroken):
            return (.reconnecting(attempt: 0), .scheduleReconnect(attempt: 0))
        case (_, .stopRequested):
            return (.disconnected, .none)
        default:
            return (state, .none)  // 其餘組合為 no-op（冪等）
        }
    }
}
