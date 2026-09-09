import AppKit
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

// 與 MirageCoreTests/LiveGate.swift 讀同一個變數，因為兩個 test target 之間沒有
// 共用檔案的機制；真正防止打錯變數名的是 verify_keymap_release.sh 會斷言測試沒有被 skip。
private enum KeymapReleaseLiveGate {
    static let live = ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1"
}

private func releaseLiveProfile() -> KeymapProfile {
    KeymapProfile(gameId: "release-live", version: 1, bindings: [
        .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                  center: NormPoint(x: 0.2, y: 0.75), radius: 0.1),
    ])
}

/// 每條測試開始前，先把 guest 上所有 slot 放開。
///
/// **為什麼需要這一步（2026-09-09 實測發現）**：emulator 的觸控驅動只送轉移，而跑過
/// 一次「修法被還原」的版本會在 guest 上留下一個永遠按著的 slot。下一次跑時第一個
/// 按下因為狀態沒變而不產生任何事件，量到「按下 0 次、零卡住」，訊息指向注入路徑，
/// 而真正的成因是上一輪的殘留。失敗方向仍是紅燈，但會把人帶去查錯的地方。
///
/// 放在測試裡而不是腳本裡：前提屬於依賴它的那一方。也刻意放在擷取窗口之內，
/// 它只產生 up 事件，不影響「卡住的 slot」與「按下次數」兩個判準。
private func releaseAllGuestSlots(_ client: EmulatorClient) async {
    let all = (0...10).map {
        TouchSpec(identifier: $0, point: NormPoint(x: 0.5, y: 0.5), down: false)
    }
    await client.sendTouches(all)
}

// 兩條測試共用 guest 的 slot，必須依序執行。
// Swift 斷言只驗本機狀態；guest 是否收到 up 由 verify_keymap_release.sh 的 getevent
// 判定。單獨執行本測試並顯示綠色，不代表已驗證 guest 釋放。
@MainActor
@Suite(.serialized) struct KeymapReleaseLiveTests {
    @Test(.enabled(if: KeymapReleaseLiveGate.live, "需 MIRAGE_LIVE=1，請跑 scripts/verify_keymap_release.sh"))
    func releasesJoystickTouchOnFocusLossAndReload() async throws {
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        do {
            // 健康探測填好 guestDisplay 前，sendTouches 會靜默略過注入。
            try await Task.sleep(for: .seconds(2))
            await releaseAllGuestSlots(client)
            try await Task.sleep(for: .milliseconds(300))
            let queue = InputQueue(injector: client)
            let c = KeymapController(queue: queue, profile: releaseLiveProfile())
            #expect(c.hasProfile)
            c.handleKeyDown(.key("w"))
            try await Task.sleep(for: .milliseconds(600))
            c.loseFocus() // D11
            try await Task.sleep(for: .milliseconds(600))
            c.handleKeyDown(.key("w"))
            try await Task.sleep(for: .milliseconds(600))
            c.reload(nil) // D23
            try await Task.sleep(for: .milliseconds(600))
            #expect(!c.hasProfile)
        } catch {
            await client.stop()
            throw error
        }
        await client.stop()
    }

    @Test(.enabled(if: KeymapReleaseLiveGate.live, "需 MIRAGE_LIVE=1，請跑 scripts/verify_keymap_release.sh"))
    func resignKeyNotificationReleasesTouch() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-appmodel-release-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: ProfileStore(directory: dir), starterBindings: { [] })
        await model.client.start(box: LatestFrameBox(), width: 540, height: 1200)
        do {
            try await Task.sleep(for: .seconds(2))
            await releaseAllGuestSlots(model.client)
            try await Task.sleep(for: .milliseconds(300))
            model.loadKeymap()
            model.setupFocusTracking()
            let keymap = try #require(model.keymap)
            keymap.reload(releaseLiveProfile())
            #expect(keymap.hasProfile)
            keymap.handleKeyDown(.key("w"))
            try await Task.sleep(for: .milliseconds(600))
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: nil)
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            await model.client.stop()
            throw error
        }
        await model.client.stop()
    }
}
