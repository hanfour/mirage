import AppKit
import Testing
@testable import MirageCore
@testable import MirageShell

/// 只測 `populate`（static、吃一個 NSMenu）：建 `MenuBarController` 本身會在開發機的
/// 選單列放一個狀態列圖示（RESULTS-shell-target.md 的全域副作用清單），headless 測試不碰。
@MainActor
@Suite struct MenuBarInstanceMenuTests {
    private let game = EmulatorInstance(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 1)
    private let poc = EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 2)
    private let onGame = EmulatorEndpoint(host: "localhost", port: 8554)
    private let action = NSSelectorFromString("instanceTapped:")

    @Test func populateBuildsOneItemPerEntryWithCheckAndTarget() throws {
        let menu = NSMenu()
        let target = NSObject()
        let entries = InstanceMenu.entries(instances: [game, poc], current: onGame)

        MenuBarController.populate(instanceMenu: menu, entries: entries, target: target, action: action)

        #expect(menu.items.map(\.title) == entries.map(\.title))
        #expect(menu.items.map(\.state) == [.on, .off])
        #expect(menu.items.allSatisfy(\.isEnabled))
        #expect(menu.items.allSatisfy { $0.target === target && $0.action == action })
        #expect(try #require(menu.items[1].representedObject as? EmulatorInstance) == poc)
    }

    /// 規格 §3.3：沒有其他實例 → 一個停用項，沒有 action、不打勾。
    @Test func placeholderIsSingleDisabledItem() {
        let menu = NSMenu()
        let entries = InstanceMenu.entries(instances: [game], current: onGame)

        MenuBarController.populate(instanceMenu: menu, entries: entries, target: NSObject(), action: action)

        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == InstanceMenu.placeholderTitle)
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[0].action == nil)
        #expect(menu.items[0].target == nil)
        #expect(menu.items[0].state == .off)
    }

    /// 每次展開都重建：上一次的項目不得殘留（與「套用 profile」的 removeAllItems 同一條）。
    @Test func populateReplacesPreviousItems() {
        let menu = NSMenu()
        MenuBarController.populate(instanceMenu: menu,
                                   entries: InstanceMenu.entries(instances: [game, poc], current: onGame),
                                   target: NSObject(), action: action)
        #expect(menu.items.count == 2)

        MenuBarController.populate(instanceMenu: menu,
                                   entries: InstanceMenu.entries(instances: [], current: onGame),
                                   target: NSObject(), action: action)
        #expect(menu.items.map(\.title) == [InstanceMenu.placeholderTitle])
    }
}
