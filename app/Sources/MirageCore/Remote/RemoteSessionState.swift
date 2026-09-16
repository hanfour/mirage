/// 單一手機連線的純 reducer（spec 第 3 節），比照 `ConnReducer`：轉移可窮舉，效果由
/// `RemoteServerCore` 執行（`requestKeyframe` → 重置送出佇列並通知編碼器；`releaseTouches`
/// → allocator 全放開並送進 InputQueue；`rejectBusy` → 計數）。
public struct RemoteSessionState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case waitingForPairing
        case connected
        case disconnected
    }

    public let phase: Phase
    public let hasVideo: Bool
    public let hasInput: Bool
    public let hasAudio: Bool

    public init(phase: Phase, hasVideo: Bool, hasInput: Bool, hasAudio: Bool) {
        self.phase = phase
        self.hasVideo = hasVideo
        self.hasInput = hasInput
        self.hasAudio = hasAudio
    }

    public static let initial = RemoteSessionState(phase: .waitingForPairing, hasVideo: false, hasInput: false, hasAudio: false)

    public var isViewerConnected: Bool { phase == .connected }

    /// video 是配對的必要連線；正常事件不會產生僅有 input 或 audio 的狀態。
    fileprivate func with(video: Bool, input: Bool, audio: Bool) -> RemoteSessionState {
        RemoteSessionState(phase: video || input || audio ? .connected : .disconnected, hasVideo: video, hasInput: input, hasAudio: audio)
    }
}

public enum RemoteSessionEvent: Sendable, Equatable {
    case videoOpened
    case inputOpened
    case audioOpened
    case videoClosed
    case inputClosed
    case audioClosed
    case stopRequested
}

public enum RemoteSessionEffect: Sendable, Equatable {
    case none
    case rejectBusy
    case requestKeyframe
    case releaseTouches
}

public enum RemoteSessionReducer {
    public static func reduce(_ state: RemoteSessionState, _ event: RemoteSessionEvent)
        -> (RemoteSessionState, RemoteSessionEffect)
    {
        switch event {
        case .videoOpened:
            guard !state.hasVideo else { return (state, .rejectBusy) }
            return (state.with(video: true, input: state.hasInput, audio: state.hasAudio), .requestKeyframe)
        case .inputOpened:
            guard state.hasVideo, !state.hasInput else { return (state, .rejectBusy) }
            return (state.with(video: state.hasVideo, input: true, audio: state.hasAudio), .none)
        case .audioOpened:
            guard state.hasVideo, !state.hasAudio else { return (state, .rejectBusy) }
            return (state.with(video: state.hasVideo, input: state.hasInput, audio: true), .none)
        case .audioClosed:
            guard state.hasAudio else { return (state, .none) }
            return (state.with(video: state.hasVideo, input: state.hasInput, audio: false), .none)
        case .videoClosed:
            guard state.hasVideo else { return (state, .none) }
            // 沿用 inputClosed 的釋放效果；video 關閉時整組配對失效。
            let (_, effect) = reduce(state, .inputClosed)
            return (state.with(video: false, input: false, audio: false), effect)
        case .inputClosed:
            guard state.hasInput else { return (state, .none) }
            return (state.with(video: state.hasVideo, input: false, audio: state.hasAudio), .releaseTouches)
        case .stopRequested:
            return (state.with(video: false, input: false, audio: false), state.hasInput ? .releaseTouches : .none)
        }
    }
}
