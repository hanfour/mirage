import Foundation
import MirageCore

/// 音訊扇出的一個下游：把樣本降成 16kHz 單聲道交給辨識器。
///
/// **段落的開始由這裡觸發，不是由每秒的監測迴圈**：監測迴圈一秒才跑一次，
/// 等它開段會把語音訊息的開頭整整一秒丟掉。結束仍由監測迴圈判斷，
/// 因為「沒有封包」這個訊號只有那裡看得到（見 `SpeechSegmenter`）。
final class SpeechTranscriberSink: AudioSink, @unchecked Sendable {
    private let transcriber: SpeechTranscriber

    init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
    }

    func write(_ samples: [Float], rawByteCount: Int? = nil) {
        // 降取樣在生產者執行緒做，與 AudioChunk.fromS16LE 同一個理由：
        // 轉換不得發生在即時執行緒上，而這裡不是即時執行緒。
        let mono = SpeechAudioConverter.monoAt16k(samples)
        guard !mono.isEmpty else { return }
        Task { @MainActor [transcriber] in
            if !transcriber.hasActiveSegment { transcriber.beginSegment() }
            transcriber.append(mono)
        }
    }
}
