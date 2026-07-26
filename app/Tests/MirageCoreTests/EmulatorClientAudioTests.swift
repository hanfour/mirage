import Foundation
import Testing
@testable import MirageCore

/// 可腳本化的假音訊 transport：記錄訂閱與 cancel 次數，依劇本送樣本或永掛。
final class MockAudioTransport: AudioTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _subscribeCount = 0
    private var _cancelCount = 0
    private let samplesPerPacket: [Float]

    init(samplesPerPacket: [Float] = [0.5, -0.5]) {
        self.samplesPerPacket = samplesPerPacket
    }

    var subscribeCount: Int { lock.lock(); defer { lock.unlock() }; return _subscribeCount }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }

    func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error> {
        lock.lock(); _subscribeCount += 1; lock.unlock()
        let samples = samplesPerPacket
        return AsyncThrowingStream { cont in
            cont.yield(AudioChunk(samples: samples))
            // 不 finish：模擬持續中的健康串流（也正是 proto 描述的「可能無限阻塞」）。
        }
    }

    func cancelStream() {
        lock.lock(); _cancelCount += 1; lock.unlock()
    }
}

@Suite struct EmulatorClientAudioTests {
    /// 連上後音訊封包必須流進 sink。用既有 MockTransport 讓連線走到 .connected。
    @Test func connectedClientWritesAudioIntoSink() async throws {
        let audio = MockAudioTransport()
        let ring = AudioRingBuffer(capacitySamples: 64)
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in ScriptedProbe([]) },
            makeAudioTransport: { _ in audio }
        )
        await client.setAudioSink(ring)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
        #expect(audio.subscribeCount >= 1)
        #expect(ring.stats.writes >= 1)
        #expect(ring.stats.depthSamples >= 2)
    }

    /// stop() 必須顯式 cancel 底層 RPC——否則 guest 靜音時串流永不結束。
    @Test func stopCancelsAudioStream() async throws {
        let audio = MockAudioTransport()
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in ScriptedProbe([]) },
            makeAudioTransport: { _ in audio }
        )
        await client.setAudioSink(AudioRingBuffer(capacitySamples: 64))
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
        #expect(audio.cancelCount >= 1)
    }

    /// 休眠即靜音、喚醒即恢復（spec 的「音訊跟畫面走」）。
    @Test func suspendStopsAudioAndWakeResumesIt() async throws {
        let audio = MockAudioTransport()
        let ring = AudioRingBuffer(capacitySamples: 1_024)
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in ScriptedProbe([]) },
            makeAudioTransport: { _ in audio }
        )
        await client.setAudioSink(ring)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        let subscribesBeforeSuspend = audio.subscribeCount
        await client.suspend()
        #expect(audio.cancelCount >= 1)
        await client.wake()
        try await Task.sleep(for: .milliseconds(300))
        #expect(audio.subscribeCount > subscribesBeforeSuspend)
        await client.stop()
    }

    /// 沒有 sink（App 尚未接上 AudioPlayer）時不得掛載、不得崩。
    @Test func noSinkMeansNoSubscription() async throws {
        let audio = MockAudioTransport()
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in ScriptedProbe([]) },
            makeAudioTransport: { _ in audio }
        )
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
        #expect(audio.subscribeCount == 0)
    }

    /// P1-e 終審 Important 1 的回歸守門員：`suspend()` 原本有 `channelBox != nil` 這半條
    /// guard，會讓「尚未連上（或重連退避期間）就關視窗」提早 return、power 卡在 `.active`，
    /// 等連線建立後 `connectedRun()` 照常 attach → 視窗已隱藏卻有聲音。拿掉後：
    ///   1. 未連線時 suspend 仍能把 power 推進 `.suspended`
    ///   2. 隨後首次連上時，attachStream/attachAudio 被 power guard 擋住（不出聲）
    ///   3. wake() 能把它救回來（真的開始訂閱音訊）
    /// 這條路徑先前零測試覆蓋（終審 parked 項），此測項補上。
    @Test func suspendBeforeFirstConnectStaysSilentUntilWake() async throws {
        let audio = MockAudioTransport()
        let ring = AudioRingBuffer(capacitySamples: 256)
        // 第一次健康探測失敗 → 進重連退避，模擬「還沒連上」的窗口；第二次才健康。
        // probe 必須是**單一實例**：makeHealthProbe 每次 ensureChannel() 都會被呼叫，
        // 若在閉包內新建，劇本每輪都從頭來 → 永遠失敗、永遠連不上（比照既有
        // EmulatorClientReconnectTests 捕捉單一 probe 的寫法）。
        let probe = ScriptedProbe([.failed])
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in probe },
            makeAudioTransport: { _ in audio },
            sleeper: { _ in try await Task.sleep(for: .milliseconds(50)) }
        )
        // 用公開的 powerStates 串流觀察狀態，不為測試在產品碼上開後門。
        // PowerStateRecorder 是 EmulatorClientReconnectTests 既有的假件，直接沿用。
        let seen = PowerStateRecorder()
        Task { [client] in
            for await p in client.powerStates { await seen.record(p) }
        }
        await client.setAudioSink(ring)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)

        // 連線尚未建立的窗口內關視窗
        await client.suspend()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await seen.items.contains(PowerState.suspended),
                "未連線時 suspend 必須仍能進入 .suspended（否則重連後會在視窗隱藏時出聲）")

        // 讓重連迴圈跑完並連上——休眠中不得訂閱音訊
        try await Task.sleep(for: .milliseconds(400))
        #expect(audio.subscribeCount == 0, "休眠期間即使連線建立也不得掛載音訊")

        // 喚醒後才真的開始訂閱
        await client.wake()
        try await Task.sleep(for: .milliseconds(200))
        #expect(audio.subscribeCount >= 1, "wake() 必須把音訊救回來")
        await client.stop()
    }
}
