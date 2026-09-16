import Atomics
import Foundation

/// 環形緩衝的可觀測快照（不可變）。`MIRAGE_AUDIO_LOG=1` 每秒印它。
public struct AudioStats: Equatable, Sendable {
    public let underruns: Int
    public let overruns: Int
    public let depthSamples: Int
    public let writes: Int
    /// 重新蓄水次數：`primed` 由 false 轉 true 的累積次數（含開機後第一次）。
    /// **這個數字存在的理由**：重新蓄水期間 `underruns` 不增加、`depth` 看起來像
    /// 「正常爬升」，對只看 underrun/depth 的驗收判準完全隱形——一個反覆重新蓄水、
    /// 每次賠一段 pre-roll 靜音的緩衝，不看這個數字會被誤判成「比沒有 pre-roll
    /// 更健康」。`primes` 很大代表反覆蓄水；`primes` 很小而 underrun 增量仍高，
    /// 代表卡在低水位帶（見 `readStereo` 的已知限制段落）。
    public let primes: Int
    /// 蓄水未達門檻，因累計請求量逾時而強制開播的次數。
    public let primeTimeouts: Int
    /// 累計寫入的**樣本**數（單調遞增，不是封包數）。
    ///
    /// **`writes` 答不了「供應速率夠不夠」這個問題**，而那是 D44 唯一要回答的問題。
    /// 它數的是封包，而封包大小由 emulator 決定、本專案沒有任何地方強制它——
    /// 「每包 960 samples」只寫在 `init` 的一句註解裡，是觀察不是保證。
    /// 拿 `writes` 換算供應率要先假設包大小，而 D44 記載的「供應約為需求 94%」正是
    /// 這樣算出來的：那個數字的**形狀**（均勻不足、無缺口）可信，**幅度**不可信。
    ///
    /// 這個欄位讓速率可以直接算：`(writtenSamples 差) / 秒 / (48000 × 2)` 就是供應率，
    /// 不經過任何關於封包大小的假設。
    public let writtenSamples: Int

    public init(
        underruns: Int,
        overruns: Int,
        depthSamples: Int,
        writes: Int,
        primes: Int,
        writtenSamples: Int = 0,
        primeTimeouts: Int = 0,
    ) {
        self.underruns = underruns
        self.overruns = overruns
        self.depthSamples = depthSamples
        self.writes = writes
        self.primeTimeouts = primeTimeouts
        self.primes = primes
        self.writtenSamples = writtenSamples
    }
}

/// 單生產者單消費者（SPSC）環形緩衝；render callback 無鎖。
///
/// **本專案唯一允許 mutate 的資料結構**——全域約束是「不可變優先」，此處明文破例：
/// CoreAudio 的 render callback 跑在即時執行緒，不得配置記憶體、不得加鎖、不得 log。
/// 每包造新陣列會在即時執行緒觸發配置，結果是週期性爆音。破例範圍嚴格限縮在本 type 內，
/// 對外只暴露不可變的 `AudioStats` 快照。
///
/// 生產者只碰 `writeIndex`，消費者只碰 `readIndex`；索引單調遞增（不對容量取模），
/// 讀寫位置才用 `% capacity` 算——這樣 `write - read` 直接就是可用量，不需要「滿 vs 空」
/// 的歧義判斷，消除一個經典的環形緩衝特殊情況。
public final class AudioRingBuffer: AudioSink, @unchecked Sendable {
    // 診斷鎖只由生產者與每秒監測 task 使用；render callback 永不取得它。
    private let packetStatsLock: NSLock?
    private var packetBytes: [Int: Int] = [:]

    /// 與成功寫入計數在同一個邊界取樣。直方圖每次取出後清空，stats 仍為累計。
    /// 原始包包含空包與溢位丟包，所以桶數總和不一定等於 writes 差。
    public func takePacketWindow() -> AudioPacketWindow {
        packetStatsLock?.lock()
        defer { packetStatsLock?.unlock() }
        let window = AudioPacketWindow(stats: stats, byteCounts: packetBytes)
        packetBytes.removeAll(keepingCapacity: true)
        return window
    }

    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)
    private let underrunCount = ManagedAtomic<Int>(0)
    private let overrunCount = ManagedAtomic<Int>(0)
    private let writeCount = ManagedAtomic<Int>(0)
    private let primeThreshold: Int
    private let primeTimeoutSamples: Int
    private let unprimedRequested = ManagedAtomic<Int>(0)
    private let primeTimeoutCount = ManagedAtomic<Int>(0)
    /// 是否已蓄滿水並開始供應。生產者不碰它，只有消費者（即時執行緒）讀寫，
    /// 所以 relaxed 就夠——它不用來同步任何資料，只是消費端自己的狀態。
    private let primed = ManagedAtomic<Bool>(false)
    /// 見 `AudioStats.primes` 的說明。只在 `primed` 由 false 轉 true 的那一刻加一，
    /// 不是每次 read 都加——它數的是「進入蓄水又放行」的次數，不是供應中的 read 次數。
    private let primeCount = ManagedAtomic<Int>(0)

    /// 預設 19200 = 48kHz × 2ch × 200ms。這是**溢位前的天花板**，不是目標深度。
    ///
    /// `primeThresholdSamples` 預設 9600 = 100ms：消費端要等緩衝積到這個深度才開始
    /// 供應。**沒有它，穩態深度會是 0**——生產與消費速率相等時，每次 render callback
    /// 都拿到不足的資料然後補靜音，2026-08-03 實測 60 秒 under 每秒增加約 90、
    /// depth 全程 0ms（見 app/RESULTS-d32-probe.md）。傳 0 表示不蓄水（測試用）。
    /// `primeTimeoutSamples` 預設 19200 = 48kHz × 2ch × 200ms，未經校準，不是量出的值。
    /// 這是明顯長於 100ms 蓄水門檻、又希望短到點擊音效不會被聽成延遲的取捨，
    /// 並非已驗證的聽感保證。開放注入供測試與日後校準使用。
    /// 逾時以有資料等待期間的累計請求樣本數計算，不讀時鐘。
    public init(capacitySamples: Int = 19_200, primeThresholdSamples: Int = 9_600,
                primeTimeoutSamples: Int = 19_200,
                collectPacketSizes: Bool = false) {
        packetStatsLock = collectPacketSizes ? NSLock() : nil
        capacity = max(capacitySamples, 1)
        // 門檻不得超過容量的一半：超過的話蓄水期會先撞到 overrun，永遠 prime 不起來
        //（前提：封包大小均勻；`write` 是整包丟棄語意——若封包大小不均勻，例如先來一包
        // 小的把水位卡在剛好低於門檻、之後每包都比剩餘空間大，仍可能永遠丟棄、永遠
        // prime 不起來。實務上封包等長（960 samples／包），這個前提成立）。
        primeThreshold = max(0, min(primeThresholdSamples, capacity / 2))
        self.primeTimeoutSamples = primeTimeoutSamples
        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    public var stats: AudioStats {
        // 讀取順序是刻意的：**先 read 後 write**。兩個索引都單調遞增，且不變式 w >= r
        // 在任何瞬間都成立（write 只在有空間時前進、read 取 min(count, w - r)）。先取
        // r(t1) 再取 w(t2)（t2 > t1）時 w(t2) >= w(t1) >= r(t1)，故 depthSamples 永不為負。
        // 反過來（先 w 後 r）則會在兩次 load 之間發生消費時算出負值——P1-e 曾以此形式
        // 讓 MIRAGE_AUDIO_LOG 印出負的 depth。用順序消除特殊情況，不加 max(0,) 分支。
        let r = readIndex.load(ordering: .acquiring)
        let w = writeIndex.load(ordering: .acquiring)
        return AudioStats(underruns: underrunCount.load(ordering: .relaxed),
                          overruns: overrunCount.load(ordering: .relaxed),
                          depthSamples: w - r,
                          writes: writeCount.load(ordering: .relaxed),
                          primes: primeCount.load(ordering: .relaxed),
                          // `w` 就是累計寫入樣本數：writeIndex 單調遞增、不對容量取模
                          //（見 type 說明）。免費，不需要額外的計數器。
                          writtenSamples: w,
                          primeTimeouts: primeTimeoutCount.load(ordering: .relaxed))
    }

    /// 生產者執行緒（gRPC 消費 task）呼叫。空間不足 → **整包丟棄** + overruns += 1。
    public func write(_ samples: [Float], rawByteCount: Int? = nil) {
        packetStatsLock?.lock()
        defer { packetStatsLock?.unlock() }
        if packetStatsLock != nil, let rawByteCount {
            packetBytes[rawByteCount, default: 0] += 1
        }
        guard !samples.isEmpty else { return }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        guard capacity - (w - r) >= samples.count else {
            overrunCount.wrappingIncrement(ordering: .relaxed)
            return
        }
        for (i, sample) in samples.enumerated() {
            storage[(w + i) % capacity] = sample
        }
        writeIndex.store(w + samples.count, ordering: .releasing)
        writeCount.wrappingIncrement(ordering: .relaxed)
    }

    /// 即時執行緒（`AVAudioSourceNode` render block）呼叫。從交錯緩衝讀出最多 `frames`
    /// 個立體聲 frame，左右聲道**分別**寫入兩個連續 buffer；回傳實際寫入的 frame 數，
    /// 不足時 underruns += 1、餘下由呼叫端補靜音（與 `read` 同語意）。
    /// 不配置、不加鎖、不 log。
    ///
    /// **為什麼拆交錯這一步無法省略**：`AVAudioEngine.connect(_:to:format:)` 只接受
    /// deinterleaved 格式，傳 interleaved 會讓它丟出 `kAudioUnitErr_FormatNotSupported`
    /// (-10868) 的 **NSException**——Obj-C 例外，Swift 的 `do/catch` 攔不到。它曾在
    /// `@MainActor` 上把 App 的啟動流程整個扯斷，使 Mirage 的畫面與連線狀態自 P1-a 起
    /// 從未真正顯示過（見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md`）。
    /// 而生產端存進來的是 guest 送來的交錯樣本（`AudioChunk` 的合約），轉換總得有人做；
    /// 放在這裡是因為它必須發生在即時執行緒上，而這裡是唯一保證零配置零鎖的地方。
    ///
    /// **只讀完整 frame**：緩衝裡剩單數個樣本時把落單的那個留著不動。少讀半個 frame
    /// 只是晚一個 render 週期補上，錯開一個樣本卻會讓其後每一個 frame 的左右聲道永久反相。
    ///
    /// **蓄水期**：達到深度門檻或有資料等待的累計請求量達到逾時值才開播。
    /// 等待時回 0 且不計 underrun；空緩衝不累計逾時。
    public func readStereo(left: UnsafeMutablePointer<Float>,
                           right: UnsafeMutablePointer<Float>,
                           frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        // 蓄水等待以交錯樣本計數，與深度門檻使用相同單位。
        if !primed.load(ordering: .relaxed) {
            let depth = w - r
            if depth < primeThreshold {
                // 空緩衝沒有資料被扣住，不催開播，也不製造 underrun。
                if depth <= 0 { return 0 }
                let waited = unprimedRequested.wrappingIncrementThenLoad(by: frames * 2, ordering: .relaxed)
                if waited < primeTimeoutSamples { return 0 }
                primeTimeoutCount.wrappingIncrement(ordering: .relaxed)
            }
            primed.store(true, ordering: .relaxed)
            // 正常蓄滿與逾時放行都算一次開播。
            primeCount.wrappingIncrement(ordering: .relaxed)
            unprimedRequested.store(0, ordering: .relaxed)
        }
        let n = min(frames, (w - r) / 2)
        guard n > 0 else {
            // 被排乾了：回到蓄水狀態。不重置的話，斷流之後就退回沒有 pre-roll 的行為。
            primed.store(false, ordering: .relaxed)
            // ⚠️ 這一行在目前的不變式下是冗餘的，實測沒有任何測試能分辨它在不在
            // （2026-09-09 故障注入：拿掉它 27 條全綠）。理由是
            // `unprimedRequested` 只在未蓄滿時累加，而蓄滿那一刻（上面的 prime 分支）
            // 一定會把它歸零，所以走到這裡時它必然已經是 0。
            // 保留是防禦性的，與本 repo 對 `NSApp` 保護的處理一致（債務表 D34(c)）：
            // 保護留著，但不假裝有測試在守它。日後若新增「已蓄滿仍會累加」的路徑，
            // 這行才會開始有作用。
            unprimedRequested.store(0, ordering: .relaxed)
            underrunCount.wrappingIncrement(ordering: .relaxed)
            return 0
        }
        for i in 0..<n {
            left[i] = storage[(r + i * 2) % capacity]
            right[i] = storage[(r + i * 2 + 1) % capacity]
        }
        readIndex.store(r + n * 2, ordering: .releasing)
        if n < frames { underrunCount.wrappingIncrement(ordering: .relaxed) }
        return n
    }

    /// 即時執行緒（AVAudioSourceNode render block）呼叫。
    /// 回傳實際寫入 `dst` 的樣本數；不足 `count` 時 underruns += 1，餘下由呼叫端補靜音。
    /// 不配置、不加鎖、不 log。
    ///
    /// **本方法不參與 pre-roll**：不看也不重置 `primed`。若某個呼叫端同時混用
    /// `read(into:count:)` 與 `readStereo`，`primed` 會停在 `readStereo` 上次寫入的值，
    /// 變成陳舊狀態——目前沒有生產路徑這樣混用（`AudioPlayer` 只走 `readStereo`），
    /// 但 `AudioLiveTests` 的測試輔助函式是用 `read(into:)` 排空，這是特例，不是慣例。
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(count, w - r)
        guard n > 0 else {
            underrunCount.wrappingIncrement(ordering: .relaxed)
            return 0
        }
        for i in 0..<n {
            dst[i] = storage[(r + i) % capacity]
        }
        readIndex.store(r + n, ordering: .releasing)
        if n < count { underrunCount.wrappingIncrement(ordering: .relaxed) }
        return n
    }
}
