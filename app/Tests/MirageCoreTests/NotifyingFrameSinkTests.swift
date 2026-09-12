import Foundation
import Testing
@testable import MirageCore

@Suite(.timeLimit(.minutes(1))) struct NotifyingFrameSinkTests {
    private func frame(_ width: Int) -> Frame {
        Frame(width: width, height: 1, rgba: Data(count: width * 4))
    }

    @Test func notificationsCoalesceAndTakeOnlyLatest() async throws {
        let sink = NotifyingFrameSink()
        var iterator = sink.signals.makeAsyncIterator()
        _ = await iterator.next() // 訂閱建立的初始檢查
        sink.put(frame(1))
        sink.put(frame(2))
        sink.put(frame(3))
        sink.finish()
        let signal = await iterator.next()
        #expect(signal != nil)
        let latest = try #require(sink.takeLatest())
        #expect(latest.width == 3)
        #expect(sink.takeLatest() == nil)
        let end = await iterator.next()
        #expect(end == nil)
        #expect(sink.stats() == FrameCounterSnapshot(arrived: 3, dropped: 2, rejected: 0))
    }

    @Test func broadcastPutsToBackingBoxAlsoSignal() async throws {
        let box = LatestFrameBox()
        let sink = NotifyingFrameSink(box: box)
        let broadcast = BroadcastFrameSink(primary: LatestFrameBox(), secondary: box)
        var iterator = sink.signals.makeAsyncIterator()
        _ = await iterator.next()
        broadcast.put(frame(8))
        let signal = await iterator.next()
        #expect(signal != nil)
        let remote = try #require(sink.takeLatest())
        #expect(remote.width == 8)
        #expect(broadcast.takeLatest()?.width == 8)
    }

    @Test func existingFrameIsNotLostDuringSubscription() async throws {
        let box = LatestFrameBox()
        box.put(frame(5))
        let sink = NotifyingFrameSink(box: box)
        var iterator = sink.signals.makeAsyncIterator()
        let signal = await iterator.next()
        #expect(signal != nil)
        let latest = try #require(sink.takeLatest())
        #expect(latest.width == 5)
    }

    @Test func invalidFramesDoNotWakeEncoder() async {
        let sink = NotifyingFrameSink()
        var iterator = sink.signals.makeAsyncIterator()
        _ = await iterator.next()
        sink.put(Frame(width: 2, height: 2, rgba: Data()))
        sink.finish()
        let end = await iterator.next()
        #expect(end == nil)
        #expect(sink.stats().rejected == 1)
    }

    @Test func replacementSubscriptionSurvivesOldFinish() async throws {
        let box = LatestFrameBox()
        let old = NotifyingFrameSink(box: box)
        let replacement = NotifyingFrameSink(box: box)
        var iterator = replacement.signals.makeAsyncIterator()
        _ = await iterator.next()
        old.finish()
        box.put(frame(7))
        let signal = await iterator.next()
        #expect(signal != nil)
        let latest = try #require(replacement.takeLatest())
        #expect(latest.width == 7)
    }

    @Test func notificationCanSynchronouslyReadWithoutDeadlock() {
        let box = LatestFrameBox()
        box.notifyAfterPut { _ = box.takeLatest() }
        box.put(frame(4))
        #expect(box.takeLatest() == nil)
        // 解除測試回呼對 box 的強參照。
        box.notifyAfterPut {}
    }

    @Test func firstFrameNeverWaitsForRateLimit() {
        let delay = RemoteEncodePacing.delay(lastEncodedAt: nil, now: .now, minimumInterval: .seconds(1))
        #expect(delay == .zero)
    }

    @Test func rateLimitUsesRemainingIntervalWithoutDebouncing() {
        let start = ContinuousClock.now
        for elapsed in [0, 1, 2, 10, 32] {
            let delay = RemoteEncodePacing.delay(lastEncodedAt: start, now: start + .milliseconds(elapsed),
                                                 minimumInterval: .milliseconds(33))
            #expect(delay == .milliseconds(33 - elapsed))
        }
        for elapsed in [33, 40, 250, 1000] {
            let delay = RemoteEncodePacing.delay(lastEncodedAt: start, now: start + .milliseconds(elapsed),
                                                 minimumInterval: .milliseconds(33))
            #expect(delay == .zero)
        }
    }

    @Test(arguments: [5, 30, 60]) func honorsConfiguredFPS(_ fps: Int) {
        let start = ContinuousClock.now
        let interval = Duration.nanoseconds(1_000_000_000 / Int64(fps))
        let before = RemoteEncodePacing.delay(lastEncodedAt: start, now: start + interval - .nanoseconds(1),
                                              minimumInterval: interval)
        let ready = RemoteEncodePacing.delay(lastEncodedAt: start, now: start + interval, minimumInterval: interval)
        #expect(before == .nanoseconds(1))
        #expect(ready == .zero)
    }
}
