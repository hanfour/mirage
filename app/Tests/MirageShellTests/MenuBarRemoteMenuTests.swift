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
    private let disconnect = NSSelectorFromString("remoteDisconnectTapped")
    private let url = "http://192.168.1.61:8765/?t=00112233445566778899aabbccddeeff"

    private func populate(_ menu: NSMenu, _ entries: [RemoteMenuEntry], target: AnyObject) {
        MenuBarController.populate(remoteMenu: menu, entries: entries, target: target,
                                   toggleAction: toggle, copyAction: copy, disconnectAction: disconnect,
                                   qrImage: { QRCodeImage.make($0, side: RemoteMenu.qrSide) })
    }

    @Test func buildsOneItemPerEntryWithActionsAndQRView() throws {
        let menu = NSMenu()
        let target = NSObject()
        let session = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: true)
        populate(menu, RemoteMenu.entries(.on(urls: [url], session: session)), target: target)

        #expect(menu.items.count == 6)
        #expect(menu.items[0].title == RemoteMenu.disableTitle)
        #expect(menu.items[0].action == toggle)
        #expect(menu.items[0].target === target)
        #expect(menu.items[1].title == "狀態：已連線")
        #expect(!menu.items[1].isEnabled)
        #expect(menu.items[2].title == "拉取率：30 fps")
        #expect(!menu.items[2].isEnabled)
        #expect(menu.items[2].action == nil)
        #expect(menu.items[3].title == "網址：\(url)（點一下複製）")
        #expect(menu.items[3].action == copy)
        let represented = try #require(menu.items[3].representedObject as? String)
        #expect(represented == url)
        let view = try #require(menu.items[4].view as? NSImageView)
        #expect(view.frame.size == NSSize(width: RemoteMenu.qrSide, height: RemoteMenu.qrSide))
        #expect(view.image != nil)
        #expect(menu.items[5].title == RemoteMenu.disconnectTitle)
        #expect(menu.items[5].isEnabled)
        #expect(menu.items[5].action == disconnect)
    }

    @Test func disabledDisconnectHasNoActionAndOffMenuHasTwoItems() {
        let menu = NSMenu()
        populate(menu, RemoteMenu.entries(.on(urls: [url], session: .initial)), target: NSObject())
        let last = menu.items[menu.items.count - 1]
        #expect(!last.isEnabled)
        #expect(last.action == nil)

        populate(menu, RemoteMenu.entries(.off), target: NSObject())   // 每次展開重建，舊項目不殘留
        #expect(menu.items.map(\.title) == [RemoteMenu.enableTitle, "狀態：未開啟"])
    }
}
