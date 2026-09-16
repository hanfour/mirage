public struct SpeechSegmenter: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case began, continued, ended, idle
    }

    public let silenceWindows: Int
    public let maxWindows: Int
    private let windows: Int
    private let silentWindows: Int

    public init(silenceWindows: Int = 1, maxWindows: Int = 60) {
        precondition(silenceWindows > 0)
        precondition(maxWindows > 0)
        self.silenceWindows = silenceWindows
        self.maxWindows = maxWindows
        self.windows = 0
        self.silentWindows = 0
    }

    private init(previous: Self, windows: Int, silentWindows: Int) {
        self.silenceWindows = previous.silenceWindows
        self.maxWindows = previous.maxWindows
        self.windows = windows
        self.silentWindows = silentWindows
    }

    public func observing(packets: Int) -> (SpeechSegmenter, Event) {
        precondition(packets >= 0)
        if windows == 0 {
            return packets > 0
                ? (Self(previous: self, windows: 1, silentWindows: 0), .began)
                : (self, .idle)
        }

        let silence = packets == 0 ? silentWindows + 1 : 0
        // SFSpeechRecognitionTask 有長度上限，不切會整段丟失。
        // 開始窗口也算一個，達上限就重設，讓下一個有封包的窗口能另開任務。
        // 先比較再遞增，避免極大門檻造成整數溢位。
        if windows >= maxWindows - 1 || silence >= silenceWindows {
            return (Self(previous: self, windows: 0, silentWindows: 0), .ended)
        }
        return (Self(previous: self, windows: windows + 1, silentWindows: silence), .continued)
    }
}
