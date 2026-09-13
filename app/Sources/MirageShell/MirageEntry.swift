import Darwin
import Foundation

/// `MirageShell` 唯一的公開宣告——executable 的 `@main` 只呼叫這一個函式。
///
/// 這樣設計的理由：App 層 21 檔全部是 internal，測試靠 `@testable import` 觸及即可，
/// 沒有任何型別需要跨 module 公開。把公開面壓到一個函式，就不會有人為了「讓
/// executable 看得見」而逐步把內部型別改成 `public`。
public enum MirageEntry {
    @MainActor
    public static func main() {
        raiseFileDescriptorLimit()
        MirageScene.main()
    }

    /// 防禦性增加餘裕；不降低既有 soft limit，也不修改 hard limit。
    private static func raiseFileDescriptorLimit() {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
            NSLog("[startup] 無法讀取 RLIMIT_NOFILE：errno=%d", errno)
            return
        }
        let target = min(limits.rlim_max, rlim_t(4096))
        guard limits.rlim_cur < target else { return }
        limits.rlim_cur = target
        if setrlimit(RLIMIT_NOFILE, &limits) != 0 {
            NSLog("[startup] 無法提高 RLIMIT_NOFILE：errno=%d", errno)
        }
    }
}
