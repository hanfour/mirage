import CoreMedia
import Foundation

/// PTS 用 `Frame.receivedAt`（spec 第 3 節）：以 session 建立時那一幀為零點，奈秒精度。
/// `ContinuousClock.Instant` 是單調時鐘，跨幀遞增，正是編碼器要的 PTS 性質。
enum RemoteEncoderClock {
    // 畫面封包在 RemoteVideoConnection 使用 uptimeNanoseconds；PTS 的 session 零點
    // 不能當傳輸時間，否則音訊與畫面的時間戳無法直接比較。
    static func sentAtNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static let timescale: CMTimeScale = 1_000_000_000

    static func presentationTime(of instant: ContinuousClock.Instant,
                                 since epoch: ContinuousClock.Instant) -> CMTime {
        let elapsed = instant - epoch
        let nanoseconds = elapsed.components.seconds * 1_000_000_000
            + elapsed.components.attoseconds / 1_000_000_000
        return CMTime(value: CMTimeValue(nanoseconds), timescale: timescale)
    }
}
