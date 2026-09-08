import Testing
@testable import MirageShell

struct LifecyclePolicyTests {
    @Test func closingLastWindowKeepsApplicationRunning() {
        #expect(!LifecyclePolicy.terminateAfterLastWindowClosed)
    }

    /// `consumeResume()` 是 mutating，不能直接寫在 `#expect(...)` 裡：巨集展開後
    /// 會把值捕捉進一個 `$0` 不可變的閉包，編譯錯誤是
    /// 「cannot use mutating member on immutable value」。先呼叫、再斷言回傳值。
    @Test func onlySuspendedSessionResumes() {
        var policy = LifecyclePolicy()
        var resumed = policy.consumeResume()
        #expect(!resumed)

        policy.didHide()
        #expect(policy.suspended)
        resumed = policy.consumeResume()
        #expect(resumed)
        #expect(!policy.suspended)

        resumed = policy.consumeResume()
        #expect(!resumed)

        // 連續兩次 didHide 只換得一次 resume。
        policy.didHide()
        policy.didHide()
        resumed = policy.consumeResume()
        #expect(resumed)
        resumed = policy.consumeResume()
        #expect(!resumed)
    }
}
