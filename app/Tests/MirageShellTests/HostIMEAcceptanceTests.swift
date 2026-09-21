import AppKit
import SwiftUI
import Testing
import MirageCore
@testable import MirageShell

private actor IMEFailureTransport: InputInjecting, TextCommitTransport {
    /// `healthy` 是沒有任何傳輸故障的對照組，只給
    /// `focusDuringPasteNeitherPausesTheChannelNorReplays` 用：Paste 送出之後失焦
    /// 不是故障，所以它不屬於底下那組故障參數。
    enum Fault: String { case mismatch, timeout, disconnected, conflict, healthy }
    let fault: Fault
    var clipboard = ""
    var downs: [String] = []
    var signal: (@Sendable () -> Void)?
    func setSignal(_ signal: @escaping @Sendable () -> Void) { self.signal = signal }
    init(_ fault: Fault) { self.fault = fault }
    func sendTouches(_ touches: [TouchSpec]) async {}
    func sendKey(_ code: KeyCode, down: Bool) async {}
    func sendTap(nx: Double, ny: Double, down: Bool) async {}
    func writeTextClipboard(_ text: String, timeout: Duration) async throws {
        if fault == .disconnected { throw TextCommitIssue.transport("disconnected") }
        clipboard = text
    }
    func readTextClipboard(timeout: Duration) async throws -> String { fault == .mismatch ? "wrong" : clipboard }
    func sendTextKey(_ key: String, down: Bool, timeout: Duration) async throws {
        if down { downs.append(key) }
        if key == "v" && down { signal?() }
        if fault == .timeout && key == "v" && down { throw TextCommitIssue.transport("timeout") }
    }
}

@MainActor @Suite struct HostIMEAcceptanceTests {
    @Test(arguments: [IMEFailureTransport.Fault.mismatch, .timeout, .disconnected, .conflict])
    fileprivate func actualViewFailureRetainsDraftPausesAndNeverRetries(_ fault: IMEFailureTransport.Fault) async throws {
        let transport = IMEFailureTransport(fault)
        let evidence = ProcessInfo.processInfo.environment["MIRAGE_IME_FAILURE_EVIDENCE"].map { URL(fileURLWithPath: $0).appendingPathComponent(fault.rawValue) }
        if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false) }
        let diagnostics = TextInputDiagnostics(path: evidence?.appendingPathComponent("trace.jsonl").path)
        #expect(diagnostics.error == nil)
        let queue = InputQueue(injector: transport, textTransport: transport,
                               textPolicy: .success(try TextSubmissionPolicy(settleMilliseconds: 1, readbackTimeoutMilliseconds: 5)), textDiagnostics: diagnostics)
        if fault == .conflict { await transport.setSignal { _ = queue.observeGuestClipboard("external-new-value") } }
        let presentation = TextInputPresentation(queue: queue)
        let view = MirrorMTKView(frame: .zero)
        view.textInput = presentation
        view.interpretInput = { _ in
            view.setMarkedText("保留é", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText("保留é", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        view.keyDown(with: try MirrorTextInputRoutingTests().event(.keyDown))
        await queue.drained()
        for _ in 0..<100 where presentation.results.isEmpty { await Task.yield() }
        let first = try #require(presentation.results.first)
        #expect(first.commit.text == "保留é")
        #expect(first.outcome != .submittedUnverified)
        #expect(presentation.paused)
        if let evidence {
            _ = NSApplication.shared
            let window = NSWindow(contentRect: NSRect(x: 140, y: 100, width: 400, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Synthetic failure fixture: " + fault.rawValue
            window.contentView = NSHostingView(rootView: TextInputDetails(state: presentation))
            window.orderFront(nil); window.displayIfNeeded()
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), evidence.appendingPathComponent("status.png").path]
            try capture.run(); capture.waitUntilExit()
            window.close()
            #expect(capture.terminationStatus == 0)
        }
        let downCount = await transport.downs.count
        let dispatched = fault == .timeout || fault == .conflict
        #expect(downCount == (dispatched ? 2 : 0))
        view.keyDown(with: try MirrorTextInputRoutingTests().event(.keyDown))
        await queue.drained()
        #expect(await transport.downs.count == downCount)
        if dispatched {
            presentation.resume(acknowledgingUncertainty: false)
            #expect(presentation.paused)
            #expect(TextInputPresentation.label(first.outcome).contains("不確定"))
        } else { #expect(TextInputPresentation.label(first.outcome).contains("未送")) }
        presentation.resume(acknowledgingUncertainty: true)
        await queue.drained()
        #expect(await transport.downs.count == downCount)
        #expect(presentation.results.contains { $0.commit.id == first.commit.id })
        if let evidence {
            let report: [String: Any] = ["kind": "synthetic-view-and-transport-failure", "humanIMEVerified": false,
                "fault": fault.rawValue, "outcome": String(describing: first.outcome),
                "label": TextInputPresentation.label(first.outcome), "retainedText": first.commit.text,
                "downsAfterFailure": downCount, "downsAfterResume": await transport.downs.count,
                "autoReplay": false, "settleMS": 1, "note": "1ms is a fake-transport test value, not a live policy"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("result.json"))
        }
    }

    /// Paste 已經送給 guest 之後視窗失焦：那一筆照常完成，通道不暫停，也不重按 Paste。
    ///
    /// 舊行為是把它判成 `indeterminateAfterDispatch` 並設全域 `paused`，於是 Mac 上一次
    /// 焦點變動就讓手機遙控打字整個失效，且只剩鏡像視窗左下角那顆按鈕能解。
    @Test func focusDuringPasteNeitherPausesTheChannelNorReplays() async throws {
        let transport = IMEFailureTransport(.healthy)
        let queue = InputQueue(injector: transport, textTransport: transport,
                               textPolicy: .success(try TextSubmissionPolicy(settleMilliseconds: 1, readbackTimeoutMilliseconds: 5)))
        await transport.setSignal { queue.invalidateTextSession() }
        let presentation = TextInputPresentation(queue: queue)
        let view = MirrorMTKView(frame: .zero)
        view.textInput = presentation
        view.interpretInput = { _ in
            view.insertText("保留é", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        view.keyDown(with: try MirrorTextInputRoutingTests().event(.keyDown))
        await queue.drained()
        for _ in 0..<100 where presentation.results.isEmpty { await Task.yield() }
        let first = try #require(presentation.results.first)
        #expect(first.outcome == .submittedUnverified)
        #expect(!presentation.paused)
        #expect(await transport.downs == ["Control", "v"])

        // 通道仍然收件：下一筆真的送得出去，而且不是重播上一筆。
        view.keyDown(with: try MirrorTextInputRoutingTests().event(.keyDown))
        await queue.drained()
        for _ in 0..<100 where presentation.results.count < 2 { await Task.yield() }
        #expect(await transport.downs == ["Control", "v", "Control", "v"])
        #expect(presentation.results.count == 2)
        #expect(presentation.results[1].commit.id != first.commit.id)
    }

    @Test func focusCancelsMarkedAndLateUnmarkCannotSubmit() throws {
        let queue = InputQueue(injector: IMEFailureTransport(.timeout))
        let state = TextInputPresentation(queue: queue)
        let view = MirrorMTKView(frame: .zero)
        view.textInput = state
        view.interpretInput = { _ in
            view.setMarkedText("未完", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        view.keyDown(with: try MirrorTextInputRoutingTests().event(.keyDown))
        queue.invalidateTextSession()
        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(state.localDraft == "未完")
        #expect(queue.textCoordinator.status.pending == 0)
        #expect(state.results.isEmpty)
    }

    @Test func settingsDisplayActualQueuePolicy() throws {
        let transport = IMEFailureTransport(.mismatch)
        let queue = InputQueue(injector: transport, textTransport: transport,
                               textPolicy: .success(try TextSubmissionPolicy(settleMilliseconds: 137)))
        let state = TextInputPresentation(queue: queue)
        #expect(state.settle == "137")
    }

    @Test func diagnosticsAreExactPrivateAndRefuseOverwrite() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        let diagnostics = TextInputDiagnostics(path: path.path)
        diagnostics.record("marked", ["textSHA256": TextInputDiagnostics.hash("é")])
        #expect(TextInputDiagnostics.hash("é") != TextInputDiagnostics.hash("e\u{301}"))
        let data = try Data(contentsOf: path)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("é"))
        #expect(text.split(separator: "\n").count == 2)
        let duplicate = TextInputDiagnostics(path: path.path)
        #expect(duplicate.error != nil)
        #expect(try Data(contentsOf: path) == data)
    }
}
