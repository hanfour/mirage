import AVFoundation
import Foundation
import MirageCore

/// CoreAudio 出口：AVAudioEngine + AVAudioSourceNode，從環形緩衝拉樣本。
///
/// render block 跑在即時執行緒——**只做一次 memcpy 與補零**，不配置、不加鎖、不 log。
/// 所有轉換與配置都已在生產者端（AudioChunk.fromS16LE）完成。
@MainActor
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let ring: AudioRingBuffer
    private var node: AVAudioSourceNode?
    private(set) var isMuted = false

    init(ring: AudioRingBuffer) { self.ring = ring }

    /// 啟動失敗一律降級為「無音訊」——音訊絕不可拖垮鏡像主功能（畫面與輸入不受影響）。
    func start() {
        guard node == nil else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000, channels: 2, interleaved: true) else {
            print("[audio] 無法建立 48k/stereo/Float32 格式，降級為無音訊")
            return
        }
        let ring = self.ring   // 只捕捉 sink（@unchecked Sendable），不捕捉 self
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first,
                  let dst = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let wanted = Int(frameCount) * 2                 // interleaved stereo
            let got = ring.read(into: dst, count: wanted)
            if got < wanted {
                dst.advanced(by: got).update(repeating: 0, count: wanted - got)
            }
            return noErr
        }
        self.node = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            print("[audio] engine 啟動失敗，降級為無音訊：\(error)")
            self.node = nil
        }
    }

    /// macOS 沒有原生 per-app 音量——不給靜音等於玩家只能把整台 Mac 靜音。
    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    func stop() {
        engine.stop()
        node = nil
    }
}
