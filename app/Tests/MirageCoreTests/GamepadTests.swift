import Testing
@testable import MirageCore

@Suite struct GamepadTests {
    @Test func snapshotDifferReportsButtonEdgesTriggersAndStickChanges() {
        var differ = GamepadSnapshotDiffer()
        let initial = differ.update(GamepadSnapshot(
            buttons: [.a], leftStick: GamepadVector(x: 0.2, y: -0.4), leftTrigger: 0.5
        ))
        #expect(initial == [
            .buttonDown(.a),
            .leftStickChanged(GamepadVector(x: 0.2, y: -0.4)),
        ])

        let triggerDown = differ.update(GamepadSnapshot(
            buttons: [.a], leftStick: GamepadVector(x: 0.2, y: -0.4), leftTrigger: 0.51
        ))
        #expect(triggerDown == [.buttonDown(.leftTrigger)])
        #expect(differ.update(GamepadSnapshot(
            buttons: [.a], leftStick: GamepadVector(x: 0.2, y: -0.4), leftTrigger: 0.7
        )).isEmpty)

        let released = differ.update(.neutral)
        #expect(released.contains(.buttonUp(.a)))
        #expect(released.contains(.buttonUp(.leftTrigger)))
        #expect(released.contains(.leftStickChanged(.zero)))
    }

    @Test func fallbackMapsSystemButtonsToAndroidKeys() {
        var machine = GamepadFallbackMachine()
        #expect(machine.apply(.buttonDown(.b)) == [.androidKey("GoBack")])
        #expect(machine.apply(.buttonDown(.menu)) == [.androidKey("GoHome")])
        #expect(machine.apply(.buttonDown(.options)) == [.androidKey("AppSwitch")])
        #expect(machine.apply(.buttonDown(.a)).isEmpty)
    }

    @Test func dpadAndLeftStickHoldOneCenterDragUntilReleased() {
        var machine = GamepadFallbackMachine()
        let center = NormPoint(x: 0.5, y: 0.5)
        #expect(machine.apply(.buttonDown(.dpadDown)) == [.touchDown(center)])
        let dpadMove = machine.tick(dt: 1.0 / 6.0)
        guard case .touchMove(let dpadPoint) = dpadMove.first else {
            Issue.record("十字鍵按住時應持續移動觸點")
            return
        }
        #expect(abs(dpadPoint.y - 0.6) < 1e-9)
        #expect(machine.apply(.buttonUp(.dpadDown)) == [.touchUp(dpadPoint)])

        #expect(machine.apply(.leftStickChanged(GamepadVector(x: 0, y: 0.5))) == [.touchDown(center)])
        let stickMove = machine.tick(dt: 1.0 / 6.0)
        guard case .touchMove(let stickPoint) = stickMove.first else {
            Issue.record("左搖桿按住時應持續移動觸點")
            return
        }
        #expect(abs(stickPoint.y - 0.45) < 1e-9)
        #expect(machine.apply(.leftStickChanged(.zero)) == [.touchUp(stickPoint)])
    }

    @Test func cancelReleasesHeldScrollAtItsLastPoint() throws {
        var machine = GamepadFallbackMachine()
        _ = machine.apply(.buttonDown(.dpadUp))
        let movement = machine.tick(dt: 0.2)
        guard case .touchMove(let point) = movement.first else {
            Issue.record("捲動中應有移動觸點")
            return
        }

        #expect(machine.cancel() == [.touchUp(point)])
        #expect(machine.cancel().isEmpty)
    }
}
