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

    /// 多指觸控注入。`TouchSpec.point` 已經是正規化座標，換算用的尺寸由本 actor 從健康
    /// 探測取得的 guest 實體解析度提供——**不再由呼叫端傳入**。
    ///
    /// 原本的簽章是 `sendTouches(_:width:height:)`，而唯一的呼叫端（KeymapController）
    /// 傳的是串流幀尺寸，不是 guest 實體解析度。兩者在本機相差兩倍，所以 P1-c 起所有
    /// 鍵位映射的觸點都落在目標的左上一半處。拿掉這兩個參數之後，呼叫端沒有機會再傳錯
    /// （見 §10 的調查記錄）。`guestDisplay` 未知時靜默不送，理由同 `sendTap`。
    public func sendTouches(_ touches: [TouchSpec]) async {
        guard let client = channelBox?.client, let display = guestDisplay else { return }
        _ = try? await client.sendTouch(
            Self.buildTouchEvent(touches, width: display.w, height: display.h))
    }

    public func sendKey(_ code: KeyCode, down: Bool) async {
        guard let client = channelBox?.client, let ev = Self.buildKeyEvent(code, down: down) else { return }
        _ = try? await client.sendKey(ev)
    }
}
