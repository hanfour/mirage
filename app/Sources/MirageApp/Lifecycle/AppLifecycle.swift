import AppKit
import MirageCore

/// 生命週期協調：視窗關閉→休眠（不退出，選單列常駐）、喚醒→恢復、Cmd+Q→乾淨 teardown。
@MainActor
final class AppLifecycle: NSObject, NSWindowDelegate {
    private let client: EmulatorClient
    private var suspended = false

    init(client: EmulatorClient) { self.client = client }

    /// 視窗即將關閉 → 觸發休眠而非退出（回傳 false 阻止關閉，改為隱藏）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)                 // 隱藏視窗，app 續存（選單列常駐）
        suspended = true
        Task { await client.suspend() }
        return false
    }

    func wake(showing window: NSWindow?) {
        guard suspended else { window?.makeKeyAndOrderFront(nil); return }
        suspended = false
        window?.makeKeyAndOrderFront(nil)
        Task { await client.wake() }
    }
}
