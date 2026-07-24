import Testing
@testable import MirageCore

@Suite struct PowerStateTests {
    @Test func legalSuspendWakeCycle() {
        var s = PowerState.active
        s = PowerReducer.reduce(s, .suspendRequested); #expect(s == .suspending)
        s = PowerReducer.reduce(s, .snapshotSaved);    #expect(s == .suspended)
        s = PowerReducer.reduce(s, .wakeRequested);    #expect(s == .waking)
        s = PowerReducer.reduce(s, .snapshotLoaded);   #expect(s == .active)
    }

    @Test func illegalTransitionsAreNoOp() {
        #expect(PowerReducer.reduce(.active, .wakeRequested) == .active)
        #expect(PowerReducer.reduce(.suspended, .suspendRequested) == .suspended)
        #expect(PowerReducer.reduce(.waking, .suspendRequested) == .waking)
    }
}
