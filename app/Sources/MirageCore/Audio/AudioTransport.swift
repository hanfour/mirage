import Foundation

/// 向 emulator 請求的音訊串流格式。取樣格式固定 S16（proto 只有 U8/S16 兩種，
/// S16 是品質較好的那個），故不參數化。
public struct AudioStreamFormat: Equatable, Sendable {
    public let samplingRate: Int
    public let channels: Int

    public init(samplingRate: Int, channels: Int) {
        self.samplingRate = samplingRate
        self.channels = channels
    }

    /// proto 註明取樣率上限 48kHz、Android 裝置典型即 48k——固定用它就不需要重採樣。
    public static let standard = AudioStreamFormat(samplingRate: 48_000, channels: 2)
}

/// 一包已解碼的音訊：interleaved Float32，範圍 [-1, 1)。
public struct AudioChunk: Equatable, Sendable {
    public let samples: [Float]
    /// 原始 S16 payload 大小；保留奇數尾端與空包，不能從解碼後樣本數反推。
    public let rawByteCount: Int?

    public init(samples: [Float], rawByteCount: Int? = nil) {
        self.samples = samples
        self.rawByteCount = rawByteCount
    }

    /// S16 little-endian 位元組 → interleaved Float32。
    ///
    /// 在生產者執行緒呼叫——配置與轉換都不得發生在即時執行緒上。
    /// 位元組數為奇數時尾端半個 sample 直接丟棄（防禦性，不崩）。
    public static func fromS16LE(_ data: Data) -> AudioChunk {
        let count = data.count / 2
        guard count > 0 else { return AudioChunk(samples: [], rawByteCount: data.count) }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let s = Int16(bitPattern: lo | (hi << 8))
                out[i] = Float(s) / 32_768.0
            }
        }
        return AudioChunk(samples: out, rawByteCount: data.count)
    }
}

/// 音訊來源的注入點——對齊既有 `DisplayTransport` 的慣例，讓 EmulatorClient 的
/// attach/detach 編排可以用假件測試（見 EmulatorClientAudioTests）。
public protocol AudioTransport: Sendable {
    func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error>

    /// 顯式取消底層 RPC。
    ///
    /// **不可省略**：`AsyncThrowingStream` 的 `onTermination` + `Task.cancel()`
    /// 不足以中斷已 in-flight 的 `next()`——這是 P1-b 剪貼簿串流實證過的坑
    /// （見 `EmulatorClient.startClipboardStream` 的 ADAPTATION 註解）。而 proto 明載
    /// 「The stream may block indefinitely if the emulator ceases to produce audio」，
    /// guest 靜音時就是這個情境，沒有真 cancel 會卡住並在 channel 拆除時觸發
    /// NIO "leaking promise" 致命錯誤。
    func cancelStream()
}
