import Foundation

public enum InstanceFailure: Sendable, Equatable {
    case emulatorNotFound(URL)
    case avdNotFound(URL)
    case avdInUse(consolePort: Int)
    case launchTimedOut
    case bootTimedOut
    case abnormalExit
}

public enum InstanceState: Sendable, Equatable {
    case stopped
    case launching(since: Date)
    case booting(since: Date)
    case running
    case restarting
    case stopping
    case failed(InstanceFailure)
    case external

    public static let launchTimeoutSeconds: TimeInterval = 30
    public static let bootTimeoutSeconds: TimeInterval = 120
    public static let autoRestartWindowSeconds: TimeInterval = 60

    public func next(
        event: InstanceEvent,
        now: Date,
        lastRestartAt: Date? = nil
    ) -> InstanceStateTransition {
        let state = self
        func unchanged() -> InstanceStateTransition {
            InstanceStateTransition(state: state, action: .none, lastRestartAt: lastRestartAt)
        }

        func failed(_ failure: InstanceFailure) -> InstanceStateTransition {
            InstanceStateTransition(state: .failed(failure), action: .showFailure(failure),
                                     lastRestartAt: lastRestartAt)
        }

        if case .external = state {
            return unchanged()
        }

        switch (state, event) {
        case (.stopped, .launchRequested):
            return InstanceStateTransition(state: .launching(since: now), action: .launchProcess,
                                            lastRestartAt: nil)
        case (.stopped, .launchFailed(let failure)),
             (.launching(_), .launchFailed(let failure)),
             (.restarting, .launchFailed(let failure)):
            return failed(failure)
        case (.failed(_), .userRestartRequested):
            return InstanceStateTransition(state: .launching(since: now), action: .launchProcess,
                                            lastRestartAt: nil)
        case (.launching(_), .launchStarted):
            return InstanceStateTransition(state: .launching(since: now), action: .none,
                                            lastRestartAt: lastRestartAt)
        case (.launching(let since), .discoveryFileAppeared):
            if now.timeIntervalSince(since) >= Self.launchTimeoutSeconds {
                return failed(.launchTimedOut)
            }
            return InstanceStateTransition(state: .booting(since: since), action: .none,
                                            lastRestartAt: lastRestartAt)
        case (.launching(let since), .timeElapsed)
            where now.timeIntervalSince(since) >= Self.launchTimeoutSeconds:
            return failed(.launchTimedOut)
        case (.booting(let since), .booted):
            if now.timeIntervalSince(since) >= Self.bootTimeoutSeconds {
                return failed(.bootTimedOut)
            }
            return InstanceStateTransition(state: .running, action: .none,
                                            lastRestartAt: lastRestartAt)
        case (.booting(let since), .timeElapsed)
            where now.timeIntervalSince(since) >= Self.bootTimeoutSeconds:
            return failed(.bootTimedOut)
        case (.restarting, .launchStarted):
            return InstanceStateTransition(state: .launching(since: now), action: .none,
                                            lastRestartAt: now)
        case (.launching(_), .processExited), (.booting(_), .processExited),
             (.running, .processExited), (.restarting, .processExited):
            if let lastRestartAt,
               now.timeIntervalSince(lastRestartAt) <= Self.autoRestartWindowSeconds {
                return failed(.abnormalExit)
            }
            return InstanceStateTransition(state: .restarting, action: .launchProcess,
                                            lastRestartAt: now)
        case (.stopping, .processExited):
            return InstanceStateTransition(state: .stopped, action: .none, lastRestartAt: nil)
        case (_, .stopRequested):
            if case .stopped = state { return unchanged() }
            if case .stopping = state { return unchanged() }
            return InstanceStateTransition(state: .stopping, action: .stopProcess,
                                            lastRestartAt: lastRestartAt)
        default:
            return unchanged()
        }
    }
}

public enum InstanceEvent: Sendable, Equatable {
    case launchRequested
    case launchStarted
    case launchFailed(InstanceFailure)
    case discoveryFileAppeared
    case booted
    case processExited
    case stopRequested
    case userRestartRequested
    case timeElapsed
}

public enum InstanceAction: Sendable, Equatable {
    case none
    case launchProcess
    case stopProcess
    case showFailure(InstanceFailure)
}

public struct InstanceStateTransition: Sendable, Equatable {
    public let state: InstanceState
    public let action: InstanceAction
    /// Feed this value into the next transition to enforce the restart window.
    public let lastRestartAt: Date?

    public init(state: InstanceState, action: InstanceAction, lastRestartAt: Date?) {
        self.state = state
        self.action = action
        self.lastRestartAt = lastRestartAt
    }
}
