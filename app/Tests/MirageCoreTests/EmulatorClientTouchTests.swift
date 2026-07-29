import Foundation
import Testing
@testable import MirageCore

@Suite struct EmulatorClientTouchTests {
    @Test func buildsMultiTouchEventWithScaledPixels() {
        let touches = [
            TouchSpec(identifier: 1, point: NormPoint(x: 0.5, y: 0.5), down: true),
            TouchSpec(identifier: 2, point: NormPoint(x: 1.0, y: 0.0), down: false),
        ]
        let ev = EmulatorClient.buildTouchEvent(touches, width: 540, height: 1200)
        #expect(ev.touches.count == 2)
        #expect(ev.touches[0].identifier == 1)
        #expect(ev.touches[0].x == 270 && ev.touches[0].y == 600)
        #expect(ev.touches[0].pressure == 1024)      // down
        #expect(ev.touches[1].identifier == 2)
        #expect(ev.touches[1].x == 540 && ev.touches[1].y == 0)
        #expect(ev.touches[1].pressure == 0)         // up
    }

    @Test func buildsKeyEventFromW3CKey() {
        let ev = EmulatorClient.buildKeyEvent(.key("Enter"), down: true)
        #expect(ev?.key == "Enter")
        #expect(ev?.eventType == .keydown)
        let up = EmulatorClient.buildKeyEvent(.key("Enter"), down: false)
        #expect(up?.eventType == .keyup)
    }

    @Test func mouseKeyCodeProducesNoKeyEvent() {
        #expect(EmulatorClient.buildKeyEvent(.mouse(.left), down: true) == nil)
    }
}

@Suite struct MultiTouchLiveTests {
    @Test(.enabled(if: LiveGate.live, "需 MIRAGE_LIVE=1 與真模擬器"))
    func injectsTwoSimultaneousTouches() async throws {
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(2))
        // 兩個同時 down 觸點（移動 + 技能）
        await client.sendTouches([
            TouchSpec(identifier: 1, point: NormPoint(x: 0.25, y: 0.7), down: true),
            TouchSpec(identifier: 2, point: NormPoint(x: 0.85, y: 0.8), down: true),
        ])
        try await Task.sleep(for: .seconds(1))
        await client.sendTouches([
            TouchSpec(identifier: 1, point: NormPoint(x: 0.25, y: 0.7), down: false),
            TouchSpec(identifier: 2, point: NormPoint(x: 0.85, y: 0.8), down: false),
        ])
        await client.stop()
        // 佐證：adb shell settings put system show_touches 1 後截圖見兩觸點（pending-human/腳本擷取）
    }
}
