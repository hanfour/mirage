import Foundation
import GRPC

extension EmulatorClient: TextCommitTransport {
    static func buildTextClipboard(_ text: String) -> Android_Emulation_Control_ClipData {
        var request = Android_Emulation_Control_ClipData()
        request.text = text
        return request
    }
    static func buildTextPasteKey(_ key: String, down: Bool) -> Android_Emulation_Control_KeyboardEvent {
        var request = Android_Emulation_Control_KeyboardEvent()
        request.key = key
        request.eventType = down ? .keydown : .keyup
        return request
    }
    private func textOptions(_ timeout: Duration) -> CallOptions {
        let c = timeout.components
        let ms = c.seconds * 1_000 + c.attoseconds / 1_000_000_000_000_000
        var options = CallOptions()
        options.timeLimit = .timeout(.milliseconds(max(1, ms)))
        return options
    }
    public func writeTextClipboard(_ text: String, timeout: Duration) async throws {
        guard let client = channelBox?.client else { throw TextCommitIssue.transport("not-connected") }
        _ = try await client.setClipboard(Self.buildTextClipboard(text), callOptions: textOptions(timeout))
    }
    public func readTextClipboard(timeout: Duration) async throws -> String {
        guard let client = channelBox?.client else { throw TextCommitIssue.transport("not-connected") }
        return try await client.getClipboard(.init(), callOptions: textOptions(timeout)).text
    }
    public func sendTextKey(_ key: String, down: Bool, timeout: Duration) async throws {
        guard let client = channelBox?.client else { throw TextCommitIssue.transport("not-connected") }
        _ = try await client.sendKey(Self.buildTextPasteKey(key, down: down), callOptions: textOptions(timeout))
    }
}
