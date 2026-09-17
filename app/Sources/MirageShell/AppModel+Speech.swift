import Foundation
import MirageCore

/// 語音轉文字的接線（規格 `docs/specs/2026-09-16-speech-to-text-design.md`）。
///
/// 段落的**開始**由 `SpeechTranscriberSink` 在收到樣本時觸發，**結束**由本檔的
/// `advanceSpeechSegment` 依每秒監測迴圈的封包數判斷。分成兩處是因為監測迴圈一秒
/// 才跑一次，等它開段會把語音訊息的開頭整整一秒丟掉，而「沒有封包」這個訊號
/// 只有監測迴圈看得到。
extension AppModel {
    /// 選單列切換。第一次開啟才要授權，關閉時不撤銷授權也不重問。
    /// `persist` 為 true（使用者從選單列切換）才寫入下次啟動沿用的設定。
    func toggleSpeech(persist: Bool = true) {
        if speechEnabled {
            setSpeechEnabled(false)
            if persist { launchPreferences.speechEnabled = false }
            return
        }
        let transcriber = speechTranscriber ?? makeSpeechTranscriber()
        speechTranscriber = transcriber
        transcriber.prepare { [weak self] ready in
            guard let self else { return }
            if ready {
                self.setSpeechEnabled(true)
                if persist { self.launchPreferences.speechEnabled = true }
            } else {
                // 不可用的原因寫在選單列那一項，功能保持關閉。
                self.menuBar?.updateSpeech(on: false, unavailableReason: transcriber.unavailableReason)
            }
        }
    }

    private func makeSpeechTranscriber() -> SpeechTranscriber {
        SpeechTranscriber { [weak self] transcript in
            guard let self else { return }
            self.speechText = transcript.text
            // 手機把它當第二螢幕在看時，字幕只顯示在 Mac 上等於看不到。
            self.remote?.send(speech: transcript.text, isFinal: transcript.isFinal)
        }
    }

    private func setSpeechEnabled(_ on: Bool) {
        speechEnabled = on
        if !on {
            speechTranscriber?.stop()
            speechText = ""
        }
        menuBar?.updateSpeech(on: on, unavailableReason: speechTranscriber?.unavailableReason)
        refreshAudioFanOut()
    }

    /// 依目前開啟的功能組出音訊 sink。手機遙控與語音轉文字可以同時開，
    /// 所以 secondary 是 `FanOutAudioSink` 而不是單一 sink；兩者都關時就是 `audioRing`
    /// 本身，與遙控上線前的行為完全一樣。
    ///
    /// **只有這一個地方決定音訊 sink 長什麼樣**：遙控與語音各自組一份的話，
    /// 後開的那個會把先開的靜默蓋掉。
    func currentAudioSink() -> any AudioSink {
        var downstream: [any AudioSink] = []
        if let forwarder = remoteAudioForwarder { downstream.append(forwarder) }
        if speechEnabled, let transcriber = speechTranscriber {
            downstream.append(SpeechTranscriberSink(transcriber: transcriber))
        }
        guard !downstream.isEmpty else { return audioRing }
        return BroadcastAudioSink(primary: audioRing, secondary: FanOutAudioSink(sinks: downstream))
    }

    /// 開關語音辨識之後重掛 sink。畫面那側不受影響，所以不走 `switchSink`。
    func refreshAudioFanOut() {
        let sink = currentAudioSink()
        activeAudioSink = sink
        let previous = instanceSwitchTask
        instanceSwitchTask = Task { @MainActor in
            await previous?.value
            await self.client.setAudioSink(sink)
        }
    }

    /// 每秒監測迴圈呼叫。只處理段落結束；開始由 sink 觸發（見本檔開頭）。
    func advanceSpeechSegment(packets: Int) {
        guard speechEnabled, let transcriber = speechTranscriber else { return }
        let (next, event) = speechSegmenter.observing(packets: packets)
        speechSegmenter = next
        if event == .ended { transcriber.endSegment() }
    }
}
