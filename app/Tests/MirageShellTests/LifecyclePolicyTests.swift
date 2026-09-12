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
    /// spec 第 6 節：手機連著時關 Mac 視窗不 suspend，畫面繼續串流；之後喚醒也不該
    /// 呼叫 `client.wake()`（沒有東西要恢復）。
    @Test func hidingWithRemoteViewerDoesNotSuspend() {
        var policy = LifecyclePolicy()
        var suspend = policy.didHide(remoteViewerActive: true)
        #expect(!suspend)
        #expect(!policy.suspended)
        var resumed = policy.consumeResume()
        #expect(!resumed)

        suspend = policy.didHide(remoteViewerActive: false)
        #expect(suspend)
        #expect(policy.suspended)
        resumed = policy.consumeResume()
        #expect(resumed)
    }

    /// 既有無參數版本的行為不變：等於 `remoteViewerActive: false`。
    @Test func legacyDidHideStillSuspends() {
        var policy = LifecyclePolicy()
        policy.didHide()
        #expect(policy.suspended)
    }

}
