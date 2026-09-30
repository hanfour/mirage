import AppKit
import Testing
@testable import MirageShell

@MainActor
@Suite struct MenuBarVolumeTests {
    @Test func volumeItemsDispatchW3CKeys() {
        let menu = NSMenu()
        let target = NSObject()
        let action = NSSelectorFromString("volumeTapped:")
        MenuBarController.addVolumeItems(to: menu, target: target, action: action)
        var sent: [String] = []

        for item in menu.items {
            MenuBarController.dispatchAndroidKey(item) { sent.append($0) }
        }

        #expect(menu.items.map(\.title) == ["音量調高", "音量調低"])
        #expect(menu.items.allSatisfy { $0.target === target && $0.action == action })
        #expect(sent == ["AudioVolumeUp", "AudioVolumeDown"])
    }
}
