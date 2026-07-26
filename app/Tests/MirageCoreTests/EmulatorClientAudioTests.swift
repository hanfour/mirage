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
}
