import AppKit
import Testing
@testable import MirageCore
@testable import MirageShell

/// 只測 `populate(remoteMenu:)`：建 `MenuBarController` 本身會在開發機的選單列放狀態列圖示
/// （比照 `MenuBarInstanceMenuTests`）。
@MainActor
@Suite struct MenuBarRemoteMenuTests {
    private let toggle = NSSelectorFromString("remoteToggleTapped")
    private let copy = NSSelectorFromString("remoteCopyTapped:")
    private let rotate = NSSelectorFromString("remoteRotateTapped")
    private let disconnect = NSSelectorFromString("remoteDisconnectTapped")
    private let url = "http://192.168.1.61:8765/?t=00112233445566778899aabbccddeeff"

    private func populate(_ menu: NSMenu, _ entries: [RemoteMenuEntry], target: AnyObject) {
        MenuBarController.populate(remoteMenu: menu, entries: entries, target: target,
                                   toggleAction: toggle, copyAction: copy, disconnectAction: disconnect, rotateAction: rotate,
                                   qrImage: { QRCodeImage.make($0, side: RemoteMenu.qrSide) })
    }

    @Test func buildsOneItemPerEntryWithActionsAndQRView() throws {
        let menu = NSMenu()
        let target = NSObject()
        let session = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: true, hasAudio: false)
        populate(menu, RemoteMenu.entries(.on(urls: [url], addresses: [.init(interface: "en0", ip: "192.168.1.61")], session: session)), target: target)

        #expect(menu.items.count == 8)
        #expect(menu.items[0].title == RemoteMenu.disableTitle)
        #expect(menu.items[0].action == toggle)
        #expect(menu.items[0].target === target)
        #expect(menu.items[1].title == "狀態：已連線")
        #expect(!menu.items[1].isEnabled)
        #expect(menu.items[2].title == "拉取率上限：30 fps")
        #expect(!menu.items[2].isEnabled)
        #expect(menu.items[2].action == nil)
        #expect(menu.items[3].title == "連線：等待手機回報")
        #expect(!menu.items[3].isEnabled)
        #expect(menu.items[3].action == nil)
        #expect(menu.items[4].title == "網址：\(url)（點一下複製）")
        #expect(menu.items[4].action == copy)
        let represented = try #require(menu.items[4].representedObject as? String)
        #expect(represented == url)
        let view = try #require(menu.items[5].view as? NSImageView)
        #expect(view.frame.size == NSSize(width: RemoteMenu.qrSide, height: RemoteMenu.qrSide))
        #expect(view.image != nil)
        #expect(menu.items[6].title == RemoteMenu.rotateTokenTitle)
        #expect(menu.items[6].action == rotate)
        #expect(menu.items[6].isEnabled)
        #expect(menu.items[7].title == RemoteMenu.disconnectTitle)
        #expect(menu.items[7].isEnabled)
        #expect(menu.items[7].action == disconnect)
    }

    @Test func permissionHintAndEnvironmentOverrideHaveNoAction() throws {
        let menu = NSMenu()
        populate(menu, RemoteMenu.entries(.on(urls: [], addresses: [], session: .initial), canRotateToken: false), target: NSObject())
        for title in [RemoteMenu.localNetworkHint, RemoteMenu.overriddenTokenTitle] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(!item.isEnabled)
            #expect(item.action == nil)
        }
    }

    @Test func rebuildingMenuReplacesReadOnlyQualityWithLatestReport() throws {
        let menu = NSMenu(), target = NSObject()
        let state = RemoteMenuState.on(urls: [], addresses: [],
                                       session: .init(phase: .connected, hasVideo: true, hasInput: true, hasAudio: true))
        populate(menu, RemoteMenu.entries(state), target: target)
        for rtt in [15.0, 42.0] {
            let stats = RemoteClientStats(rtt: rtt, dropped: 2, decodeFps: 30)
            populate(menu, RemoteMenu.entries(state, clientStats: stats), target: target)
            let rows = menu.items.filter { $0.title.hasPrefix("連線：") }
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.title == RemoteMenu.connectionText(stats))
            #expect(!row.isEnabled)
            #expect(row.action == nil)
        }
    }

    @Test func disabledDisconnectHasNoActionAndOffMenuHasTwoItems() {
        let menu = NSMenu()
        populate(menu, RemoteMenu.entries(.on(urls: [url], addresses: [.init(interface: "en0", ip: "192.168.1.61")], session: .initial)), target: NSObject())
        let last = menu.items[menu.items.count - 1]
        #expect(!last.isEnabled)
        #expect(last.action == nil)

        populate(menu, RemoteMenu.entries(.off), target: NSObject())   // 每次展開重建，舊項目不殘留
        #expect(menu.items.map(\.title) == [RemoteMenu.enableTitle, "狀態：未開啟"])
    }
}
