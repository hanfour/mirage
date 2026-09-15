import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct RemoteMenuTests {
    private let urls = ["http://192.168.1.61:8765/?t=aa", "http://100.1.1.1:8765/?t=aa"]

    @Test func connectionQualityUsesLatestReportOnlyWhileConnected() {
        let connected = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: true)
        let state = RemoteMenuState.on(urls: urls, session: connected)
        #expect(RemoteMenu.entries(state).contains(.status("連線：等待手機回報")))
        let stats = RemoteClientStats(rtt: 15.2, dropped: 0, decodeFps: 29.8)
        #expect(RemoteMenu.entries(state, clientStats: stats).contains(.status("連線：RTT 15 ms · 丟幀 0 · 30 fps")))
        let idle = RemoteMenu.entries(.on(urls: urls, session: .initial), clientStats: stats)
        #expect(!idle.contains(.status(RemoteMenu.connectionText(stats))))
        #expect(RemoteMenu.connectionText(.init(rtt: 0, dropped: 12, decodeFps: 0)) == "連線：RTT 0 ms · 丟幀 12 · 0 fps")
    }

    @Test(arguments: [5, 30, 60]) func showsActualPullRate(_ fps: Int) {
        let entries = RemoteMenu.entries(.on(urls: urls, session: .initial),
                                         pullInterval: .nanoseconds(1_000_000_000 / Int64(fps)))
        #expect(entries.contains(.status("拉取率上限：\(fps) fps")))
    }

    @Test func offShowsEnableAndStatus() {
        #expect(RemoteMenu.entries(.off) == [.toggle(title: RemoteMenu.enableTitle), .status("狀態：未開啟")])
    }

    /// 錯誤時功能是關閉的（spec 第 7 節），所以仍是「開啟」，錯誤訊息當停用項顯示。
    @Test func failedShowsEnableAndError() {
        #expect(RemoteMenu.entries(.failed("埠 8765 被佔用")) == [
            .toggle(title: RemoteMenu.enableTitle), .status("錯誤：埠 8765 被佔用"),
        ])
    }

    /// 開啟中：關閉、狀態、每個網址一列、第一個網址的 QR、中斷連線（有 viewer 才可點）。
    @Test func onListsEveryURLAndQRForTheFirst() {
        let waiting = RemoteMenu.entries(.on(urls: urls, session: .initial))
        #expect(waiting == [
            .toggle(title: RemoteMenu.disableTitle),
            .status("狀態：等待配對"),
            .status("拉取率上限：30 fps"),
            .url(urls[0]), .url(urls[1]),
            .qr(urls[0]),
            .disconnect(enabled: false),
        ])
        let connected = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: true)
        #expect(RemoteMenu.entries(.on(urls: urls, session: connected)).last == .disconnect(enabled: true))
        #expect(RemoteMenu.entries(.on(urls: urls, session: connected))[1] == .status("狀態：已連線"))
        let dropped = RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false)
        #expect(RemoteMenu.entries(.on(urls: urls, session: dropped))[1] == .status("狀態：已斷線（同一網址可重連）"))
    }

    /// 沒有任何介面位址（沒接網路）：沒有 url、沒有 qr，狀態說明原因。
    @Test func onWithoutAddressesExplains() {
        #expect(RemoteMenu.entries(.on(urls: [], session: .initial)) == [
            .toggle(title: RemoteMenu.disableTitle),
            .status("狀態：等待配對"),
            .status("拉取率上限：30 fps"),
            .status("找不到本機 IPv4 位址，請確認 Wi-Fi 或 Tailscale"),
            .status(RemoteMenu.localNetworkHint),
            .disconnect(enabled: false),
        ])
    }
}
