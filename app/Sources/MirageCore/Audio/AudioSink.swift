/// 音訊消費端。抽成協定的理由與畫面那側的 `FrameSink` 相同：手機遙控開啟時，
/// 同一批樣本要同時進本機播放的環形緩衝與送往手機的編碼路徑，而 `EmulatorClient`
/// 不該知道有幾個消費者。`AudioRingBuffer` 的方法簽章本來就符合，直接 conform。
public protocol AudioSink: AnyObject, Sendable {
    func write(_ samples: [Float], rawByteCount: Int?)
}
