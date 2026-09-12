import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteViewerPageTests {
    @Test func bundledPageIsPackagedAndSpeaksTheProtocol() throws {
        let page = try #require(RemoteViewerPage.bundled())
        let html = try #require(String(data: page, encoding: .utf8))
        for needle in ["<!doctype html>", "VideoDecoder", "optimizeForLatency", "/ws/video", "/ws/input",
                       "params.get('t')", "params.get('stats')", "touch-action:none", "user-select:none",
                       "-webkit-touch-callout:none", "overscroll-behavior:none", "gesturestart", "gesturechange",
                       "wakeLock", "getBigUint64(0, false)", "getUint32(8, false)", "getUint8(12)",
                       "decodeQueueSize", "type:'ping'", "frame.close()"] {
            #expect(html.contains(needle), "viewer.html 缺 \(needle)")
        }
        #expect(!html.contains("requestFullscreen"))
        #expect(!html.contains("params.get('codec')"))
    }
}
