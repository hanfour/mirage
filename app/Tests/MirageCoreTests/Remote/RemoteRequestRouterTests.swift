import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteRequestRouterTests {
    private let token = PairingToken(value: "00112233445566778899aabbccddeeff")!
    private let good = "?t=00112233445566778899aabbccddeeff"
    private let idle = RemoteSessionState.initial
    private let videoOnly = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: false)
    private let full = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: true)

    private func route(_ uri: String, method: String = "GET", state: RemoteSessionState? = nil) -> RemoteRoute {
        RemoteRequestRouter.route(method: method, uri: uri, token: token, state: state ?? idle)
    }

    @Test func tokenParsingHandlesPositionAndAbsence() {
        #expect(RemoteRequestRouter.token(fromURI: "/?t=abc") == "abc")
        #expect(RemoteRequestRouter.token(fromURI: "/ws/video?x=1&t=abc") == "abc")
        #expect(RemoteRequestRouter.token(fromURI: "/ws/video?t=abc&x=1") == "abc")
        #expect(RemoteRequestRouter.token(fromURI: "/ws/video") == nil)
        #expect(RemoteRequestRouter.token(fromURI: "/?token=abc") == nil)
        #expect(RemoteRequestRouter.path(fromURI: "/ws/video?t=abc#frag") == "/ws/video")
        #expect(RemoteRequestRouter.path(fromURI: "/") == "/")
    }

    @Test func viewerNeedsExactToken() {
        #expect(route("/" + good) == .viewer)
        #expect(route("/") == .forbidden)
        #expect(route("/?t=00112233445566778899aabbccddeefe") == .forbidden)
        #expect(route("/?t=") == .forbidden)
    }

    @Test func manifestRequiresPairingAndOnlyAcceptsGet() {
        #expect(route("/manifest.webmanifest" + good) == .manifest)
        #expect(route("/manifest.webmanifest" + good, state: full) == .manifest)
        #expect(route("/manifest.webmanifest") == .forbidden)
        #expect(route("/manifest.webmanifest?t=nope") == .forbidden)
        #expect(route("/manifest.webmanifest" + good, method: "POST") == .methodNotAllowed)
        #expect(route("/manifest.webmanifest/" + good) == .notFound)
    }

    @Test func manifestResponseLoadsBundledStandaloneConfiguration() throws {
        let response = RemoteHTTPConnection.response(for: .manifest, viewerPage: Data())
        #expect(response.status.code == 200)
        #expect(response.contentType == "application/manifest+json; charset=utf-8")
        let manifest = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: String])
        #expect(manifest["name"] == "Mirage")
        #expect(manifest["display"] == "standalone")
        #expect(manifest["orientation"] == "portrait")
        #expect(manifest["background_color"] == "#000000")
        #expect(manifest["start_url"] == nil)
    }

    @Test func upgradesDependOnSessionState() {
        #expect(route("/ws/video" + good) == .upgradeVideo)
        #expect(route("/ws/input" + good) == .videoRequired)
        #expect(route("/ws/video" + good, state: videoOnly) == .busy)
        #expect(route("/ws/input" + good, state: videoOnly) == .upgradeInput)
        #expect(route("/ws/video" + good, state: full) == .busy)
        #expect(route("/ws/input" + good, state: full) == .busy)
    }

    @Test func inputRequiresVideoAfterDisconnectAndStillChecksTokenFirst() {
        let disconnected = RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false)
        #expect(route("/ws/input" + good, state: disconnected) == .videoRequired)
        #expect(route("/ws/input?t=nope") == .forbidden)
        #expect(route("/ws/input", state: disconnected) == .forbidden)
    }

    @Test func wrongTokenIsForbiddenEvenWhenBusyOrUnknownPath() {
        #expect(route("/ws/video?t=nope", state: full) == .forbidden)
        #expect(route("/ws/input", state: full) == .forbidden)
        #expect(route("/secret") == .forbidden)
    }

    @Test func unknownPathWithValidTokenIsNotFound() {
        #expect(route("/index.html" + good) == .notFound)
        #expect(route("/ws/audio" + good) == .notFound)
        #expect(route("/ws/video/" + good) == .notFound)
    }

    @Test(arguments: ["POST", "PUT", "HEAD", "OPTIONS"])
    func nonGetIsRejectedBeforeTokenCheck(method: String) {
        #expect(route("/" + good, method: method) == .methodNotAllowed)
        #expect(route("/ws/video?t=nope", method: method) == .methodNotAllowed)
    }
}
