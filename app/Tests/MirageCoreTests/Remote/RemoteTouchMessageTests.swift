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
        (#"{"type": "down", "id": -2147483649, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.invalidPointerId),
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

    @Test(arguments: [-10102172, 1807384342, Int(Int32.min), Int(Int32.max)])
    func signedPointerIdsDecode(_ id: Int) throws {
        let message = try touch(#"{"type":"down","id":\#(id),"x":0,"y":1}"#)
        #expect(message.pointerId == id)
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

    @Test func batchDecodesClampsAndAllocatesAtomically() throws {
        let decoded = try RemoteTouchMessageDecoder.decode(#"{"type":"touches","t":12,"points":[{"id":-7,"phase":"down","x":-1,"y":2},{"id":8,"phase":"down","x":0.8,"y":0.5}]}"#).get()
        guard case .touches(let messages) = decoded else { throw RemoteInputDecodeError.invalidPoints }
        #expect(messages.count == 2)
        #expect(messages[0].point == NormPoint(x: 0, y: 1))
        #expect(messages[0].time == 12)
        let allocator = RemoteTouchIdentifierAllocator()
        let batch = try allocator.applyBatch(messages).get()
        #expect(batch.specs.map(\.identifier) == [64, 65])
        let bad = RemoteTouchMessage(pointerId: 99, phase: .move, point: .clamped(x: 0.5, y: 0.5), time: 12)
        if case .failure(let reason) = allocator.applyBatch([messages[0], bad]) {
            #expect(reason == .unknownPointer)
        } else { Issue.record("部分失敗批次不可成功") }
        #expect(allocator.active.isEmpty)
        let retry = try allocator.applyBatch([messages[1]]).get()
        #expect(retry.specs[0].identifier == 64)
    }

    @Test(arguments: [
        #"{"type":"touches","t":1,"points":[]}"#,
        #"{"type":"touches","t":true,"points":[{"id":1,"phase":"down","x":0,"y":0}]}"#,
        #"{"type":"touches","t":1,"points":[{"id":1,"phase":"down","x":0,"y":0},{"id":2,"phase":"move","x":true,"y":0}]}"#,
        #"{"type":"touches","t":1,"points":[{"id":1,"phase":"down","x":0,"y":0},{"id":1,"phase":"up","x":0,"y":0}]}"#
    ])
    func invalidBatchIsRejected(_ json: String) {
        if case .success = RemoteTouchMessageDecoder.decode(json) { Issue.record("整批必須拒絕") }
    }

    @Test func batchLimitAndExplicitSingleTouchCompatibility() throws {
        let explicit = try touch(#"{"type":"touch","phase":"cancel","id":-7,"x":0.5,"y":0.5}"#)
        #expect(explicit.phase == .cancel)
        #expect(!explicit.isDown)
        let points: [[String: Any]] = (0..<11).map { ["id": $0, "phase": "down", "x": 0.5, "y": 0.5] }
        let data = try JSONSerialization.data(withJSONObject: ["type": "touches", "t": 1, "points": points])
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(RemoteTouchMessageDecoder.decode(json) == .failure(.invalidPoints))
        let down = RemoteTouchMessage(pointerId: 1, phase: .down, point: .clamped(x: 0.2, y: 0.3), time: 1)
        let pressed = try RemoteTouchIdentifierAllocator().applyBatch([down]).get()
        let move = RemoteTouchMessage(pointerId: 1, phase: .move, point: .clamped(x: 0.8, y: 0.9), time: 2)
        let moved = try pressed.allocator.applyBatch([move]).get()
        #expect(moved.specs[0].isRemoteMove)
        #expect(!pressed.specs[0].isRemoteMove)
        let released = moved.allocator.releaseAll()
        #expect(released.released[0].point == move.point)
        #expect(!released.released[0].down)
    }


    /// 手機端要能自己解除文字暫停，否則唯一的恢復入口在 Mac 鏡像視窗左下角，
    /// 而遙控的正常用法就是那個視窗關著。
    @Test func textResumeIsAcceptedWithoutFields() {
        #expect(RemoteTouchMessageDecoder.decode(#"{"type":"textResume"}"#) == .success(.textResume))
    }

    @Test(arguments: [("textresume", "textresume"), ("TextResume", "TextResume")])
    func textResumeTypeIsExact(_ type: String, _ reported: String) {
        let json = #"{"type":"\#(type)"}"#
        #expect(RemoteTouchMessageDecoder.decode(json) == .failure(.unknownType(reported)))
    }
}
