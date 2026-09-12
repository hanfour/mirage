import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteTouchMessageTests {
    private func touch(_ text: String) throws -> RemoteTouchMessage {
        guard case .touch(let message) = try RemoteTouchMessageDecoder.decode(text).get() else {
            throw RemoteInputDecodeError.unknownType("expected touch")
        }
        return message
    }

    @Test func decodesSpecExampleDown() throws {
        let m = try touch(#"{"t": 1234.5, "id": 7, "type": "down", "x": 0.49, "y": 0.75}"#)
        #expect(m == RemoteTouchMessage(pointerId: 7, phase: .down, point: NormPoint(x: 0.49, y: 0.75), time: 1234.5))
        #expect(m.isDown)
    }

    @Test(arguments: [("down", true), ("move", true), ("up", false), ("cancel", false)])
    func isDownFollowsPhase(type: String, expected: Bool) throws {
        let m = try touch(#"{"t": 1, "id": 0, "type": "\#(type)", "x": 0.5, "y": 0.5}"#)
        #expect(m.phase.rawValue == type)
        #expect(expected ? m.isDown : !m.isDown)
    }

    @Test func pingIsRecognisedWithOrWithoutTime() throws {
        let actual25 = try RemoteTouchMessageDecoder.decode(#"{"type": "ping", "t": 1234.5}"#).get()
        #expect(actual25 == .ping)
        let actual26 = try RemoteTouchMessageDecoder.decode(#"{"type":"ping"}"#).get()
        #expect(actual26 == .ping)
    }

    @Test func coordinatesAreClampedIntoUnitSquare() throws {
        let m = try touch(#"{"t": 1, "id": 3, "type": "move", "x": 1.2, "y": -0.3}"#)
        #expect(m.point == NormPoint(x: 1, y: 0))
        #expect(m.point.isValid)
    }

    @Test func missingTimeDefaultsToZeroAndExtraFieldsAreIgnored() throws {
        let m = try touch(#"{"id": 2, "type": "up", "x": 0.1, "y": 0.2, "pressure": 0.9}"#)
        #expect(m.time == 0)
        #expect(m.pointerId == 2)
    }

    @Test(arguments: [
        ("nope", RemoteInputDecodeError.notJSON),
        ("[]", RemoteInputDecodeError.notJSON),
        ("", RemoteInputDecodeError.notJSON),
        (#"{"id": 1, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.missingField("type")),
        (#"{"type": 7}"#, RemoteInputDecodeError.missingField("type")),
        (#"{"type": "hover", "id": 1, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.unknownType("hover")),
        (#"{"type": "down", "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.missingField("id")),
        (#"{"type": "down", "id": -1, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.invalidPointerId),
        (#"{"type": "down", "id": 1.5, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.invalidPointerId),
        (#"{"type": "down", "id": "7", "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.invalidPointerId),
        (#"{"type": "down", "id": 1, "y": 0.5}"#, RemoteInputDecodeError.missingField("x")),
        (#"{"type": "down", "id": 1, "x": 0.5}"#, RemoteInputDecodeError.missingField("y")),
        (#"{"type": "down", "id": 1, "x": "0.5", "y": 0.5}"#, RemoteInputDecodeError.invalidCoordinate),
        (#"{"type": "down", "id": 1, "x": 0.5, "y": null}"#, RemoteInputDecodeError.invalidCoordinate),
    ])
    func invalidMessagesAreRejectedWithReason(text: String, error: RemoteInputDecodeError) {
        switch RemoteTouchMessageDecoder.decode(text) {
        case .success(let message): Issue.record("應拒絕但解出 \(message)")
        case .failure(let actual): #expect(actual == error)
        }
    }

    @Test(arguments: ["true", "false"])
    func booleanFieldsAreNotNumbers(_ boolean: String) {
        let id = RemoteTouchMessageDecoder.decode(
            #"{"type":"down","id":\#(boolean),"x":0.5,"y":0.5}"#)
        #expect(id == .failure(.invalidPointerId))
        let x = RemoteTouchMessageDecoder.decode(
            #"{"type":"down","id":1,"x":\#(boolean),"y":0.5}"#)
        #expect(x == .failure(.invalidCoordinate))
        let y = RemoteTouchMessageDecoder.decode(
            #"{"type":"down","id":1,"x":0.5,"y":\#(boolean)}"#)
        #expect(y == .failure(.invalidCoordinate))
    }

    @Test func pointerIdUpperBoundIsCheckedBeforeIntegerConversion() throws {
        let maximum = try touch(#"{"type":"down","id":2147483647,"x":0,"y":1}"#)
        #expect(maximum.pointerId == Int(Int32.max))
        let overflow = RemoteTouchMessageDecoder.decode(
            #"{"type":"down","id":2147483648,"x":0,"y":1}"#)
        #expect(overflow == .failure(.invalidPointerId))
    }

    @Test func booleanTimeDefaultsToZero() throws {
        let message = try touch(#"{"type":"down","id":1,"x":0,"y":1,"t":true}"#)
        #expect(message.time == 0)
    }

    @Test(arguments: ["GoBack", "GoHome", "AppSwitch"])
    func navigationKeysDecode(_ key: String) throws {
        let decoded = try RemoteTouchMessageDecoder.decode(
            #"{"type":"key","key":"\#(key)","t":1234.5}"#).get()
        #expect(decoded == .key(.key(key), time: 1234.5))
    }

    @Test(arguments: [
        (#"{"type":"key","key":"gohome","t":1}"#, RemoteInputDecodeError.invalidKey),
        (#"{"type":"key","key":"Goback","t":1}"#, RemoteInputDecodeError.invalidKey),
        (#"{"type":"key","key":"appSwitch","t":1}"#, RemoteInputDecodeError.invalidKey),
        (#"{"type":"key","key":"Power","t":1}"#, RemoteInputDecodeError.invalidKey),
        (#"{"type":"key","key":7,"t":1}"#, RemoteInputDecodeError.invalidKey),
        (#"{"type":"key","key":null,"t":1}"#, RemoteInputDecodeError.invalidKey),
        (#"{"type":"key","t":1}"#, RemoteInputDecodeError.missingField("key")),
        (#"{"type":"key","key":"GoHome"}"#, RemoteInputDecodeError.missingField("t")),
        (#"{"type":"key","key":"GoHome","t":true}"#, RemoteInputDecodeError.invalidTime),
        (#"{"type":"key","key":"GoHome","t":"1"}"#, RemoteInputDecodeError.invalidTime),
        (#"{"type":"key","key":"GoHome","t":null}"#, RemoteInputDecodeError.invalidTime),
    ])
    func invalidNavigationKeysAreRejected(text: String, error: RemoteInputDecodeError) {
        #expect(RemoteTouchMessageDecoder.decode(text) == .failure(error))
    }

    @Test func backspaceAllowsTheCompactKeyMessage() throws {
        let message = try RemoteTouchMessageDecoder.decode(#"{"type":"key","key":"Backspace"}"#).get()
        #expect(message == .key(.key("Backspace"), time: 0))
    }

    @Test(arguments: ["hello", "中文🙂é", " ", String(repeating: "a", count: 4096), String(repeating: "🙂", count: 2048)])
    func textPreservesUnicodeAndBoundary(_ text: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "text", "text": text, "t": 12.5])
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try RemoteTouchMessageDecoder.decode(json).get()
        #expect(decoded == .text(text, time: 12.5))
    }

    @Test(arguments: [
        (#"{"type":"text","t":1}"#, RemoteInputDecodeError.missingField("text")),
        (#"{"type":"text","text":"","t":1}"#, RemoteInputDecodeError.invalidText),
        (#"{"type":"text","text":true,"t":1}"#, RemoteInputDecodeError.invalidText),
        (#"{"type":"text","text":null,"t":1}"#, RemoteInputDecodeError.invalidText),
        (#"{"type":"text","text":"hi"}"#, RemoteInputDecodeError.missingField("t")),
        (#"{"type":"text","text":"hi","t":true}"#, RemoteInputDecodeError.invalidTime),
    ])
    func invalidTextIsRejected(json: String, error: RemoteInputDecodeError) {
        #expect(RemoteTouchMessageDecoder.decode(json) == .failure(error))
    }

    @Test(arguments: [String(repeating: "a", count: 4097), String(repeating: "🙂", count: 2049)])
    func oversizedTextIsRejected(_ text: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "text", "text": text, "t": 1])
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(RemoteTouchMessageDecoder.decode(json) == .failure(.invalidText))
    }

}
