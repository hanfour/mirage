import Foundation
import Testing
@testable import MirageCore

/// 以 48kHz/stereo 的真實節奏排空環形緩衝，節流頻率比照 `AudioPlayer` 的
/// `AVAudioSourceNode` render callback（見 `Sources/MirageShell/Audio/AudioPlayer.swift`）：
/// 960 samples／10ms = 96,000 samples/秒，精確對齊 `AudioStreamFormat.standard` 的
/// 48kHz × 2ch，用 `Task.sleep` 節流取代即時執行緒回呼。
///
/// **2026-08-03 起與 `AudioPlayer` 已經分岔，不再是「複製其行為」**：`AudioPlayer` 走
/// `readStereo`（有 pre-roll，未蓄滿門檻前回 0 且不計 underrun）；這裡故意仍走
/// `read(into:count:)`（無 pre-roll，一律照常排水）。這是刻意的選擇，不是遺漏——本測試
/// 只斷言 `stats.writes >= 75`（見下方），驗的是**生產端**（`EmulatorClient` 有沒有把
/// 封包送進緩衝），不是消費端的蓄水行為；用哪一種讀法排水對這個斷言沒有影響，
/// 換成 `readStereo` 反而會引入蓄水延遲，讓「多久排空一次」這個與本測試斷言無關的
/// 細節變成新的不穩定因子。
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
    // 原本是 `guard ... else { print(...); return }`——那行 print 是為了讓「回報 passed 但零驗證」
    // 不至於完全靜默（終審 Minor 7）。改用 .enabled(if:) 之後不需要它了：測試會如實顯示為
    // skipped，訊息就是下面這個 comment，而且是測試框架自己報的，不靠人記得去 grep stdout。
    @Test(.enabled(if: LiveGate.audio,
                   "需 MIRAGE_LIVE=1 且 MIRAGE_LIVE_AUDIO=1；請跑 scripts/verify_audio.sh"))
    func realEmulatorDeliversAudioPackets() async throws {
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
