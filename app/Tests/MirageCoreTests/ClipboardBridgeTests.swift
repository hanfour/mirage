import Foundation
import Testing
@testable import MirageCore

@Suite struct ClipboardBridgeTests {
    @Test func firstValuePropagates() {
        let (ok, _) = ClipboardBridge().shouldPropagate(value: "hello", direction: .hostToGuest)
        #expect(ok)
    }

    @Test func echoBackDoesNotPropagate() {
        // host 設 "hello" 送 guest（傳播）；guest 串流回吐 "hello"（不回彈）→ 無限迴圈被切斷
        var bridge = ClipboardBridge()
        let (ok1, b1) = bridge.shouldPropagate(value: "hello", direction: .hostToGuest)
        bridge = b1
        #expect(ok1)
        let (ok2, _) = bridge.shouldPropagate(value: "hello", direction: .guestToHost)
        #expect(!ok2)          // 回音不傳播
    }

    @Test func differentValuePropagatesBothDirections() {
        var bridge = ClipboardBridge()
        let (okA, b1) = bridge.shouldPropagate(value: "A", direction: .hostToGuest); bridge = b1
        let (okB, _) = bridge.shouldPropagate(value: "B", direction: .guestToHost)
        #expect(okA)
        #expect(okB)           // B ≠ A，雙向都傳播
    }

    @Test func duplicateValueDeduped() {
        var bridge = ClipboardBridge()
        let (_, b1) = bridge.shouldPropagate(value: "same", direction: .guestToHost); bridge = b1
        let (ok2, _) = bridge.shouldPropagate(value: "same", direction: .guestToHost)
        #expect(!ok2)          // 同值連續 → 去重
    }

    @Test func bridgeIsImmutable() {
        let original = ClipboardBridge()
        _ = original.shouldPropagate(value: "x", direction: .hostToGuest)
        // original 未被改動：再次以初始狀態判定，仍傳播
        let (ok, _) = original.shouldPropagate(value: "x", direction: .hostToGuest)
        #expect(ok)
    }
}

@Suite struct ClipboardLiveTests {
    @Test(.enabled(if: LiveGate.live, "需 MIRAGE_LIVE=1 與真模擬器"))
    func hostToGuestSetsClipboard() async throws {
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(2))
        await client.setGuestClipboard("mirage-test-\(42)")
        try await Task.sleep(for: .milliseconds(500))
        await client.stop()
        // 佐證：adb shell 讀 guest 剪貼簿或人工檢查（pending-human）
    }
}
