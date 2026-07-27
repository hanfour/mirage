import Testing
@testable import MirageCore

/// `MmapBlankProbe` 是從 `MmapStreamTransport`（無單元測試網——需要真 channel）抽出來的
/// 純狀態機，涵蓋前 3 幀全零判定、以及「串流提早結束」這條先前漏掉的路徑（見
/// task-5-report.md 的 Critical 修正）。目標：逐行 100% 覆蓋。
@Suite struct MmapBlankProbeTests {
    /// (a) 前 3 幀全零 → 前兩幀 stillProbing，第 3 幀判定 unusable。
    @Test func threeBlankFramesBecomeUnusableOnTheThird() {
        var probe = MmapBlankProbe(frameBudget: 3)
        #expect(probe.observe(isBlank: true) == .stillProbing)
        #expect(probe.observe(isBlank: true) == .stillProbing)
        #expect(probe.observe(isBlank: true) == .unusable)
    }

    /// (b) 第 1 幀全零、第 2 幀有內容 → 第 1 幀 stillProbing、第 2 幀起 deliver，
    /// 且判定完成後即使又出現全零幀也照樣 deliver（不再檢查）。
    @Test func firstBlankThenContentDeliversFromSecondFrameOnward() {
        var probe = MmapBlankProbe(frameBudget: 3)
        #expect(probe.observe(isBlank: true) == .stillProbing)
        #expect(probe.observe(isBlank: false) == .deliver)
        #expect(probe.observe(isBlank: true) == .deliver)   // 判定已完成，不再檢查
        #expect(probe.observe(isBlank: false) == .deliver)
    }

    /// (c) 第 1 幀就有內容 → 立刻 deliver，探測窗口形同虛設。
    @Test func contentOnFirstFrameDeliversImmediately() {
        var probe = MmapBlankProbe(frameBudget: 3)
        #expect(probe.observe(isBlank: false) == .deliver)
    }

    /// (d) Critical 修正：只觀察到 2 幀全零（尚未用完 3 幀預算）後串流就自然結束
    /// → endedWithoutContent() 必須回 true，呼叫端據此丟 .mmapUnusable 而非放行成
    /// 乾淨結束（見 MmapBlankProbe 型別文件的完整推論）。
    @Test func streamEndingBeforeBudgetExhaustedReportsNoContent() {
        var probe = MmapBlankProbe(frameBudget: 3)
        #expect(probe.observe(isBlank: true) == .stillProbing)
        #expect(probe.observe(isBlank: true) == .stillProbing)
        #expect(probe.endedWithoutContent())
    }

    /// 補充：曾經送出過內容後才自然結束 → endedWithoutContent() 為 false（乾淨結束照常放行）。
    @Test func streamEndingAfterContentSeenIsNotFlaggedAsNoContent() {
        var probe = MmapBlankProbe(frameBudget: 3)
        _ = probe.observe(isBlank: false)
        #expect(!probe.endedWithoutContent())
    }

    /// 補充：完全沒收到任何幀就結束（例如伺服器連通知都沒送）→ 也視同無內容。
    @Test func streamEndingWithZeroFramesObservedReportsNoContent() {
        let probe = MmapBlankProbe(frameBudget: 3)
        #expect(probe.endedWithoutContent())
    }
}
