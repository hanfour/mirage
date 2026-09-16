import Dispatch
import Testing
import MirageCore

@Suite struct FanOutAudioSinkTests {
    @Test func emptyListAcceptsWrites() {
        let sink = FanOutAudioSink()
        sink.write([1, -1])
        sink.write([])
        #expect(sink.sinks.isEmpty)
    }

    @Test func bothReceiveIdenticalSamplesAndByteCount() {
        let first = FanOutTestAudioSink()
        let second = FanOutTestAudioSink()
        let sink = FanOutAudioSink(sinks: [first, second])
        sink.write([0.25, -0.75, 1, -1], rawByteCount: 16)
        #expect(first.samples == [[0.25, -0.75, 1, -1]])
        #expect(second.samples == [[0.25, -0.75, 1, -1]])
        #expect(first.rawByteCounts == [16])
        #expect(second.rawByteCounts == [16])
    }

    @Test func replacementOnlyReceivesFutureWrites() {
        let old = FanOutTestAudioSink()
        let replacement = FanOutTestAudioSink()
        let sink = FanOutAudioSink(sinks: [old])
        sink.write([0.25])
        sink.sinks = [replacement]
        sink.write([0.75])
        sink.sinks = []
        sink.write([1])
        #expect(old.samples == [[0.25]])
        #expect(replacement.samples == [[0.75]])
        #expect(replacement.rawByteCounts == [nil])
        #expect(sink.sinks.isEmpty)
    }

    @Test func retainedCopyMutationDoesNotAffectOtherSink() {
        let first = FanOutTestAudioSink(replacementSample: 99)
        let second = FanOutTestAudioSink()
        let sink = FanOutAudioSink(sinks: [first, second])
        let original: [Float] = [0.25, -0.75]
        sink.write(original)
        #expect(first.samples == [[99, -0.75]])
        #expect(second.samples == [[0.25, -0.75]])
        #expect(original == [0.25, -0.75])
    }

    @Test func downstreamCanReplaceListWithoutChangingCurrentDelivery() throws {
        let sink = FanOutAudioSink()
        let second = FanOutTestAudioSink()
        let replacement = FanOutTestAudioSink()
        let first = FanOutTestAudioSink { [weak sink] in
            #expect(second.samples.isEmpty)
            sink?.sinks = [replacement]
        }
        sink.sinks = [first, second]
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            sink.write([0.5])
            finished.signal()
        }
        // 鎖若退化成持鎖呼叫，期限會讓測試失敗，不會把測試程序卡死。
        try #require(finished.wait(timeout: .now() + 2) == .success)
        #expect(first.samples == [[0.5]])
        #expect(second.samples == [[0.5]])
        #expect(replacement.samples.isEmpty)
        sink.write([0.75])
        #expect(replacement.samples == [[0.75]])
    }
}
