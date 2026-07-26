import Foundation
import Testing
@testable import MirageCore

/// 以 48kHz/stereo 的真實節奏排空環形緩衝——複製 `AudioPlayer` 的 `AVAudioSourceNode`
/// render callback 行為（見 `Sources/MirageApp/Audio/AudioPlayer.swift`），只是這裡用
/// `Task.sleep` 節流取代即時執行緒回呼。960 samples／10ms = 96,000 samples/秒，精確
/// 對齊 `AudioStreamFormat.standard` 的 48kHz × 2ch。
///
/// **這一步不可省略**：環形緩衝只有 200ms 天花板（19_200 samples）。若沒有消費者，
/// 實測幾秒內就會填滿——之後每包都算 overrun 而非 write，`writes` 會卡在 ~17～20
/// 不再增加，跟 guest 有沒有在發聲無關（本檔案曾量到 writes=17, overruns=436,
/// depth 貼著容量上限；接上這個 drain 後才量到 writes 隨時間正常累積）。
private func drainRingAtRealTimeRate(_ ring: AudioRingBuffer) async {
    let quantum = 960
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
    defer { scratch.deallocate() }
    while !Task.isCancelled {
        _ = ring.read(into: scratch, count: quantum)
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// 活體：真模擬器 → streamAudio → 環形緩衝。預設 skip，MIRAGE_LIVE=1 開啟。
/// guest 必須正在發聲才會有封包——由 scripts/verify_audio.sh 負責先觸發發聲。
@Suite struct AudioLiveTests {
    @Test func realEmulatorDeliversAudioPackets() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let ring = AudioRingBuffer()
        let client = EmulatorClient()
        await client.setAudioSink(ring)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)

        let drain = Task { await drainRingAtRealTimeRate(ring) }
        try await Task.sleep(for: .seconds(5))
        let stats = ring.stats
        drain.cancel()
        await client.stop()

        print("[audio-live] writes=\(stats.writes) depth=\(stats.depthSamples) " +
              "under=\(stats.underruns) over=\(stats.overruns)")
        // 每 20–30ms 一包（proto）→ 5 秒至少 150 包。門檻取一半留裕度。
        #expect(stats.writes >= 75, "guest 是否正在發聲？先跑 scripts/verify_audio.sh")
    }
}
