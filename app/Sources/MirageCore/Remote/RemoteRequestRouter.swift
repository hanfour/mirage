import Foundation

public enum RemoteRoute: Sendable, Equatable {
    case viewer
    case manifest
    case upgradeVideo
    case upgradeInput
    case upgradeAudio
    case forbidden
    case busy
    case videoRequired
    case notFound
    case methodNotAllowed
}

/// `GET /`、`/ws/video`、`/ws/input` 的路由決定（spec 第 5 節）。純函式，NIO 的
/// `shouldUpgrade` 與 HTTP 回應路徑都呼叫它，403／409 的判定只寫在這一處。
public enum RemoteRequestRouter {
    public static let manifestPath = "/manifest.webmanifest"
    public static let viewerPath = "/"
    public static let videoPath = "/ws/video"
    public static let audioPath = "/ws/audio"
    public static let inputPath = "/ws/input"
    public static let tokenQueryName = "t"
    private static let getMethod = "GET"

    public static func path(fromURI uri: String) -> String {
        String(uri.prefix { $0 != "?" && $0 != "#" })
    }

    public static func token(fromURI uri: String) -> String? {
        URLComponents(string: uri)?.queryItems?.first { $0.name == tokenQueryName }?.value
    }

    public static func route(method: String, uri: String, token: PairingToken, state: RemoteSessionState) -> RemoteRoute {
        guard method == getMethod else { return .methodNotAllowed }
        guard token.matches(Self.token(fromURI: uri)) else { return .forbidden }
        switch path(fromURI: uri) {
        case viewerPath: return .viewer
        case manifestPath: return .manifest
        case videoPath: return state.hasVideo ? .busy : .upgradeVideo
        case inputPath:
            guard state.hasVideo else { return .videoRequired }
            return state.hasInput ? .busy : .upgradeInput
        case audioPath:
            guard state.hasVideo else { return .videoRequired }
            return state.hasAudio ? .busy : .upgradeAudio
        default: return .notFound
        }
    }
}
