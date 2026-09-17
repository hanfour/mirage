import Testing
import MirageCore

@Suite struct SpeechSegmentTextTests {
    @Test func nonEmptyResultsAreShownAsIs() {
        let (next, shown) = SpeechSegmentText().observing("你好")
        #expect(shown == "你好")
        #expect(next.observing("你好嗎").1 == "你好嗎")
    }

    /// 實測（2026-09-17）：逐字結果長到 18 字，最終結果回傳空字串，字幕被清掉。
    @Test func emptyFinalKeepsLastRecognizedText() {
        let (heard, _) = SpeechSegmentText().observing("你好嗎")
        #expect(heard.observing("").1 == "你好嗎")
    }

    /// 整段都沒辨識出字（遊戲音樂、雜音）時不送任何東西，上一則字幕留著。
    @Test func segmentWithNothingRecognizedShowsNothing() {
        let (silent, shown) = SpeechSegmentText().observing("")
        #expect(shown == nil)
        #expect(silent.observing("").1 == nil)
    }

    @Test func observingDoesNotChangeOriginal() {
        let initial = SpeechSegmentText()
        _ = initial.observing("你好")
        #expect(initial == SpeechSegmentText())
        #expect(initial.observing("").1 == nil)
    }
}
