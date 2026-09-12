import Testing
@testable import MirageCore

@Suite struct RemoteSessionStateTests {
    private func state(_ phase: RemoteSessionState.Phase, video: Bool, input: Bool) -> RemoteSessionState {
        RemoteSessionState(phase: phase, hasVideo: video, hasInput: input)
    }

    @Test func initialIsWaitingWithNothingAttached() {
        #expect(RemoteSessionState.initial == state(.waitingForPairing, video: false, input: false))
        #expect(!RemoteSessionState.initial.isViewerConnected)
    }

    @Test func videoThenInputConnectsAndAsksForKeyframeOnce() {
        let (s1, e1) = RemoteSessionReducer.reduce(.initial, .videoOpened)
        #expect(s1 == state(.connected, video: true, input: false))
        #expect(e1 == .requestKeyframe)
        #expect(s1.isViewerConnected)
        let (s2, e2) = RemoteSessionReducer.reduce(s1, .inputOpened)
        #expect(s2 == state(.connected, video: true, input: true))
        #expect(e2 == .none)
    }

    @Test func inputRequiresVideo() {
        for from in [RemoteSessionState.initial, state(.disconnected, video: false, input: false)] {
            let (s, e) = RemoteSessionReducer.reduce(from, .inputOpened)
            #expect(s == from)
            #expect(e == .rejectBusy)
        }
    }

    @Test func secondSocketOnSamePathIsBusy() {
        let full = state(.connected, video: true, input: true)
        #expect(RemoteSessionReducer.reduce(full, .videoOpened) == (full, .rejectBusy))
        #expect(RemoteSessionReducer.reduce(full, .inputOpened) == (full, .rejectBusy))
    }

    @Test func closingVideoDisconnectsPairAndReleasesTouchesOnce() {
        let (s, e) = RemoteSessionReducer.reduce(state(.connected, video: true, input: true), .videoClosed)
        #expect(s == state(.disconnected, video: false, input: false))
        #expect(e == .releaseTouches)
        #expect(RemoteSessionReducer.reduce(s, .inputClosed) == (s, .none))
        #expect(RemoteSessionReducer.reduce(s, .videoClosed) == (s, .none))
    }

    @Test func closingLastSocketDisconnects() {
        let (s1, e1) = RemoteSessionReducer.reduce(state(.connected, video: true, input: false), .videoClosed)
        #expect(s1 == state(.disconnected, video: false, input: false))
        #expect(e1 == .none)
        let (s2, e2) = RemoteSessionReducer.reduce(state(.connected, video: false, input: true), .inputClosed)
        #expect(s2 == state(.disconnected, video: false, input: false))
        #expect(e2 == .releaseTouches)
    }

    @Test func closingInputAlwaysReleasesTouches() {
        let (s, e) = RemoteSessionReducer.reduce(state(.connected, video: true, input: true), .inputClosed)
        #expect(s == state(.connected, video: true, input: false))
        #expect(e == .releaseTouches)
    }

    @Test func closingSomethingNotOpenIsNoOp() {
        for from in [RemoteSessionState.initial, state(.connected, video: true, input: false), state(.disconnected, video: false, input: false)] {
            #expect(RemoteSessionReducer.reduce(from, .inputClosed) == (from, .none))
        }
        let videoOnlyInput = state(.connected, video: false, input: true)
        #expect(RemoteSessionReducer.reduce(videoOnlyInput, .videoClosed) == (videoOnlyInput, .none))
    }

    @Test func reconnectAfterDisconnectIsAllowedWithKeyframe() {
        let (s, e) = RemoteSessionReducer.reduce(state(.disconnected, video: false, input: false), .videoOpened)
        #expect(s == state(.connected, video: true, input: false))
        #expect(e == .requestKeyframe)
    }

    @Test func stopDisconnectsAndReleasesTouchesOnlyIfInputWasOpen() {
        let (s1, e1) = RemoteSessionReducer.reduce(state(.connected, video: true, input: true), .stopRequested)
        #expect(s1 == state(.disconnected, video: false, input: false))
        #expect(e1 == .releaseTouches)
        let (s2, e2) = RemoteSessionReducer.reduce(.initial, .stopRequested)
        #expect(s2 == state(.disconnected, video: false, input: false))
        #expect(e2 == .none)
    }
}
