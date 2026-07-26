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
///
/// **為什麼要多一道 `MIRAGE_LIVE_AUDIO` 閘門（比照既有 `MIRAGE_LIVE_MMAP` 慣例，
/// 見 `EmulatorClientReconnectTests.liveUnaryMmapDeliversFrames`）**：本專案文件指定的
/// 覆蓋率量測指令是 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`
/// （見 `RESULTS-p1a.md` 驗收 4 節）——這條指令會把所有活體測試（含本測試）一起跑，
/// 但只有 `scripts/verify_audio.sh` 才會先觸發 guest 發聲；跟其他活體測試併發排隊時，
/// 輪到本測試的 5 秒取樣窗口時鈴聲往往早已播畢，導致 `writes` 斷言不穩定失敗
/// （實測量到 41、0），把「預期中沒觸發發聲」誤判成「真的壞了」。掛在通用的
/// `MIRAGE_LIVE` 下會讓覆蓋率量測指令無謂地紅掉；只有明確知道前置條件已滿足的呼叫端
/// （目前只有 `verify_audio.sh`）才會額外設 `MIRAGE_LIVE_AUDIO=1`。
@Suite struct AudioLiveTests {
    @Test func realEmulatorDeliversAudioPackets() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MIRAGE_LIVE"] == "1", env["MIRAGE_LIVE_AUDIO"] == "1" else { return }
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
