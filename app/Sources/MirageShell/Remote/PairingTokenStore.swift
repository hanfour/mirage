import Foundation
import MirageCore

/// 與 AppModel 分離，測試使用獨立 suite，不碰使用者保存的配對碼。
final class PairingTokenStore {
    static let key = "mirage.remote.pairingToken"
    private let defaults: UserDefaults
    let override: PairingToken?

    init(defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        override = environment[RemoteLaunchOptions.tokenKey].flatMap { PairingToken(value: $0) }
    }

    func token(rotate: Bool = false) -> PairingToken {
        // 活體腳本的指定值不污染使用者保存的 token，且跨重新啟用仍優先。
        if let override { return override }
        let token = PairingToken.selected(existing: defaults.string(forKey: Self.key), rotate: rotate,
                                          replacement: PairingToken.generate())
        defaults.set(token.value, forKey: Self.key)
        return token
    }
}
