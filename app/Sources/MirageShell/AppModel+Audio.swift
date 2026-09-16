import Foundation
import MirageCore

/// P1-e 音訊：建立 CoreAudio 出口（AudioPlayer）、掛上環形緩衝當 EmulatorClient 的 sink、
/// 綁選單列靜音，持續偵測音訊供應並依 MIRAGE_AUDIO_LOG 決定是否印出統計。
///
/// 獨立成 extension 檔（比照 AppModel+FullScreen.swift 的 Task 3 前例）：AppModel.swift
/// 本體已滿 400 行，儲存屬性（audioRing/audioPlayer）留在本體，行為搬來這裡。
///
/// `startAudio()` 不能標 `private`，因為 SE-0169 讓 `private` 只在同一個檔案內的 extension 之間
/// 互通，跨檔案（這裡 vs. AppModel.swift 的 startLifecycle()）仍會被擋。`startAudioMonitoring()`
/// 只在本檔內被呼叫，因此維持 `private`。
extension AppModel {
    /// 建立播放器 → 掛上 sink → 綁選單列。啟動失敗只降級為無音訊，不影響畫面與輸入。
    func startAudio() {
        let player = AudioPlayer(ring: audioRing)
        player.start()
        audioPlayer = player
        menuBar?.onToggleMute = { [weak self] in self?.toggleMute() }
        menuBar?.updateMute(player.isMuted)
        // 生命週期可能晚於遙控啟動，必須沿用目前 sink 並與遠端切換共用順序。
        let previous = instanceSwitchTask
        instanceSwitchTask = Task { @MainActor in
            await previous?.value
            await self.client.setAudioSink(self.activeAudioSink)
        }
        startAudioMonitoring()
    }

    func toggleMute() {
        guard let audioPlayer else { return }
        audioPlayer.setMuted(!audioPlayer.isMuted)
        menuBar?.updateMute(audioPlayer.isMuted)
    }

    /// 偵測與觀測共用每秒統計，避免未開啟日誌時漏掉 emulator 異常。
    /// MIRAGE_AUDIO_LOG 只控制健康摘要，既有驗證腳本依賴其欄位格式。
    private func startAudioMonitoring() {
        let logRequested = ProcessInfo.processInfo.environment["MIRAGE_AUDIO_LOG"] == "1"
        Task { [weak self, audioRing] in
            var monitor = AudioSupplyMonitor()
            var lastWrites = 0
            var lastSamples = 0
            var lastWindowUptime = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                let window = audioRing.takePacketWindow()
                let windowEnd = Date().timeIntervalSince1970
                let windowUptime = ProcessInfo.processInfo.systemUptime
                let windowSeconds = windowUptime - lastWindowUptime
                lastWindowUptime = windowUptime
                let s = window.stats
                let depthMs = s.depthSamples * 1000 / (48_000 * 2)
                // `supply` 是這一秒實際供應量佔即時需求的百分比。
                //
                // **`pkt` 答不了這件事**：它數封包，而封包大小由 emulator 決定，本專案
                // 沒有任何地方強制它。D44 記載的「供應約為需求 94%」是拿 pkt 乘上一個
                // 假設的包大小推出來的——形狀（均勻不足、無缺口）可信，幅度不可信。
                // 這一項直接由累計樣本數算出，不經過任何假設。
                //
                // `pkt` 仍然要留著，但用途不同：它是「guest 有沒有在放音訊」的判準。
                // guest 停止輸出時 emulator 會關閉主機輸出裝置、送零個封包，而不是送
                // 靜音樣本；崩潰時則是封包照樣約 88 個而供應率剩 6.5%。兩者只有 pkt
                // 分得開，見 `AudioSupplyMonitor`。
                let supplied = s.writtenSamples - lastSamples
                let supplyPct = supplied * 100 / (48_000 * 2)
                let packets = s.writes - lastWrites
                let previousState = monitor.state
                monitor = monitor.observing(packets: packets, supplyPercent: supplyPct)
                switch AudioSupplyMonitor.notice(from: previousState, to: monitor.state) {
                case .degraded:
                    // 這一行的格式由 `audio_stats.sh` 的正規式綁著（結尾必須是 supply=N%），
                    // 不要在後面加欄位。給使用者的處理方式放在選單列那一項。
                    print("[audio] degraded reason=emulator-output-stalled pkt=\(packets) supply=\(supplyPct)%")
                case .recovered:
                    print("[audio] recovered pkt=\(packets) supply=\(supplyPct)%")
                case .cleared:
                    print("[audio] degraded-cleared reason=guest-audio-stopped pkt=\(packets) supply=\(supplyPct)%")
                case .none:
                    break
                }
                if monitor.state != previousState { self.menuBar?.updateAudioHealth(monitor.state) }
                if logRequested {
                    print("[audio] pkt=\(s.writes - lastWrites) smp=\(supplied) supply=\(supplyPct)% " +
                          "sr=48000 ch=2 under=\(s.underruns) over=\(s.overruns) " +
                          "primes=\(s.primes) ptimeouts=\(s.primeTimeouts) depth=\(depthMs)ms " +
                          window.logFields +
                          String(format: " window_end=%.6f window_seconds=%.6f", windowEnd, windowSeconds))
                }
                lastWrites = s.writes
                lastSamples = s.writtenSamples
            }
        }
    }
}
