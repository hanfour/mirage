import AVFoundation
import Foundation
import MirageCore
import Speech

/// 一段語音辨識出來的文字。`isFinal` 為 false 是播放中的逐字結果。
struct SpeechTranscript: Equatable, Sendable {
    let text: String
    let isFinal: Bool
}

/// 裝置端 zh-TW 語音辨識。**語音不離開這台機器**：`requiresOnDeviceRecognition`
/// 永遠是 true，設不起來就整個降級為不辨識，不退回雲端。
///
/// ⚠️ `recognitionTask` 的回呼在**主佇列**送出。第一版驗證時用 `DispatchSemaphore`
/// 在主執行緒等結果，直接卡死且沒有任何錯誤訊息，看起來就像「辨識不出來」。
/// 這個型別標 `@MainActor`，回呼與狀態都在同一個地方，不要改成自己開佇列等。
@MainActor
final class SpeechTranscriber {
    /// 辨識器要的格式，與 `SpeechAudioConverter.monoAt16k` 的輸出對齊。
    static let sampleRate = 16_000.0

    private let locale = Locale(identifier: "zh-TW")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 段落世代。`endSegment()` 只是告訴辨識器沒有更多音訊，**舊任務還活著**，
    /// 它稍後送出的最終結果如果直接去清狀態，會把已經開始的**新段落**一起清掉，
    /// 之後就在「開一段、被舊任務清掉」之間空轉，畫面再也不更新。
    /// 每個回呼帶著自己的世代，過期的一律忽略。
    private var generation = 0
    private let format: AVAudioFormat?
    private let onTranscript: (SpeechTranscript) -> Void

    /// 不可用時的原因，給選單列顯示。nil 表示可用。
    private(set) var unavailableReason: String?

    init(onTranscript: @escaping (SpeechTranscript) -> Void) {
        self.onTranscript = onTranscript
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                               channels: 1, interleaved: false)
        if format == nil { unavailableReason = "無法建立 16kHz 單聲道格式" }
    }

    /// 要求授權並確認裝置端 zh-TW 可用。未授權或不可用時設定 `unavailableReason`，
    /// 呼叫端據此把功能保持關閉，不影響音訊與畫面。
    func prepare(completion: @escaping (Bool) -> Void) {
        guard format != nil else { completion(false); return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                completion(self.finishPrepare(status: status))
            }
        }
    }

    private func finishPrepare(status: SFSpeechRecognizerAuthorizationStatus) -> Bool {
        guard status == .authorized else {
            unavailableReason = "語音辨識未授權（系統設定 → 隱私權與安全性 → 語音辨識）"
            return false
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            unavailableReason = "這台機器沒有可用的 zh-TW 辨識器"
            return false
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // 不退回雲端：語音是私人內容，寧可不做。
            unavailableReason = "zh-TW 不支援裝置端辨識，為保護隱私不使用雲端"
            return false
        }
        self.recognizer = recognizer
        unavailableReason = nil
        return true
    }

    /// 目前有沒有進行中的段落。呼叫端據此決定要不要開新的，不必自己記狀態。
    var hasActiveSegment: Bool { request != nil }

    /// 開一段新的辨識。已經有一段在跑時先收尾，不並行兩個任務。
    func beginSegment() {
        guard let recognizer else { return }
        endSegment()
        generation += 1
        let generation = self.generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, generation == self.generation else { return }
                if error != nil {
                    // 單段失敗不停用整個功能：下一段重新開始。
                    self.clearSegment()
                    return
                }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                if Self.logEnabled {
                    print("[speech] gen=\(generation) final=\(result.isFinal) len=\(text.count)")
                }
                self.onTranscript(SpeechTranscript(text: text, isFinal: result.isFinal))
                if result.isFinal { self.clearSegment() }
            }
        }
    }

    /// 餵樣本。呼叫端已經降成 16kHz 單聲道。沒有進行中的段落時直接丟棄。
    func append(_ monoSamples: [Float]) {
        guard let request, let format, !monoSamples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(monoSamples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(monoSamples.count)
        monoSamples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: monoSamples.count)
        }
        request.append(buffer)
    }

    /// 段落結束：告訴辨識器沒有更多音訊，等它送出最終結果後自行收尾。
    func endSegment() {
        request?.endAudio()
        request = nil
    }

    /// 診斷用：`MIRAGE_SPEECH_LOG=1` 時把每一則辨識結果印出來。
    /// 沒有它就只能從畫面猜辨識是不是還活著，而畫面不會告訴你「停在哪一段」。
    static let logEnabled = ProcessInfo.processInfo.environment["MIRAGE_SPEECH_LOG"] == "1"

    private func clearSegment() {
        request = nil
        task = nil
    }

    func stop() {
        endSegment()
        task?.cancel()
        task = nil
    }
}
