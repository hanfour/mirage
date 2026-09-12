import MirageCore

/// 配對網址（spec 第 5 節）：`http://<主機位址>:<埠>/?t=<token>`。不做 HTTPS，理由見 spec 第 1 節。
enum RemoteURL {
    static func build(host: String, port: Int, token: PairingToken) -> String {
        "http://\(host):\(port)/?t=\(token.value)"
    }

    static func all(addresses: [HostAddress], port: Int, token: PairingToken) -> [String] {
        HostAddresses.ordered(addresses).map { build(host: $0.ip, port: port, token: token) }
    }
}
