import Foundation
import MirageCore

/// P1-e 音訊：建立 CoreAudio 出口（AudioPlayer）、掛上環形緩衝當 EmulatorClient 的 sink、
/// 綁選單列靜音，並在要求時啟動 MIRAGE_AUDIO_LOG 觀測。
///
/// 獨立成 extension 檔（比照 AppModel+FullScreen.swift 的 Task 3 前例）：MirageApp.swift
/// 本體已滿 400 行，儲存屬性（audioRing/audioPlayer）留在本體，行為搬來這裡。
///
/// `startAudio()` 不能標 `private`——SE-0169 讓 `private` 只在同一個檔案內的 extension 之間
/// 互通，跨檔案（這裡 vs. MirageApp.swift 的 startLifecycle()）仍會被擋。`startAudioLogIfRequested()`
/// 只在本檔內被呼叫，維持 brief 原本的 `private`。
extension AppModel {
    /// 建立播放器 → 掛上 sink → 綁選單列。啟動失敗只降級為無音訊，不影響畫面與輸入。
    func startAudio() {
        let player = AudioPlayer(ring: audioRing)
        player.start()
        audioPlayer = player
        menuBar?.onToggleMute = { [weak self] in self?.toggleMute() }
        menuBar?.updateMute(player.isMuted)
        Task { [client, audioRing] in await client.setAudioSink(audioRing) }
        startAudioLogIfRequested()
    }

    func toggleMute() {
        guard let audioPlayer else { return }
        audioPlayer.setMuted(!audioPlayer.isMuted)
        menuBar?.updateMute(audioPlayer.isMuted)
    }

    /// MIRAGE_AUDIO_LOG=1：每秒一行健康摘要。這是**唯一能無頭驗證音訊的訊號**，
    /// verify_audio.sh 的斷言建立在它之上。格式沿用 MIRAGE_FPS_LOG 的單行可 grep 風格。
    private func startAudioLogIfRequested() {
        guard ProcessInfo.processInfo.environment["MIRAGE_AUDIO_LOG"] == "1" else { return }
        Task { [audioRing] in
            var lastWrites = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let s = audioRing.stats
                let depthMs = s.depthSamples * 1000 / (48_000 * 2)
                print("[audio] pkt=\(s.writes - lastWrites) sr=48000 ch=2 " +
                      "under=\(s.underruns) over=\(s.overruns) depth=\(depthMs)ms")
                lastWrites = s.writes
            }
        }
    }
}
