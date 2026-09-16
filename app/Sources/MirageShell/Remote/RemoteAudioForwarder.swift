import Foundation
import MirageCore

/// 同一把鎖涵蓋序號與送出，避免並行 write 讓批次在網路上超車。
final class RemoteAudioForwarder: AudioSink, @unchecked Sendable {
    private let controller: RemoteMirrorController
    private let lock = NSLock()
    private var sequence: UInt32 = 0

    init(controller: RemoteMirrorController) {
        self.controller = controller
    }

    func write(_ samples: [Float], rawByteCount: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        let format = AudioStreamFormat.standard
        guard controller.sessionState.hasAudio,
              !samples.isEmpty, samples.count % format.channels == 0 else { return }
        let payload = Self.s16LittleEndian(samples)
        controller.send(audio: RemoteAudioMessage(
            sentAtNanoseconds: RemoteEncoderClock.sentAtNanoseconds(), sequence: sequence,
            samplingRate: UInt32(format.samplingRate), channels: UInt8(format.channels), samples: payload))
        sequence &+= 1
    }

    static func s16LittleEndian(_ samples: [Float]) -> Data {
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            // 浮點誤差可能超出 [-1, 1)，必須先夾住上下界，否則 Int16 轉型會崩潰。
            let value = Int16(max(-32768, min(32767, (sample * 32768).rounded())))
            let bits = UInt16(bitPattern: value)
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return bytes
    }
}
