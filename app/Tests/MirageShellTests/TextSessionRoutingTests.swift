import Testing
import MirageCore
@testable import MirageShell

private struct TextSessionNoopInjector: InputInjecting {
    func sendTouches(_ touches: [TouchSpec]) async {}
    func sendKey(_ code: KeyCode, down: Bool) async {}
    func sendTap(nx: Double, ny: Double, down: Bool) async {}
}

@MainActor @Suite struct TextSessionRoutingTests {
    @Test func modeReloadAndFocusInvalidateTextBeforeRelease() {
        let queue = InputQueue(injector: TextSessionNoopInjector())
        let controller = KeymapController(queue: queue, profile: nil)
        let first = queue.textCoordinator.status.generation
        controller.setEditing(true)
        let editing = queue.textCoordinator.status.generation
        #expect(editing > first)
        controller.reload(nil)
        let reload = queue.textCoordinator.status.generation
        #expect(reload > editing)
        controller.loseFocus()
        #expect(queue.textCoordinator.status.generation > reload)
    }
}
