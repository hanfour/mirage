import Foundation
import Testing
@testable import MirageCore

/// App-path 活體（Core 範圍，spec §4.7）：引擎狀態序列 → sendTouches → 真模擬器。
/// `KeymapController`+NSEvent 抽取在不可 import 的 executable target/GUI，列 pending-human。
@Suite struct KeymapInjectLiveTests {
    @Test func engineDrivenMultiTouchInjects() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let profile = KeymapProfile(gameId: "com.example.game", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.25, y: 0.7), radius: 0.12),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
        ])
        let engine = KeymapEngine(profile: profile)
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(2))
        _ = engine.apply(.keyDown(.key("w")))                 // joystick
        let frame = engine.apply(.keyDown(.key("j")))         // + 技能 → 兩觸點
        await client.sendTouches(frame.touches)
        try await Task.sleep(for: .seconds(1))
        await client.sendTouches(engine.apply(.keyUp(.key("j"))).touches)
        await client.stop()
        #expect(frame.touches.filter { $0.down }.count == 2)  // 引擎產兩 down 觸點
    }
}
