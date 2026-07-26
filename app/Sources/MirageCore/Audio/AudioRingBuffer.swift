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
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
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
