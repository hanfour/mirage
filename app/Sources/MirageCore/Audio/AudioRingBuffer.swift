import Atomics

/// 環形緩衝的可觀測快照（不可變）。`MIRAGE_AUDIO_LOG=1` 每秒印它。
public struct AudioStats: Equatable, Sendable {
    public let underruns: Int
    public let overruns: Int
    public let depthSamples: Int
    public let writes: Int

    public init(underruns: Int, overruns: Int, depthSamples: Int, writes: Int) {
        self.underruns = underruns
        self.overruns = overruns
        self.depthSamples = depthSamples
        self.writes = writes
    }
}

/// 單生產者單消費者（SPSC）無鎖環形緩衝。
///
/// **本專案唯一允許 mutate 的資料結構**——全域約束是「不可變優先」，此處明文破例：
/// CoreAudio 的 render callback 跑在即時執行緒，不得配置記憶體、不得加鎖、不得 log。
/// 每包造新陣列會在即時執行緒觸發配置，結果是週期性爆音。破例範圍嚴格限縮在本 type 內，
/// 對外只暴露不可變的 `AudioStats` 快照。
///
/// 生產者只碰 `writeIndex`，消費者只碰 `readIndex`；索引單調遞增（不對容量取模），
/// 讀寫位置才用 `% capacity` 算——這樣 `write - read` 直接就是可用量，不需要「滿 vs 空」
/// 的歧義判斷，消除一個經典的環形緩衝特殊情況。
public final class AudioRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)
    private let underrunCount = ManagedAtomic<Int>(0)
    private let overrunCount = ManagedAtomic<Int>(0)
    private let writeCount = ManagedAtomic<Int>(0)

    /// 預設 19200 = 48kHz × 2ch × 200ms。這是**溢位前的天花板**，不是目標深度；
    /// 穩態深度由生產端節奏自然決定（~100ms），不另設節流。
    public init(capacitySamples: Int = 19_200) {
        capacity = max(capacitySamples, 1)
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
                          writes: writeCount.load(ordering: .relaxed))
    }

    /// 生產者執行緒（gRPC 消費 task）呼叫。空間不足 → **整包丟棄** + overruns += 1。
    public func write(_ samples: [Float]) {
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
    public func readStereo(left: UnsafeMutablePointer<Float>,
                           right: UnsafeMutablePointer<Float>,
                           frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(frames, (w - r) / 2)
        guard n > 0 else {
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
