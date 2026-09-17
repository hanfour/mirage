/// 一段語音辨識要顯示的文字。
///
/// 實測（2026-09-17，LINE 語音訊息）：裝置端辨識的逐字結果長到 18 字，
/// 播完送出的**最終結果卻是空字串**，直接拿去覆蓋字幕就是「完全沒有字幕」。
/// 所以空字串一律當成「沒有新資訊」，不論是逐字還是最終結果：
/// 有辨識過字就沿用最後一次的，整段都沒辨識出字就不顯示任何東西（回傳 nil），
/// 讓上一則字幕留在畫面上。每一段辨識用一個新的值。
public struct SpeechSegmentText: Sendable, Equatable {
    private let lastRecognized: String?

    public init() {
        lastRecognized = nil
    }

    private init(lastRecognized: String?) {
        self.lastRecognized = lastRecognized
    }

    public func observing(_ text: String) -> (SpeechSegmentText, String?) {
        let shown = text.isEmpty ? lastRecognized : text
        return (SpeechSegmentText(lastRecognized: shown), shown)
    }
}
