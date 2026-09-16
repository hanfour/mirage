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
                       "decodeQueueSize", "type:'ping'", "frame.close()", "type:'touches'", "requestAnimationFrame(flushTouches)",
                       "/ws/audio", "createBufferSource", "decodeAudioMessage"] {
            #expect(html.contains(needle), "viewer.html 缺 \(needle)")
        }
        // 只檢查已知的那一個標記擋不住新加的：viewer-audio.js 的標記加進 HTML 時，
        // Swift 這側沒有一起加替換，JS 測試全綠而成品帶著一行註解出去、
        // viewer-input.js 呼叫不存在的函式。改成不得殘留任何 MIRAGE_VIEWER_ 前綴。
        #expect(!html.contains("MIRAGE_VIEWER_"))
        #expect(!html.contains("requestFullscreen"))
        #expect(!html.contains("params.get('codec')"))
    }
}
