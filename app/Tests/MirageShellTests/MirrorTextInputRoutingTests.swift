import AppKit
import Testing
import MirageCore
@testable import MirageShell

@MainActor @Suite struct MirrorTextInputRoutingTests {
    func event(_ type: NSEvent.EventType, code: UInt16 = 0, chars: String = "a") throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }
    @Test func textEventsAreInterpretedOnceWithoutGuestKeys() throws {
        let view = MirrorMTKView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        var interpreted = 0
        var keys: [KeyCode] = []
        view.interpretInput = { _ in interpreted += 1 }
        view.onKey = { code, _ in keys.append(code) }
        view.keyDown(with: try event(.keyDown))
        view.keyUp(with: try event(.keyUp))
        #expect(interpreted == 1)
        #expect(keys.isEmpty)
    }
    @Test func keyUpUsesOriginalCodeDespiteLayoutChange() throws {
        let view = MirrorMTKView(frame: .zero)
        view.textMode = false
        var keys: [KeyCode] = []
        view.onKey = { code, _ in keys.append(code) }
        view.keyDown(with: try event(.keyDown, chars: "a"))
        view.keyUp(with: try event(.keyUp, chars: "b"))
        #expect(keys == [.key("a"), .key("a")])
    }
}

private actor IMEShellTransport: InputInjecting, TextCommitTransport {
    var clipboard = ""
    var keys: [String] = []
    var operations: [String] = []
    func sendTouches(_ touches: [TouchSpec]) async {}
    func sendKey(_ code: KeyCode, down: Bool) async { operations.append("key") }
    func sendTap(nx: Double, ny: Double, down: Bool) async {}
    func writeTextClipboard(_ text: String, timeout: Duration) async throws { operations.append("write"); clipboard = text }
    func readTextClipboard(timeout: Duration) async throws -> String { operations.append("read"); return clipboard }
    func sendTextKey(_ key: String, down: Bool, timeout: Duration) async throws { operations.append("paste"); keys.append("\(key):\(down)") }
}

@MainActor @Suite struct TextInputModeTests {
    @Test func defaultsAndExplicitMode() {
        let state = TextInputPresentation(queue: InputQueue(injector: IMEShellTransport()))
        #expect(state.usesText(hasProfile: false))
        #expect(!state.usesText(hasProfile: true))
        state.mode = .text
        #expect(state.usesText(hasProfile: true))
        state.mode = .keymap
        #expect(!state.usesText(hasProfile: false))
    }
    @Test func markedReturnEscapeFlagsAndLateCallbacksDoNotLeak() throws {
        let view = MirrorMTKView(frame: .zero)
        var keys = 0
        var flags = 0
        view.onKey = { _, _ in keys += 1 }
        view.onFlagsChanged = { _ in flags += 1 }
        let event = try MirrorTextInputRoutingTests().event(.keyDown, code: 36, chars: "\r")
        view.interpretInput = { _ in
            view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.doCommand(by: NSSelectorFromString("insertNewline:"))
        }
        view.keyDown(with: event)
        #expect(view.hasMarkedText())
        view.flagsChanged(with: event)
        view.keyUp(with: try MirrorTextInputRoutingTests().event(.keyUp, code: 36, chars: "\r"))
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(keys == 0)
        #expect(flags == 0)
    }
    @Test func remoteEnqueueKeepsReadbackPasteAndFollowingKeyInOrder() async throws {
        let transport = IMEShellTransport()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let diagnostics = TextInputDiagnostics(path: path.path)
        let policy = try TextSubmissionPolicy(settleMilliseconds: 1)
        let queue = InputQueue(injector: transport, textTransport: transport,
                               textPolicy: .success(policy), textDiagnostics: diagnostics)
        let state = TextInputPresentation(queue: queue)
        state.localDraft = "Mac 草稿"
        await Task.detached {
            state.enqueue("遠端中文🙂", origin: "remote")
            queue.key(.key("Backspace"), down: true)
        }.value
        await queue.drained()
        let operations = await transport.operations
        #expect(operations == ["write", "read", "paste", "paste", "paste", "paste", "key"])
        #expect(await transport.clipboard == "遠端中文🙂")
        #expect(state.localDraft == "Mac 草稿")
        let trace = try String(contentsOf: path, encoding: .utf8)
        #expect(trace.contains(#""origin":"remote""#))
        #expect(trace.contains("commit-enqueued"))
    }

    @Test func viewCommitGoesThroughOnePasteAndPolicyRejectRetainsDraft() async throws {
        let transport = IMEShellTransport()
        let queue = InputQueue(injector: transport)
        let state = TextInputPresentation(queue: queue)
        state.settle = "1"; state.applyPolicy()
        let view = MirrorMTKView(frame: .zero)
        view.textInput = state
        view.interpretInput = { _ in
            view.insertText("中文👩‍👩‍👧‍👦é", replacementRange: NSRange(location: NSNotFound, length: 0))
            view.unmarkText()
            view.doCommand(by: NSSelectorFromString("insertNewline:"))
        }
        view.keyDown(with: try MirrorTextInputRoutingTests().event(.keyDown))
        await queue.drained()
        #expect(await transport.keys == ["Control:true", "v:true", "v:false", "Control:false"])
        #expect(await transport.clipboard == "中文👩‍👩‍👧‍👦é")
        state.settle = "0"; state.applyPolicy()
        view.keyDown(with: try MirrorTextInputRoutingTests().event(.keyDown))
        await queue.drained()
        for _ in 0..<100 where state.results.count < 2 { await Task.yield() }
        #expect(state.results.count == 2)
        #expect(state.results.last?.outcome == .rejected(.invalidPolicy("settle")))
        #expect(state.results.last?.commit.text == "中文👩‍👩‍👧‍👦é")
        #expect(await transport.keys.count == 4)
    }
}

@MainActor @Suite struct TextSubmissionStatusTests {
    @Test func unknownIsNotSuccessAndResumeDoesNotReplay() async {
        let transport = IMEShellTransport()
        let state = TextInputPresentation(queue: InputQueue(injector: transport))
        let result = TextCommitResult(commit: TextCommit(text: "保留", generation: 0), outcome: .indeterminateAfterDispatch(.transport("timeout")))
        state.record(result)
        #expect(TextInputPresentation.label(result.outcome).contains("不確定"))
        state.pause()
        state.resume(acknowledgingUncertainty: true)
        await state.queue.drained()
        #expect(state.results.first?.commit.text == "保留")
        #expect(await transport.keys.isEmpty)
    }
}
