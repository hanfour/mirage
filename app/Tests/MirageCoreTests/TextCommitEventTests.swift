import Testing
@testable import MirageCore

@Suite struct TextCommitEventTests {
    @Test func pasteEventsNeverUseTextOrPhysicalKeyCode() {
        for (key, down) in [("Control",true),("v",true),("v",false),("Control",false)] {
            let event = EmulatorClient.buildTextPasteKey(key, down: down)
            #expect(event.key == key)
            #expect(event.text.isEmpty && event.keyCode == 0)
            #expect(event.eventType == (down ? .keydown : .keyup))
        }
        #expect(TextContent.exactlyEqual(EmulatorClient.buildTextClipboard("é e\u{301}👩‍💻").text, "é e\u{301}👩‍💻"))
    }
    @Test func disconnectedCheckedAPIsThrowInsteadOfSilentlySucceeding() async {
        let client = EmulatorClient()
        await #expect(throws: (any Error).self) { try await client.writeTextClipboard("中文", timeout: .seconds(1)) }
        await #expect(throws: (any Error).self) { try await client.readTextClipboard(timeout: .seconds(1)) }
        await #expect(throws: (any Error).self) { try await client.sendTextKey("v", down: true, timeout: .seconds(1)) }
    }
}
