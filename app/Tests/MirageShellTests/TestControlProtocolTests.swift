import Foundation
import Testing
@testable import MirageShell

@Suite struct TestControlProtocolTests {
    @Test func decodesPointAndNormalizedMouseRequests() throws {
        let pointCommand = try TestControlProtocol.decode(Data(#"{"cmd":"mouse","action":"click","x":24,"y":48}"#.utf8))
        let normalizedCommand = try TestControlProtocol.decode(Data(#"{"cmd":"mouse","action":"down","x":0.5,"y":0.25,"unit":"norm"}"#.utf8))

        guard case .mouse(let action, let point, let unit) = pointCommand else {
            Issue.record("pt mouse request 沒有解析成 mouse")
            return
        }
        #expect(action == .click)
        #expect(point == TestControlPoint(x: 24, y: 48))
        #expect(unit == .points)

        guard case .mouse(let normalizedAction, let normalizedPoint, let normalizedUnit) = normalizedCommand else {
            Issue.record("norm mouse request 沒有解析成 mouse")
            return
        }
        #expect(normalizedAction == .down)
        #expect(normalizedPoint == TestControlPoint(x: 0.5, y: 0.25))
        #expect(normalizedUnit == .normalized)
    }

    @Test func convertsBothCoordinateUnitsAndRejectsOutOfBounds() throws {
        let points = try TestControlProtocol.point(
            TestControlPoint(x: 24, y: 48), unit: .points, width: 100, height: 80)
        let normalized = try TestControlProtocol.point(
            TestControlPoint(x: 0.5, y: 0.25), unit: .normalized, width: 100, height: 80)

        #expect(points == TestControlPoint(x: 24, y: 48))
        #expect(normalized == TestControlPoint(x: 50, y: 20))
        #expect(throws: TestControlProtocolError.self) {
            try TestControlProtocol.point(
                TestControlPoint(x: 1.1, y: 0.5), unit: .normalized, width: 100, height: 80)
        }
        #expect(throws: TestControlProtocolError.self) {
            try TestControlProtocol.point(
                TestControlPoint(x: 101, y: 20), unit: .points, width: 100, height: 80)
        }
    }

    @Test func rejectsMissingFieldsInvalidValuesAndUnknownCommands() throws {
        let requests = [
            #"{"cmd":"mouse","action":"click","x":1}"#,
            #"{"cmd":"scroll","x":0.5,"y":0.5,"dx":0,"dy":-1,"steps":0,"interval_ms":10,"unit":"norm"}"#,
            #"{"cmd":"key","keyCode":200,"action":"press"}"#,
            #"{"cmd":"fullscreen","on":"yes"}"#,
            #"{"cmd":"unknown"}"#,
        ]
        for request in requests {
            let rejected = (try? TestControlProtocol.decode(Data(request.utf8))) == nil
            #expect(rejected)
        }

        let unknown = Data(#"{"cmd":"unknown"}"#.utf8)
        let response: Data
        do {
            _ = try TestControlProtocol.decode(unknown)
            response = TestControlProtocol.failureResponse("請求不應該通過")
        } catch {
            response = TestControlProtocol.failureResponse(for: error)
        }
        let responseObject = try #require(try JSONSerialization.jsonObject(with: response) as? [String: Any])
        // 先算成 Bool 再斷言：#expect 展開 `!(x as? Bool ?? true)` 時會把中間值算錯（實測 ok=false 仍判失敗）。
        let succeeded = (responseObject["ok"] as? Bool) ?? true
        let mentionsUnknown = (responseObject["error"] as? String)?.contains("未知的 cmd") ?? false
        #expect(!succeeded)
        #expect(mentionsUnknown)
    }
}
