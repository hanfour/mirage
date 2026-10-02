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
        #expect(e.handles(KeyCode.key("w")))      // joystick
        #expect(e.handles(KeyCode.key("d")))
        #expect(e.handles(KeyCode.key("j")))      // tap
        #expect(!e.handles(KeyCode.key("k")))     // 沒綁 → 直通
        #expect(!e.handles(KeyCode.key("Enter")))
        #expect(!e.handles(KeyCode.mouse(.left)))
    }

    @Test func tapDownProducesTouchThenUp() throws {
        let e = engine()
        let down = e.apply(.keyDown(.key("j")))
        let tap = down.touches.first { $0.identifier == 2 }
        #expect(try #require(tap).down)
        #expect(tap?.point == NormPoint(x: 0.85, y: 0.8))
        let up = e.apply(.keyUp(.key("j")))
        #expect(try !#require(up.touches.first { $0.identifier == 2 }).down)
    }

    @Test func gamepadTapAndKeyboardShareOneTouchUntilBothAreReleased() throws {
        let e = KeymapEngine(profile: KeymapProfile(gameId: "g", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 0.6, y: 0.7), gamepad: .a),
        ]))
        let keyboardDown = e.apply(.keyDown(.key("j")))
        let gamepadDown = e.applyGamepad(.buttonDown(.a))
        let keyboardUp = e.apply(.keyUp(.key("j")))
        #expect(try #require(keyboardDown.touches.first).down)
        #expect(try #require(gamepadDown.touches.first).down)
        #expect(try #require(keyboardUp.touches.first).down)
        #expect(keyboardUp.touches.count == 1)
        let released = e.applyGamepad(.buttonUp(.a))
        let gamepadTouchIsUp = try !#require(released.touches.first).down
        #expect(gamepadTouchIsUp)
    }

    @Test func leftStickUsesHalfRadiusAndFlipsScreenY() throws {
        let e = engine()
        let halfRight = e.applyGamepad(.leftStickChanged(GamepadVector(x: 0.5, y: 0)))
        let rightTouch = try #require(halfRight.touches.first { $0.identifier == 1 })
        #expect(rightTouch.down)
        #expect(abs(rightTouch.point.x - 0.25) < 1e-9)
        #expect(abs(rightTouch.point.y - 0.75) < 1e-9)

        let halfUp = e.applyGamepad(.leftStickChanged(GamepadVector(x: 0, y: 0.5)))
        let upTouch = try #require(halfUp.touches.first { $0.identifier == 1 })
        #expect(abs(upTouch.point.y - 0.70) < 1e-9)
        #expect(upTouch.down)
    }

    @Test func leftStickDeadZoneReleasesThenRestoresKeyboardWASD() throws {
        let e = engine()
        _ = e.apply(.keyDown(.key("d")))
        let stickOverridesKeyboard = e.applyGamepad(.leftStickChanged(GamepadVector(x: -0.5, y: 0)))
        let overridden = try #require(stickOverridesKeyboard.touches.first { $0.identifier == 1 })
        #expect(abs(overridden.point.x - 0.15) < 1e-9)

        let deadZone = e.applyGamepad(.leftStickChanged(GamepadVector(x: 0.1, y: 0)))
        let restored = try #require(deadZone.touches.first { $0.identifier == 1 })
        #expect(restored.down)
        #expect(abs(restored.point.x - 0.3) < 1e-9)

        _ = e.apply(.keyUp(.key("d")))
        let released = e.applyGamepad(.leftStickChanged(.zero))
        let stickTouchIsUp = try !#require(released.touches.first { $0.identifier == 1 }).down
        #expect(stickTouchIsUp)
    }

    @Test func rightStickUsesInjectedTimeAndIgnoresLookActivation() throws {
        let e = KeymapEngine(profile: KeymapProfile(gameId: "g", version: 1, bindings: [
            .look(activation: .key("Shift"), sensitivity: 1.5),
        ]))
        let started = e.applyGamepad(.rightStickChanged(GamepadVector(x: 0.5, y: 0.5)))
        #expect(try #require(started.touches.first).down)
        let moved = try #require(e.gamepadLookTick(dt: 0.5))
        let touch = try #require(moved.touches.first)
        #expect(touch.down)
        // 0.5 偏移 × 半個畫面/秒 × sensitivity 1.5 × 0.5 秒 = 0.1875
        #expect(abs(touch.point.x - 0.6875) < 1e-9)
        #expect(abs(touch.point.y - 0.3125) < 1e-9)

        let released = e.applyGamepad(.rightStickChanged(.zero))
        let lookTouchIsUp = try !#require(released.touches.first).down
        #expect(lookTouchIsUp)
    }

    /// 滿偏在 sensitivity 1.0 時是半個畫面/秒，並隨編輯器的靈敏度滑桿線性變化。
    @Test func rightStickSpeedScalesWithLookSensitivity() throws {
        func movedX(sensitivity: Double) throws -> Double {
            let e = KeymapEngine(profile: KeymapProfile(gameId: "g", version: 1, bindings: [
                .look(activation: nil, sensitivity: sensitivity),
            ]))
            _ = e.applyGamepad(.rightStickChanged(GamepadVector(x: 1, y: 0)))
            let moved = try #require(e.gamepadLookTick(dt: 0.25))
            return try #require(moved.touches.first).point.x
        }
        #expect(abs(try movedX(sensitivity: 1) - 0.625) < 1e-9)
        #expect(abs(try movedX(sensitivity: 2) - 0.75) < 1e-9)
    }

    @Test func releaseAllLiftsGamepadTapAndBothStickTouches() throws {
        let e = KeymapEngine(profile: KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.1),
            .tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8), gamepad: .a),
            .look(activation: nil, sensitivity: 1.5),
        ]))
        _ = e.applyGamepad(.buttonDown(.a))
        _ = e.applyGamepad(.leftStickChanged(GamepadVector(x: 0.5, y: 0)))
        let active = e.applyGamepad(.rightStickChanged(GamepadVector(x: 0, y: 0.5)))
        let activeCount = active.touches.filter(\.down).count
        #expect(activeCount == 3)

        let released = e.releaseAll()
        let allReleased = released.touches.allSatisfy { !$0.down }
        #expect(allReleased)
    }

    @Test func joystickRightMovesTouchFromCenter() throws {
        let e = engine()
        let f = e.apply(.keyDown(.key("d")))          // 向右
        let js = f.touches.first { $0.identifier == 1 }
        #expect(try #require(js).down)
        #expect(js!.point.x > 0.2)                    // center.x=0.2，向右 → x 增
        #expect(abs(js!.point.y - 0.75) < 1e-9)       // 純水平
    }

    @Test func joystickReleaseLiftsTouch() throws {
        let e = engine()
        _ = e.apply(.keyDown(.key("d")))
        let f = e.apply(.keyUp(.key("d")))
        #expect(try !#require(f.touches.first { $0.identifier == 1 }).down)
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

    @Test func lookAccumulatesMouseMove() throws {
        let e = engine()
        let f = e.apply(.mouseMove(dx: 10, dy: 0))    // always-on look
        let look = f.touches.first { $0.identifier == 3 }
        #expect(try #require(look).down)
        #expect(look!.point.x != 0.5 || look!.point.y != 0.5)  // 自中心位移
    }

    /// D20：原本這條驗的是 `unmappedCount` 有沒有加一，而那個計數沒有任何消費端。
    /// 改成驗真正的產品行為：沒綁到的鍵不可以產生任何觸控，否則會在 guest 上多戳一下。
    @Test func unmappedKeyLeavesTouchStateUntouched() throws {
        let e = engine()
        let before = e.apply(.keyDown(.key("w")))     // 有綁：joystick 推到上緣
        let beforeStick = try #require(before.touches.first { $0.identifier == 1 })
        let frame = e.apply(.keyDown(.key("z")))      // 沒綁
        let afterStick = try #require(frame.touches.first { $0.identifier == 1 })
        // **比位置不是比數量**：搖桿無論如何都會出一個觸控，所以「數量不變」沒有鑑別力
        // ——實測突變（未綁鍵清掉 pressed）在只比數量時抓不到。
        #expect(afterStick.point.x == beforeStick.point.x)
        #expect(afterStick.point.y == beforeStick.point.y)
        #expect(afterStick.down == beforeStick.down)
        #expect(frame.touches.count == before.touches.count)
    }

    @Test func gatedLookLiftsTouchWhenActivationKeyReleased() throws {
        // Task 4 補審：activation-gated look 的 releaseLookIfGateClosed 迴歸測試。
        // 唯一 binding → look 為 id 1。
        let e = KeymapEngine(profile: KeymapProfile(gameId: "g", version: 1, bindings: [
            .look(activation: .key("Shift"), sensitivity: 1.0),   // id 1
        ]))

        // 1) gate 關閉：未按啟動鍵時 mouseMove 應被忽略。
        let closed = e.apply(.mouseMove(dx: 10, dy: 0))
        #expect(try !#require(closed.touches.first { $0.identifier == 1 }).down)

        // 2) gate 開啟：按住啟動鍵後 mouseMove 生效。
        _ = e.apply(.keyDown(.key("Shift")))
        let open = e.apply(.mouseMove(dx: 10, dy: 0))
        #expect(try #require(open.touches.first { $0.identifier == 1 }).down)

        // 3) 放開啟動鍵：gate 因此關閉，look 觸點應被收回（down=false）。
        let released = e.apply(.keyUp(.key("Shift")))
        #expect(try !#require(released.touches.first { $0.identifier == 1 }).down)
    }

    /// D12：搖桿圓心貼邊時，`center ± radius` 會算出越界座標。
    ///
    /// 送越界座標比不送更糟——畫面有反應但點在錯的地方，使用者會以為是遊戲的問題
    /// （D7 已確立這個立場）。
    @Test func joystickAtEdgeStaysInsideUnitSquare() throws {
        let profile = KeymapProfile(gameId: "g", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.05, y: 0.95), radius: 0.3),
        ])
        let engine = KeymapEngine(profile: profile)
        let frame = engine.apply(.keyDown(.key("a")))       // 向左：x = 0.05 - 0.3 = -0.25
        let stick = frame.touches.first { $0.identifier == 1 }
        #expect(stick?.point.x == 0)
        #expect(try #require(stick).point.isValid)

        let down = engine.apply(.keyDown(.key("s")))        // 再加向下：y 會超過 1
        let stick2 = down.touches.first { $0.identifier == 1 }
        #expect(try #require(stick2).point.isValid)
    }
}
