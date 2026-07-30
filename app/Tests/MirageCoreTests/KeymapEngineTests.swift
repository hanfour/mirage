import Testing
@testable import MirageCore

@Suite struct KeymapEngineTests {
    private func engine() -> KeymapEngine {
        KeymapEngine(profile: KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.1),   // id 1
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),         // id 2
            .look(activation: nil, sensitivity: 1.0),                     // id 3
        ]))
    }

    /// 分流的判定式：綁到的鍵走觸控，沒綁到的由呼叫端直通給 guest 鍵盤（D2）。
    /// 測試用的 profile 綁了 w/a/s/d（joystick）與 j（tap），look 的 activation 是 nil。
    @Test func handlesReportsBoundKeysOnly() {
        let e = engine()
        #expect(e.handles(KeyCode.key("w")) == true)      // joystick
        #expect(e.handles(KeyCode.key("d")) == true)
        #expect(e.handles(KeyCode.key("j")) == true)      // tap
        #expect(e.handles(KeyCode.key("k")) == false)     // 沒綁 → 直通
        #expect(e.handles(KeyCode.key("Enter")) == false)
        #expect(e.handles(KeyCode.mouse(.left)) == false)
    }

    @Test func tapDownProducesTouchThenUp() {
        let e = engine()
        let down = e.apply(.keyDown(.key("j")))
        let tap = down.touches.first { $0.identifier == 2 }
        #expect(tap?.down == true)
        #expect(tap?.point == NormPoint(x: 0.85, y: 0.8))
        let up = e.apply(.keyUp(.key("j")))
        #expect(up.touches.first { $0.identifier == 2 }?.down == false)
    }

    @Test func joystickRightMovesTouchFromCenter() {
        let e = engine()
        let f = e.apply(.keyDown(.key("d")))          // 向右
        let js = f.touches.first { $0.identifier == 1 }
        #expect(js?.down == true)
        #expect(js!.point.x > 0.2)                    // center.x=0.2，向右 → x 增
        #expect(abs(js!.point.y - 0.75) < 1e-9)       // 純水平
    }

    @Test func joystickReleaseLiftsTouch() {
        let e = engine()
        _ = e.apply(.keyDown(.key("d")))
        let f = e.apply(.keyUp(.key("d")))
        #expect(f.touches.first { $0.identifier == 1 }?.down == false)
    }

    @Test func simultaneousJoystickAndTapAreTwoStableTouches() {
        // spec §7 驗收 2：按住 W + 點技能鍵 → TouchFrame 含 joystick(id1) 與 tap(id2) 兩觸點
        let e = engine()
        _ = e.apply(.keyDown(.key("w")))              // joystick 上
        let f = e.apply(.keyDown(.key("j")))          // 同時點技能
        let ids = Set(f.touches.filter { $0.down }.map { $0.identifier })
        #expect(ids.contains(1))
        #expect(ids.contains(2))
        #expect(ids.count == 2)                       // 兩觸點且 identifier 不衝突
    }

    @Test func lookAccumulatesMouseMove() {
        let e = engine()
        let f = e.apply(.mouseMove(dx: 10, dy: 0))    // always-on look
        let look = f.touches.first { $0.identifier == 3 }
        #expect(look?.down == true)
        #expect(look!.point.x != 0.5 || look!.point.y != 0.5)  // 自中心位移
    }

    @Test func unmappedKeyIgnoredAndCounted() {
        let e = engine()
        _ = e.apply(.keyDown(.key("z")))              // 未映射
        #expect(e.unmappedCount == 1)
    }

    @Test func gatedLookLiftsTouchWhenActivationKeyReleased() {
        // Task 4 補審：activation-gated look 的 releaseLookIfGateClosed 迴歸測試。
        // 唯一 binding → look 為 id 1。
        let e = KeymapEngine(profile: KeymapProfile(gameId: "g", version: 1, bindings: [
            .look(activation: .key("Shift"), sensitivity: 1.0),   // id 1
        ]))

        // 1) gate 關閉：未按啟動鍵時 mouseMove 應被忽略。
        let closed = e.apply(.mouseMove(dx: 10, dy: 0))
        #expect(closed.touches.first { $0.identifier == 1 }?.down == false)

        // 2) gate 開啟：按住啟動鍵後 mouseMove 生效。
        _ = e.apply(.keyDown(.key("Shift")))
        let open = e.apply(.mouseMove(dx: 10, dy: 0))
        #expect(open.touches.first { $0.identifier == 1 }?.down == true)

        // 3) 放開啟動鍵：gate 因此關閉，look 觸點應被收回（down=false）。
        let released = e.apply(.keyUp(.key("Shift")))
        #expect(released.touches.first { $0.identifier == 1 }?.down == false)
    }

    /// D12：搖桿圓心貼邊時，`center ± radius` 會算出越界座標。
    ///
    /// 送越界座標比不送更糟——畫面有反應但點在錯的地方，使用者會以為是遊戲的問題
    /// （D7 已確立這個立場）。
    @Test func joystickAtEdgeStaysInsideUnitSquare() {
        let profile = KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.05, y: 0.95), radius: 0.3),
        ])
        let engine = KeymapEngine(profile: profile)
        let frame = engine.apply(.keyDown(.key("a")))       // 向左：x = 0.05 - 0.3 = -0.25
        let stick = frame.touches.first { $0.identifier == 1 }
        #expect(stick?.point.x == 0)
        #expect(stick?.point.isValid == true)

        let down = engine.apply(.keyDown(.key("s")))        // 再加向下：y 會超過 1
        let stick2 = down.touches.first { $0.identifier == 1 }
        #expect(stick2?.point.isValid == true)
    }
}
