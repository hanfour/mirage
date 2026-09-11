import AppKit
import Testing
import MirageCore
@testable import MirageShell

@MainActor @Suite(.serialized) struct TextInputGeometryTests {
    @Test func negativeScreenOriginAndInsertionRange() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -700, y: -250, width: 240, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let mirror = MirrorMTKView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView = mirror
        _ = mirror.session.mark("é👩‍👩‍👧‍👦", selection: NSRange(location: 12, length: 0), replacement: NSRange(location: NSNotFound, length: 0))
        mirror.updateMarkedOverlay()
        var range = NSRange()
        let rect = mirror.firstRect(forCharacterRange: NSRange(location: NSNotFound, length: 0), actualRange: &range)
        #expect(range == NSRange(location: 12, length: 0))
        #expect(rect.minX < 0)
        #expect(rect.width == 1 && rect.height > 0)
        #expect(mirror.markedOverlay.superview === mirror)
    }
    @Test func realWindowConversionsAfterMoveAndResize() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 360, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let mirror = MirrorMTKView(frame: NSRect(x: 20, y: 30, width: 300, height: 500))
        try #require(window.contentView).addSubview(mirror)
        let overlay = mirror.markedOverlay
        _ = mirror.session.mark("A🙂中文", selection: NSRange(location: 3, length: 1), replacement: NSRange(location: NSNotFound, length: 0))
        mirror.compositionAnchor = CGPoint(x: 0.25, y: 0.2)
        mirror.updateMarkedOverlay()
        var actual = NSRange(location: NSNotFound, length: 0)
        let before = mirror.firstRect(forCharacterRange: NSRange(location: 1, length: 2), actualRange: &actual)
        #expect(actual == NSRange(location: 1, length: 2))
        #expect(before.width > 0 && before.height > 0)
        #expect(overlay.hitTest(NSPoint(x: 2, y: 2)) == nil)
        #expect(!overlay.acceptsFirstResponder)
        let original = window.frame.origin
        window.setFrameOrigin(NSPoint(x: original.x + 97, y: original.y + 53))
        let moved = mirror.firstRect(forCharacterRange: actual, actualRange: nil)
        #expect(abs(moved.minX - before.minX - 97) < 0.01)
        #expect(abs(moved.minY - before.minY - 53) < 0.01)
        mirror.setFrameSize(NSSize(width: 250, height: 420))
        mirror.updateMarkedOverlay()
        let resized = mirror.firstRect(forCharacterRange: actual, actualRange: nil)
        let (glyph, _) = overlay.glyphRect(actual)
        let back = overlay.convert(window.convertFromScreen(resized), from: nil)
        #expect(abs(back.minX - glyph.minX) < 0.01)
        #expect(abs(back.minY - glyph.minY) < 0.01)
        #expect(mirror.bounds.contains(overlay.frame))
        if let directory = ProcessInfo.processInfo.environment["MIRAGE_GEOMETRY_EVIDENCE"] {
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            window.orderFront(nil)
            window.displayIfNeeded()
            let screenshot = Process()
            screenshot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            screenshot.arguments = ["-x", "-l", String(window.windowNumber), root.appendingPathComponent("window.png").path]
            try screenshot.run(); screenshot.waitUntilExit()
            #expect(screenshot.terminationStatus == 0)
            let report: [String: Any] = ["kind": "synthetic-preedit-real-AppKit-window",
                "humanIMEVerified": false, "backingScale": window.backingScaleFactor,
                "before": NSStringFromRect(before), "moved": NSStringFromRect(moved),
                "resized": NSStringFromRect(resized), "inverseErrorPoints": [abs(back.minX - glyph.minX), abs(back.minY - glyph.minY)],
                "moveErrorPoints": [abs(moved.minX - before.minX - 97), abs(moved.minY - before.minY - 53)]]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("geometry.json"))
        }
    }
}
