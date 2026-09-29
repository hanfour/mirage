import Foundation
import Testing
@testable import MirageCore

@Suite("InstanceState")
struct InstanceStateTests {
    private let origin = Date(timeIntervalSince1970: 1_000)

    @Test func launchDiscoveryAndBootedHappyPath() {
        let launching = next(.stopped, .launchRequested)
        #expect(launching.state == .launching(since: origin))
        #expect(launching.action == .launchProcess)

        let started = next(launching.state, .launchStarted, seconds: 1)
        #expect(started.state == .launching(since: origin.addingTimeInterval(1)))
        let booting = next(started.state, .discoveryFileAppeared, seconds: 2)
        #expect(booting.state == .booting(since: origin.addingTimeInterval(1)))
        #expect(booting.action == .none)

        let running = next(booting.state, .booted, lastRestartAt: booting.lastRestartAt)
        #expect(running.state == .running)
        #expect(running.action == .none)
    }

    @Test func unexpectedExitRestartsOnceAndRecordsTime() {
        let transition = next(.running, .processExited)
        #expect(transition.state == .restarting)
        #expect(transition.action == .launchProcess)
        #expect(transition.lastRestartAt == origin)

        let started = next(.restarting, .launchStarted, seconds: 2,
                           lastRestartAt: transition.lastRestartAt)
        #expect(started.state == .launching(since: origin.addingTimeInterval(2)))
        #expect(started.action == .none)
        #expect(started.lastRestartAt == origin.addingTimeInterval(2))
    }

    @Test func processExitDuringLaunchOrBootRequestsOneRestart() {
        for state in [InstanceState.launching(since: origin), .booting(since: origin)] {
            let transition = next(state, .processExited)
            #expect(transition.state == .restarting)
            #expect(transition.action == .launchProcess)
            #expect(transition.lastRestartAt == origin)
        }
    }

    @Test func secondExitAfterFiftyNineSecondsFails() {
        let firstExit = next(.running, .processExited)
        let restarted = next(.restarting, .launchStarted, seconds: 2,
                             lastRestartAt: firstExit.lastRestartAt)
        let transition = next(.running, .processExited, seconds: 61,
                              lastRestartAt: restarted.lastRestartAt)
        #expect(transition.state == .failed(.abnormalExit))
        #expect(transition.action == .showFailure(.abnormalExit))
        #expect(transition.lastRestartAt == restarted.lastRestartAt)
    }

    @Test func secondExitAfterSixtyOneSecondsCanRestartAgain() {
        let firstExit = next(.running, .processExited)
        let restarted = next(.restarting, .launchStarted, seconds: 2,
                             lastRestartAt: firstExit.lastRestartAt)
        let now = origin.addingTimeInterval(63)
        let transition = next(.running, .processExited, seconds: 63,
                              lastRestartAt: restarted.lastRestartAt)
        #expect(transition.state == .restarting)
        #expect(transition.action == .launchProcess)
        #expect(transition.lastRestartAt == now)
    }

    @Test func launchTimeoutShowsFailureAtThirtySeconds() {
        let transition = next(.launching(since: origin), .timeElapsed, seconds: 30)
        #expect(transition.state == .failed(.launchTimedOut))
        #expect(transition.action == .showFailure(.launchTimedOut))
    }

    @Test func bootTimeoutUsesTotalLaunchDuration() {
        let transition = next(.booting(since: origin), .timeElapsed, seconds: 120)
        #expect(transition.state == .failed(.bootTimedOut))
        #expect(transition.action == .showFailure(.bootTimedOut))
    }

    @Test func lateDiscoveryCannotSkipLaunchTimeout() {
        let transition = next(.launching(since: origin), .discoveryFileAppeared, seconds: 30)
        #expect(transition.state == .failed(.launchTimedOut))
    }

    @Test func lateBootedEventCannotSkipBootTimeout() {
        let transition = next(.booting(since: origin), .booted, seconds: 120)
        #expect(transition.state == .failed(.bootTimedOut))
    }

    @Test func userCanRestartAfterFailure() {
        let transition = next(.failed(.launchTimedOut), .userRestartRequested,
                              seconds: 5, lastRestartAt: origin)
        #expect(transition.state == .launching(since: origin.addingTimeInterval(5)))
        #expect(transition.action == .launchProcess)
        #expect(transition.lastRestartAt == nil)
    }

    @Test func launchFailurePreservesItsReasonAndRequestsDisplay() {
        let reason = InstanceFailure.avdNotFound(
            URL(fileURLWithPath: "/users/tester/.android/avd/mirage-game.ini"))
        let transition = next(.stopped, .launchFailed(reason))
        #expect(transition.state == .failed(reason))
        #expect(transition.action == .showFailure(reason))
    }

    @Test func stopRequestAndProcessExitDoNotRestart() {
        let stopping = next(.running, .stopRequested)
        #expect(stopping.state == .stopping)
        #expect(stopping.action == .stopProcess)

        let stopped = next(.stopping, .processExited, lastRestartAt: origin)
        #expect(stopped.state == .stopped)
        #expect(stopped.action == .none)
        #expect(stopped.lastRestartAt == nil)
    }

    @Test func stopRequestMovesEveryManagedActiveStateToStopping() {
        let activeStates: [InstanceState] = [
            .launching(since: origin),
            .booting(since: origin),
            .running,
            .restarting,
            .failed(.launchTimedOut),
        ]
        for state in activeStates {
            let transition = next(state, .stopRequested)
            #expect(transition.state == .stopping)
            #expect(transition.action == .stopProcess)
        }
    }

    @Test func externalStateIgnoresEveryEvent() {
        let events: [InstanceEvent] = [
            .launchRequested,
            .launchStarted,
            .launchFailed(.launchTimedOut),
            .discoveryFileAppeared,
            .booted,
            .processExited,
            .stopRequested,
            .userRestartRequested,
            .timeElapsed,
        ]
        for event in events {
            let transition = next(.external, event, lastRestartAt: origin)
            #expect(transition.state == .external)
            #expect(transition.action == .none)
            #expect(transition.lastRestartAt == origin)
        }
    }

    private func next(
        _ state: InstanceState,
        _ event: InstanceEvent,
        seconds: TimeInterval = 0,
        lastRestartAt: Date? = nil
    ) -> InstanceStateTransition {
        state.next(event: event, now: origin.addingTimeInterval(seconds),
                   lastRestartAt: lastRestartAt)
    }
}
