import Foundation

/// 單一綁定：tap（技能鍵）、joystick（方向移動）、look（滑鼠視角）。不可變值型別。
public enum Binding: Sendable, Codable, Equatable {
    case tap(key: KeyCode, at: NormPoint)
    case joystick(up: KeyCode, down: KeyCode, left: KeyCode, right: KeyCode,
                  center: NormPoint, radius: Double)   // radius 為正規化半徑
    case look(activation: KeyCode?, sensitivity: Double)  // activation=nil 表 always-on
}

public struct KeymapProfile: Sendable, Codable, Equatable {
    public let gameId: String
    public let version: Int
    public let bindings: [Binding]
    public init(gameId: String, version: Int, bindings: [Binding]) {
        self.gameId = gameId; self.version = version; self.bindings = bindings
    }
}

public enum ProfileError: Error, Equatable {
    case invalidCoordinate
    case invalidRadius
    case invalidSensitivity
    case identifierConflict
}

public extension KeymapProfile {
    /// 載入期 fail-fast 驗證：座標 0–1、radius>0、sensitivity>0。回傳自身供鏈式使用。
    func validated() throws -> KeymapProfile {
        for b in bindings {
            switch b {
            case .tap(_, let at):
                guard at.isValid else { throw ProfileError.invalidCoordinate }
            case .joystick(_, _, _, _, let center, let radius):
                guard center.isValid else { throw ProfileError.invalidCoordinate }
                guard radius > 0 else { throw ProfileError.invalidRadius }
            case .look(_, let sensitivity):
                guard sensitivity > 0 else { throw ProfileError.invalidSensitivity }
            }
        }
        // KeymapEngine 對 joystick/look 採一對一 id 模型：多餘的綁定會被靜默丟棄。
        // 在此 fail-fast，避免載入期靜默遺失使用者設定。
        let joystickCount = bindings.filter { if case .joystick = $0 { return true }; return false }.count
        let lookCount = bindings.filter { if case .look = $0 { return true }; return false }.count
        guard joystickCount <= 1, lookCount <= 1 else { throw ProfileError.identifierConflict }
        return self
    }
}
