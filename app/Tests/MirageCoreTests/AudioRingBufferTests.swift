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

/// 同上，供 `readStereo` 用：一次配好兩個聲道緩衝。
private func readStereoSamples(_ ring: AudioRingBuffer, frames: Int)
    -> (got: Int, left: [Float], right: [Float]) {
    var l = [Float](repeating: .nan, count: frames)
    var r = [Float](repeating: .nan, count: frames)
    let got = l.withUnsafeMutableBufferPointer { lb in
        r.withUnsafeMutableBufferPointer { rb in
            ring.readStereo(left: lb.baseAddress!, right: rb.baseAddress!, frames: frames)
        }
    }
    return (got, l, r)
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

    // MARK: - readStereo（拆交錯）
    //
    // 為什麼需要它：`AVAudioEngine` 的節點連接**只接受 deinterleaved 格式**，用
    // interleaved 呼叫 `connect(_:to:format:)` 會丟 NSException（見
    // docs/specs/2026-07-28-mirror-never-rendered-investigation.md）。而環形緩衝存的是
    // guest 送來的交錯樣本，拆交錯這一步無法避免；它必須發生在即時執行緒上，
    // 所以放在這裡——零配置、零鎖，和既有的 `read` 同一套不變式。
    //
    // **為什麼這一組全部傳 `primeThresholdSamples: 0`**：它們驗的是拆交錯與邊界機制，
    // 不是蓄水策略。用生產預設值（9600）的話，這些容量只有 4–16 samples 的緩衝永遠
    // 達不到門檻，每個測試都只會讀到 0，驗不到任何它們該驗的東西。蓄水本身由下方
    // 「pre-roll」那一組專門涵蓋。

    @Test func readStereoSplitsInterleavedIntoChannels() {
        let ring = AudioRingBuffer(capacitySamples: 16, primeThresholdSamples: 0)
        ring.write([1, -1, 2, -2, 3, -3])          // L,R,L,R,L,R
        let (got, left, right) = readStereoSamples(ring, frames: 3)
        #expect(got == 3)
        #expect(Array(left.prefix(3)) == [1, 2, 3])
        #expect(Array(right.prefix(3)) == [-1, -2, -3])
    }

    /// 消費快於生產：只回傳完整 frame 數，餘下由呼叫端補靜音（與 `read` 同語意）。
    @Test func readStereoPartialReturnsWholeFramesAndCountsUnderrun() {
        let ring = AudioRingBuffer(capacitySamples: 16, primeThresholdSamples: 0)
        ring.write([1, -1, 2, -2])
        let (got, left, right) = readStereoSamples(ring, frames: 5)
        #expect(got == 2)
        #expect(Array(left.prefix(2)) == [1, 2])
        #expect(Array(right.prefix(2)) == [-1, -2])
        #expect(ring.stats.underruns == 1)
    }

    /// 半個 frame（樣本數為奇數）不得被當成完整 frame 讀出去——那會讓左右聲道錯位，
    /// 之後每一個 frame 都反相。緩衝裡本來就該永遠是偶數個樣本，這條守的是防禦性下限。
    @Test func readStereoLeavesDanglingHalfFrameInBuffer() {
        let ring = AudioRingBuffer(capacitySamples: 16, primeThresholdSamples: 0)
        ring.write([1, -1, 2])                     // 一個完整 frame + 半個
        let (got, left, right) = readStereoSamples(ring, frames: 2)
        #expect(got == 1)
        #expect(left[0] == 1)
        #expect(right[0] == -1)
        #expect(ring.stats.depthSamples == 1)      // 落單的那個仍留在緩衝裡
    }

    @Test func readStereoOnEmptyReturnsZeroAndCountsUnderrun() {
        let ring = AudioRingBuffer(capacitySamples: 16, primeThresholdSamples: 0)
        let (got, _, _) = readStereoSamples(ring, frames: 4)
        #expect(got == 0)
        #expect(ring.stats.underruns == 1)
    }

    /// 環繞：讀寫位置跨越實體陣列尾端時，左右聲道仍須各自保持順序且不互相汙染。
    @Test func readStereoWrapAroundPreservesChannelOrder() {
        let ring = AudioRingBuffer(capacitySamples: 6, primeThresholdSamples: 0)
        ring.write([1, -1, 2, -2])
        _ = readStereoSamples(ring, frames: 2)
        ring.write([3, -3, 4, -4])                 // 寫入位置跨過陣列尾端
        let (got, left, right) = readStereoSamples(ring, frames: 2)
        #expect(got == 2)
        #expect(Array(left.prefix(2)) == [3, 4])
        #expect(Array(right.prefix(2)) == [-3, -4])
    }

    // MARK: - pre-roll（蓄水）
    //
    // 為什麼需要它：生產端與消費端的速率相等（都是 48kHz），若不先積一段水就開始
    // 消費，穩態深度會停在 0——每次 render callback 都拿到不足的資料然後補靜音。
    // 2026-08-03 實測 60 秒：under 每秒增加約 90、depth 全程 0ms、over 恆為 0
    // （見 app/RESULTS-d32-probe.md）。pre-roll 讓深度從門檻起跳，把「幾乎每次都欠位」
    // 變成「只有真的斷流才欠位」。

    /// 未達門檻前一律不出貨，且**不計 underrun**——那不是欠位，是還沒開始播。
    /// 這個區分很重要：若計入，驗收指標會把正常的啟動蓄水期算成缺陷。
    @Test func primeWithheldBelowThresholdAndNotCountedAsUnderrun() {
        let ring = AudioRingBuffer(capacitySamples: 64, primeThresholdSamples: 16)
        ring.write([1, -1, 2, -2])                 // 4 samples < 門檻 16
        let (got, _, _) = readStereoSamples(ring, frames: 2)
        #expect(got == 0)
        #expect(ring.stats.underruns == 0)
        #expect(ring.stats.depthSamples == 4)      // 沒被消費掉
    }

    /// 達到門檻就開始正常供應。
    @Test func primeReleasesOnceThresholdReached() {
        let ring = AudioRingBuffer(capacitySamples: 64, primeThresholdSamples: 8)
        ring.write([1, -1, 2, -2])                 // 4 < 8：還不出貨
        #expect(readStereoSamples(ring, frames: 2).0 == 0)
        ring.write([3, -3, 4, -4])                 // 累積到 8：達標
        let (got, left, right) = readStereoSamples(ring, frames: 4)
        #expect(got == 4)
        #expect(Array(left.prefix(4)) == [1, 2, 3, 4])
        #expect(Array(right.prefix(4)) == [-1, -2, -3, -4])
    }

    /// 被排乾之後要重新蓄水，不能一路空轉供應——否則斷流時會退回沒有 pre-roll 的行為。
    @Test func primeResetsAfterBufferDrained() {
        let ring = AudioRingBuffer(capacitySamples: 64, primeThresholdSamples: 8)
        ring.write([1, -1, 2, -2, 3, -3, 4, -4])   // 達標
        #expect(readStereoSamples(ring, frames: 4).0 == 4)   // 全部讀走 → 空了
        #expect(readStereoSamples(ring, frames: 4).0 == 0)   // 空讀 → 計 underrun 並重置
        #expect(ring.stats.underruns == 1)
        ring.write([5, -5])                        // 2 < 8：重新蓄水中，不出貨
        #expect(readStereoSamples(ring, frames: 1).0 == 0)
        #expect(ring.stats.underruns == 1)         // 蓄水期不再累加 underrun
    }

    /// 門檻不得超過容量的一半：超過的話蓄水期就會先撞到 overrun，變成永遠 prime 不起來。
    /// 這條守的是「小容量緩衝配大門檻」這個組態陷阱，讓它降級成可用而不是靜默鎖死。
    @Test func primeThresholdIsClampedToHalfCapacity() {
        let ring = AudioRingBuffer(capacitySamples: 8, primeThresholdSamples: 9_600)
        ring.write([1, -1, 2, -2])                 // 4 samples == 容量 8 的一半
        let (got, _, _) = readStereoSamples(ring, frames: 2)
        #expect(got == 2)
    }

    /// 釘住生產預設值：`AppModel` 用的是無參數建構（AppModel.swift:69），
    /// 而這個預設值正是本次修正唯一在生產上生效的東西。沒有這條，把預設改回 0
    /// （等同整個 revert pre-roll）整套測試依然全綠。
    @Test func productionDefaultsWithholdUntil100msAccumulated() {
        let ring = AudioRingBuffer()                              // 19200 / 9600
        ring.write([Float](repeating: 0.5, count: 9_598))
        #expect(readStereoSamples(ring, frames: 1).0 == 0)        // 差 2 個樣本，不出貨
        ring.write([0.5, 0.5])                                    // 累積到 9600
        #expect(readStereoSamples(ring, frames: 1).0 == 1)
    }

    /// `primes` 只在「由未蓄滿轉為蓄滿」的那一刻加一：蓄水 → 放行 →排乾 → 再蓄水
    /// 一輪應為 2，不是每次成功 read 都加。這個指標存在的理由是 Important-B 審查
    /// 指出的隱形問題——重新蓄水期間 underruns 不增加、depth 看起來像正常爬升，
    /// 沒有 primes 就完全看不出「反覆重新蓄水」這件事正在發生
    /// （見 `AudioStats.primes` 的說明）。
    @Test func primesCountsEachReEntryIntoPrimedState() {
        let ring = AudioRingBuffer(capacitySamples: 64, primeThresholdSamples: 8)
        ring.write([1, -1, 2, -2, 3, -3, 4, -4])   // 達標 → primed 第 1 次轉 true
        #expect(readStereoSamples(ring, frames: 4).0 == 4)   // 全部讀走 → 空了
        #expect(readStereoSamples(ring, frames: 4).0 == 0)   // 空讀 → 觸發重置回蓄水狀態
        #expect(ring.stats.primes == 1)
        ring.write([5, -5, 6, -6, 7, -7, 8, -8])   // 重新蓄水達標 → primed 第 2 次轉 true
        #expect(readStereoSamples(ring, frames: 4).0 == 4)
        #expect(ring.stats.primes == 2)
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
    /// D44：`writtenSamples` 數的是樣本，不是封包。
    ///
    /// **為什麼要一條測試釘住這個區別**：D44 記載的「供應約為需求 94%」是拿 `writes`
    /// （封包數）乘上一個假設的包大小推出來的，而那個「每包 960 samples」只寫在
    /// `init` 的一句註解裡，沒有任何東西強制它——封包大小是 emulator 決定的。形狀
    /// （均勻不足、無缺口）不受影響，幅度則整個建立在那個假設上。
    ///
    /// 這條測試用**不等長**的封包，所以任何把 writtenSamples 實作成「封包數 × 常數」
    /// 的版本都會紅。等長封包驗不出這件事——那正是原本的盲點。
    @Test func writtenSamplesCountsSamplesNotPackets() {
        let ring = AudioRingBuffer(capacitySamples: 4_096, primeThresholdSamples: 0)
        ring.write([Float](repeating: 0.1, count: 100))
        ring.write([Float](repeating: 0.2, count: 250))
        ring.write([Float](repeating: 0.3, count: 7))

        let stats = ring.stats
        #expect(stats.writes == 3)
        #expect(stats.writtenSamples == 357)
    }

    /// 被丟棄的封包不得計入供應量——否則溢位時供應率會虛報。
    @Test func writtenSamplesExcludesDroppedPackets() {
        let ring = AudioRingBuffer(capacitySamples: 128, primeThresholdSamples: 0)
        ring.write([Float](repeating: 0.1, count: 100))
        ring.write([Float](repeating: 0.2, count: 100))   // 放不下 → 整包丟棄

        let stats = ring.stats
        #expect(stats.overruns == 1)
        #expect(stats.writtenSamples == 100)
    }

}
