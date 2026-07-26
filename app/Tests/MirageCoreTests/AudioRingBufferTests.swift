import Atomics
import Foundation
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
        // 下限斷言：`overruns > 0 → break` 這條提早結束路徑若在幾乎沒讀到東西時觸發，
        // 下面兩條不變式在空/單元素集合上會恆真，測試就成了偽陽性綠燈。要求至少讀到
        // 一整個生產批次（64 samples），確保不變式真的被有意義的資料量檢驗過。
        #expect(collected.count >= 64)
        // 讀到的值必須嚴格遞增——任何撕裂或索引錯亂都會破壞這個性質。
        #expect(collected == collected.sorted())
        #expect(Set(collected).count == collected.count)
    }

    /// P1-e fast-follow：`stats` 先讀 readIndex 再讀 writeIndex，故 depthSamples 永不為負。
    ///
    /// 用**真實 OS 執行緒**（非 cooperative Task）緊迴圈，因為要打中的窗口只有 `stats`
    /// 內兩個相鄰 atomic load 之間那幾奈秒——Task.yield() 的排程粒度比它大好幾個數量級，
    /// 根本碰不到（實測：cooperative 版本在有 bug 的舊順序下 5/5 次都是綠燈，是個
    /// 什麼都沒驗到的假測試）。真執行緒靠 OS 搶佔才有機會落在那個窗口裡。
    ///
    /// 偵測率實測：把 `stats` 改回有 bug 的順序後 5 次執行中 4 次紅（cooperative 版本 0/5）；
    /// 修正版連跑 8 次全綠。**它是機率性的回歸守門員，不是決定性證明**——單次綠燈不代表
    /// 順序沒被改壞，但順序若被改壞，CI 上重複執行遲早會抓到。
    @Test func depthNeverGoesNegativeUnderThreadedContention() {
        let ring = AudioRingBuffer(capacitySamples: 2_048)
        let worst = ManagedAtomic<Int>(Int.max)
        let done = ManagedAtomic<Int>(0)
        let iterations = 200_000

        Thread.detachNewThread {          // 生產者：持續補滿
            let chunk = [Float](repeating: 1, count: 64)
            for _ in 0..<iterations { ring.write(chunk) }
            done.wrappingIncrement(ordering: .relaxed)
        }
        Thread.detachNewThread {          // 消費者：持續排空
            var buf = [Float](repeating: 0, count: 64)
            for _ in 0..<iterations {
                buf.withUnsafeMutableBufferPointer { _ = ring.read(into: $0.baseAddress!, count: 64) }
            }
            done.wrappingIncrement(ordering: .relaxed)
        }
        Thread.detachNewThread {          // 觀測者：緊迴圈取樣 depth，記錄最小值
            for _ in 0..<iterations {
                let d = ring.stats.depthSamples
                var cur = worst.load(ordering: .relaxed)
                while d < cur, !worst.weakCompareExchange(expected: cur, desired: d,
                                                          ordering: .relaxed).exchanged {
                    cur = worst.load(ordering: .relaxed)
                }
            }
            done.wrappingIncrement(ordering: .relaxed)
        }

        while done.load(ordering: .acquiring) < 3 { usleep(1_000) }
        #expect(worst.load(ordering: .acquiring) >= 0,
                "depthSamples 為負代表 stats 的兩次 atomic load 順序錯了（須先 read 後 write）")
    }
}
