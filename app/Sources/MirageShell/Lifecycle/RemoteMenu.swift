import Foundation
import MirageCore

/// 「手機遙控」子選單顯示的狀態。由 `AppModel` 在 MainActor 上維護，選單展開前讀一次。
enum RemoteMenuState: Equatable {
    case off
    case failed(String)
    case on(urls: [String], session: RemoteSessionState)
}

/// 子選單的一列。`qr` 與 `url` 分開：QR 只畫第一個網址，網址每個都列。
enum RemoteMenuEntry: Equatable {
    case toggle(title: String)
    case status(String)
    case url(String)
    case qr(String)
    case disconnect(enabled: Bool)
}

/// 子選單內容的純決策：狀態 → 列表。無 AppKit、無 I/O，逐條單元測試（比照 `InstanceMenu`）。
enum RemoteMenu {
    static let enableTitle = "開啟手機遙控"
    static let disableTitle = "關閉手機遙控"
    static let disconnectTitle = "中斷連線"
    static let noAddressText = "找不到本機 IPv4 位址，請確認 Wi-Fi 或 Tailscale"
    static let qrSide: CGFloat = 176

    static func entries(_ state: RemoteMenuState,
                        pullInterval: Duration = .nanoseconds(1_000_000_000 / 30),
                        clientStats: RemoteClientStats? = nil) -> [RemoteMenuEntry] {
        switch state {
        case .off:
            return [.toggle(title: enableTitle), .status("狀態：未開啟")]
        case .failed(let message):
            return [.toggle(title: enableTitle), .status("錯誤：\(message)")]
        case .on(let urls, let session):
            let addresses: [RemoteMenuEntry] = urls.isEmpty
                ? [.status(noAddressText)]
                : urls.map { .url($0) } + [.qr(urls[0])]
            return [.toggle(title: disableTitle), .status(statusText(session)), .status(pullRateText(pullInterval))]
                + (session.isViewerConnected ? [.status(connectionText(clientStats))] : [])
                + addresses
                + [.disconnect(enabled: session.isViewerConnected)]
        }
    }

    static func connectionText(_ stats: RemoteClientStats?) -> String {
        guard let stats else { return "連線：等待手機回報" }
        return "連線：RTT \(String(format: "%.0f", stats.rtt)) ms · 丟幀 \(stats.dropped) · \(String(format: "%.0f", stats.decodeFps)) fps"
    }

    static func pullRateText(_ interval: Duration) -> String {
        let c = interval.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        let fps = seconds > 0 ? (1 / seconds).rounded() : 0
        return "拉取率上限：\(String(format: "%.0f", fps)) fps"
    }

    static func statusText(_ session: RemoteSessionState) -> String {
        switch session.phase {
        case .waitingForPairing: return "狀態：等待配對"
        case .connected: return "狀態：已連線"
        case .disconnected: return "狀態：已斷線（同一網址可重連）"
        }
    }
}
