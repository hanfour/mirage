import AppKit
import Foundation
import Testing
@testable import MirageShell

@MainActor
@Suite struct MirrorWindowControllerTests {
    private final class Delegate: NSObject, NSWindowDelegate {}

    private func makeController(contentBuilds: @escaping () -> Void = {}) -> MirrorWindowController {
        MirrorWindowController(autosaveName: "MirrorWindowControllerTests.\(UUID().uuidString)") {
            contentBuilds()
            return NSView()
        }
    }

    @Test func windowIsCreatedOnceAndOnlyWhenAsked() {
        var builds = 0
        let controller = makeController { builds += 1 }
        #expect(controller.existingWindow == nil)
        #expect(builds == 0)
        let first = controller.window()
        let second = controller.window()
        #expect(first === second)
        #expect(controller.existingWindow === first)
        #expect(builds == 1)
    }

    @Test func windowIsConfiguredForMirroring() {
        let name = "MirrorWindowControllerTests.\(UUID().uuidString)"
        let window = MirrorWindowController(autosaveName: name) { NSView() }.window()
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.frameAutosaveName == name)
        #expect(!window.isReleasedWhenClosed)
        #expect(window.title == "Mirage")
        #expect(window.contentMinSize == MirrorWindowController.minimumContentSize)
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func delegateAttachedBeforeCreationIsApplied() {
        let controller = makeController()
        let delegate = Delegate()
        controller.attach(delegate: delegate)
        #expect(controller.existingWindow == nil)
        #expect(controller.window().delegate === delegate)
    }

    @Test func delegateAttachedAfterCreationIsApplied() {
        let controller = makeController()
        let window = controller.window()
        let delegate = Delegate()
        controller.attach(delegate: delegate)
        #expect(window.delegate === delegate)
    }
}
