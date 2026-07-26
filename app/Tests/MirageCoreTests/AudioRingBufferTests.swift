import Testing
@testable import MirageCore

/// 測試用讀取輔助：包一層讓每個測項不必各自管 UnsafeMutablePointer 生命週期。
private func readSamples(_ ring: AudioRingBuffer, count: Int) -> (got: Int, values: [Float]) {
    var out = [Float](repeating: .nan, count: count)
    let got = out.withUnsafeMutableBufferPointer { buf in
        ring.read(into: buf.baseAddress!, count: count)
    }
    return (got, out)
}

@Suite struct AudioRingBufferTests {
    @Test func writeThenReadRoundTripsValues() {
        let ring = AudioRingBuffer(capacitySamples: 16)
        ring.write([1, 2, 3, 4])
        let (got, values) = readSamples(ring, count: 4)
        #expect(got == 4)
        #expect(Array(values.prefix(4)) == [1, 2, 3, 4])
    }

    @Test func readOnEmptyReturnsZeroAndCountsUnderrun() {
        let ring = AudioRingBuffer(capacitySamples: 16)
        let (got, _) = readSamples(ring, count: 8)
        #expect(got == 0)
        #expect(ring.stats.underruns == 1)
    }

    @Test func partialReadCountsUnderrunAndReturnsWhatExists() {
        let ring = AudioRingBuffer(capacitySamples: 16)
        ring.write([1, 2])
        let (got, values) = readSamples(ring, count: 5)
        #expect(got == 2)
        #expect(Array(values.prefix(2)) == [1, 2])
        #expect(ring.stats.underruns == 1)
    }

    @Test func writeExceedingFreeSpaceIsDroppedWholeAndCountsOverrun() {
        let ring = AudioRingBuffer(capacitySamples: 4)
        ring.write([1, 2, 3])
        ring.write([4, 5])                       // 只剩 1 格 → 整包丟棄
        #expect(ring.stats.overruns == 1)
        #expect(ring.stats.depthSamples == 3)    // 原本的 3 個仍在
        let (got, values) = readSamples(ring, count: 3)
        #expect(got == 3)
        #expect(Array(values.prefix(3)) == [1, 2, 3])
    }

    /// 寫入超過容量本身的單包也只是丟棄，不得寫壞記憶體。
    @Test func writeLargerThanCapacityIsDropped() {
        let ring = AudioRingBuffer(capacitySamples: 4)
        ring.write([1, 2, 3, 4, 5, 6])
        #expect(ring.stats.overruns == 1)
        #expect(ring.stats.depthSamples == 0)
    }

    /// 環繞：寫滿→讀空→再寫，資料必須跨越實體陣列尾端仍然正確。
    @Test func wrapAroundPreservesOrder() {
        let ring = AudioRingBuffer(capacitySamples: 4)
        ring.write([1, 2, 3])
        _ = readSamples(ring, count: 3)
        ring.write([4, 5, 6])                    // 寫入位置跨過陣列尾端
        let (got, values) = readSamples(ring, count: 3)
        #expect(got == 3)
        #expect(Array(values.prefix(3)) == [4, 5, 6])
    }

    @Test func statsTracksWriteCountAndDepth() {
        let ring = AudioRingBuffer(capacitySamples: 16)
        ring.write([1, 2])
        ring.write([3, 4, 5])
        #expect(ring.stats.writes == 2)
        #expect(ring.stats.depthSamples == 5)
    }

    /// 生產者/消費者併發：不得崩潰、不得讀到損毀值（每個 sample 都是遞增序列的一員）。
    @Test func concurrentProducerConsumerKeepsDataIntact() async {
        let ring = AudioRingBuffer(capacitySamples: 4_096)
        let total = 200 * 64
        let producer = Task.detached {
            for chunk in 0..<200 {
                ring.write((0..<64).map { Float(chunk * 64 + $0) })
                await Task.yield()
            }
        }
        let consumer = Task.detached { () -> [Float] in
            var collected: [Float] = []
            while collected.count < total {
                let (got, values) = readSamples(ring, count: 128)
                if got == 0 { await Task.yield(); continue }
                collected.append(contentsOf: values.prefix(got))
                if ring.stats.overruns > 0 { break }   // 消費端落後時提早結束，不無限等
            }
            return collected
        }
        await producer.value
        let collected = await consumer.value
        // 讀到的值必須嚴格遞增——任何撕裂或索引錯亂都會破壞這個性質。
        #expect(collected == collected.sorted())
        #expect(Set(collected).count == collected.count)
    }
}
