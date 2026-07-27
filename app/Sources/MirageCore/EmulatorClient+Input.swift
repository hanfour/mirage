import GRPC
import SwiftProtobuf

// MARK: - 多指觸控 / 鍵盤注入（Task 6：消費 Task 4 TouchSpec、Task 1 KeyCode）
//
// 從 EmulatorClient.swift 搬出（Task 6 審查 Important 2：本體因新增 makeDisplayTransport()
// 超過 400 行上限）。純檔案位移，行為零改變。

extension EmulatorClient {
    /// 純建構——供單元測試，不需 channel。
    static func buildTouchEvent(_ touches: [TouchSpec], width: Int, height: Int)
        -> Android_Emulation_Control_TouchEvent
    {
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = touches.map { spec in
            let (gx, gy) = spec.point.guestPixel(width: width, height: height)
            var t = Android_Emulation_Control_Touch()
            t.x = Int32(gx); t.y = Int32(gy)
            t.identifier = Int32(spec.identifier)
            t.pressure = spec.down ? 1024 : 0
            return t
        }
        return event
    }

    /// 純建構——`.mouse` 無對應 KeyboardEvent，回 nil（呼叫端忽略）。
    static func buildKeyEvent(_ code: KeyCode, down: Bool)
        -> Android_Emulation_Control_KeyboardEvent?
    {
        guard case .key(let w3c) = code else { return nil }
        var ev = Android_Emulation_Control_KeyboardEvent()
        ev.eventType = down ? .keydown : .keyup
        ev.key = w3c
        return ev
    }

    public func sendTouches(_ touches: [TouchSpec], width: Int, height: Int) async {
        guard let client = channelBox?.client else { return }
        _ = try? await client.sendTouch(Self.buildTouchEvent(touches, width: width, height: height))
    }

    public func sendKey(_ code: KeyCode, down: Bool) async {
        guard let client = channelBox?.client, let ev = Self.buildKeyEvent(code, down: down) else { return }
        _ = try? await client.sendKey(ev)
    }
}
