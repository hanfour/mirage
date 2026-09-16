import AVFoundation
import CoreAudio
import Foundation
import MirageCore

/// CoreAudio 出口：AVAudioEngine + AVAudioSourceNode，從環形緩衝拉樣本。
///
/// render block 跑在即時執行緒——**只做一次 memcpy 與補零**，不配置、不加鎖、不 log。
/// 所有轉換與配置都已在生產者端（AudioChunk.fromS16LE）完成。
@MainActor
final class AudioPlayer {
    /// 換輸出裝置時整顆換掉，不是 var 只為了可測。**沿用同一顆 engine 換裝置會壞**：
    /// 實測 stop → 改 `kAudioOutputUnitProperty_CurrentDevice` → start 之後 `engine.start()`
    /// 不報錯，但 render block 再也不被呼叫，環形緩衝塞滿、每秒 84 包全部溢位丟棄。
    private var engine = AVAudioEngine()
    private let ring: AudioRingBuffer
    private var node: AVAudioSourceNode?
    private(set) var isMuted = false
    /// 目前輸出綁在哪個裝置。`AVAudioEngine` 在 start 時綁定一次就不再跟隨系統變更，
    /// 所以要自己記住綁的是誰，才分得出「系統換了裝置」與「同一個裝置的其他通知」。
    private var boundDevice: AudioDeviceID?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(ring: AudioRingBuffer) { self.ring = ring }

    /// 啟動失敗一律降級為「無音訊」——音訊絕不可拖垮鏡像主功能（畫面與輸入不受影響）。
    func start() {
        guard node == nil else { return }
        // 明確綁到「現在」的預設輸出。不做這件事的話，engine 會綁在它第一次啟動時
        // 的裝置上：耳機在 Mirage 之後才連上時，聲音會一路送到內建喇叭，而所有
        // 統計（交付率、緩衝深度、排空速率）全部正常，看數字完全查不出來。
        bindToCurrentDefaultOutput()
        // `interleaved: false` 是硬性要求，不是偏好：`engine.connect(_:to:format:)`（見下方）
        // 只接受 deinterleaved，傳 interleaved 會讓它丟 `kAudioUnitErr_FormatNotSupported`
        // (-10868) 的 **NSException**。那是 Obj-C 例外，下面那個 `do/catch` 攔不到（它本來
        // 也只包住 `engine.start()`）——例外會在 `@MainActor` 上把呼叫端 `startLifecycle()`
        // 的執行整個扯斷，MainActor 自此不再 drain，於是 `client.states` 的消費者永遠收不到
        // 值（橫幅卡在「未連線」）、MTKView 的 draw 停止（`fps=` 恆為 0）。這正是 Mirage 的
        // 鏡像顯示自 P1-a 起從未運作過的原因，而它被誤記為「螢幕鎖定」達三個階段。
        // 完整證據見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md`。
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000, channels: 2, interleaved: false) else {
            print("[audio] 無法建立 48k/stereo/Float32 格式，降級為無音訊")
            return
        }
        let ring = self.ring   // 只捕捉 sink（@unchecked Sendable），不捕捉 self
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            // deinterleaved：左右聲道各自一個 buffer。取不到就整塊不動（維持 CoreAudio
            // 給的靜音內容）——寧可沒聲音，也不對著未知佈局寫入。宣告的格式是 2ch
            // deinterleaved，這條 guard 在實務上不可達，留作防禦下限。
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            let wanted = Int(frameCount)
            let got = ring.readStereo(left: left, right: right, frames: wanted)
            if got < wanted {
                left.advanced(by: got).update(repeating: 0, count: wanted - got)
                right.advanced(by: got).update(repeating: 0, count: wanted - got)
            }
            return noErr
        }
        self.node = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            observeDefaultOutputChanges()
        } catch {
            print("[audio] engine 啟動失敗，降級為無音訊：\(error)")
            // 終審 Minor 5：失敗路徑必須 detach，否則 engine 留著一個已 attach/connect
            // 但從未成功 start 的半掛載 node——若未來重試 start()，guard node == nil
            // 這條早退會失效（node 早被設回 nil 了不是問題），但 engine 內部仍記著舊
            // node 的 attach/connect 狀態，可能造成資源累積或重複 connect 的錯誤。
            engine.detach(node)
            self.node = nil
        }
    }

    /// 讀系統目前的預設輸出裝置，讀不到回 nil（此時沿用 engine 自己選的，不強行改）。
    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &defaultOutputAddress, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// 把 engine 的輸出單元指到目前的預設裝置。**必須在 engine 停止時做**，
    /// 執行中改這個屬性會失敗。
    private func bindToCurrentDefaultOutput() {
        guard let device = Self.defaultOutputDevice(), let unit = engine.outputNode.audioUnit else { return }
        var id = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr {
            boundDevice = device
        } else {
            print("[audio] 無法綁定輸出裝置 \(device)：OSStatus \(status)，沿用 engine 預設")
        }
    }

    /// 系統換預設輸出時重新綁定。只在真的換了裝置時重建，同一個裝置的其他通知忽略，
    /// 否則使用者調個音量都會讓聲音中斷一次。
    private func observeDefaultOutputChanges() {
        guard deviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rebindIfDefaultOutputChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, DispatchQueue.main, block)
        if status == noErr {
            deviceListener = block
        } else {
            print("[audio] 無法監聽預設輸出變更：OSStatus \(status)，換裝置後需重啟 Mirage")
        }
    }

    private func rebindIfDefaultOutputChanged() {
        guard let device = Self.defaultOutputDevice(), device != boundDevice else { return }
        let wasMuted = isMuted
        stop()
        engine = AVAudioEngine()
        start()
        setMuted(wasMuted)
        print("[audio] 預設輸出已變更，重新綁定到裝置 \(device)")
    }

    /// macOS 沒有原生 per-app 音量——不給靜音等於玩家只能把整台 Mac 靜音。
    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    /// 終審 Minor 5：接上真實呼叫端（見 AppDelegate.swift 的 AppDelegate.applicationWillTerminate），
    /// 不再是死碼。停止 engine 並 detach node——對稱 start() 失敗路徑的 detach，避免任何
    /// 「engine 記得一個已 attach 但邏輯上已停用的 node」的半掛載狀態。
    func stop() {
        engine.stop()
        if let node {
            engine.detach(node)
        }
        node = nil
    }
}
