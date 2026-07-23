import Testing
@testable import MirageCore

@Suite struct ConnectionStateMachineTests {
    @Test func happyPath() {
        var (s, e) = ConnReducer.reduce(.disconnected, .connectRequested)
        #expect(s == .connecting)
        #expect(e == .startConnect)
        (s, e) = ConnReducer.reduce(s, .connectSucceeded)
        #expect(s == .connected)
        #expect(e == .none)
    }

    @Test func streamBrokenTriggersReconnectWithAttemptZero() {
        let (s, e) = ConnReducer.reduce(.connected, .streamBroken)
        #expect(s == .reconnecting(attempt: 0))
        #expect(e == .scheduleReconnect(attempt: 0))
    }

    @Test func reconnectFailureIncrementsAttempt() {
        let (s, e) = ConnReducer.reduce(.reconnecting(attempt: 2), .connectFailed)
        #expect(s == .reconnecting(attempt: 3))
        #expect(e == .scheduleReconnect(attempt: 3))
    }

    @Test func reconnectSuccessResets() {
        let (s, e) = ConnReducer.reduce(.reconnecting(attempt: 5), .connectSucceeded)
        #expect(s == .connected)
        #expect(e == .none)
    }

    @Test func initialConnectFailureGoesToReconnecting() {
        let (s, e) = ConnReducer.reduce(.connecting, .connectFailed)
        #expect(s == .reconnecting(attempt: 0))
        #expect(e == .scheduleReconnect(attempt: 0))
    }

    @Test func stopFromAnyStateDisconnects() {
        for from in [ConnState.connecting, .connected, .reconnecting(attempt: 3)] {
            let (s, e) = ConnReducer.reduce(from, .stopRequested)
            #expect(s == .disconnected)
            #expect(e == .none)
        }
    }
}
