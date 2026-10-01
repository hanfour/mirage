import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct TouchpadDragTests {
    private func sample(
        _ phase: TouchpadScrollPhase,
        location: (x: Double, y: Double) = (50, 100),
        delta: (x: Double, y: Double) = (0, 0),
        precise: Bool = true,
        hasPhase: Bool = true,
        momentum: Bool = false,
        enabled: Bool = true,
        leftMouseDown: Bool = false,
        size: (width: Double, height: Double) = (100, 200)
    ) -> TouchpadScrollSample {
        TouchpadScrollSample(phase: phase, hasPreciseDeltas: precise, hasPhase: hasPhase,
                             hasMomentum: momentum, isEnabled: enabled,
                             leftMouseDown: leftMouseDown, location: location,
                             delta: delta, size: size)
    }

    @Test func beganChangedAndEndedFormOneFingerDrag() {
        var machine = TouchpadDragMachine()

        #expect(machine.handle(sample(.began)) == [.down(NormPoint(x: 0.5, y: 0.5))])
        #expect(machine.handle(sample(.changed, delta: (10, -20))) == [.move(NormPoint(x: 0.6, y: 0.4))])
        #expect(machine.handle(sample(.ended)) == [.up(NormPoint(x: 0.6, y: 0.4))])
        #expect(!machine.isDragging)
    }

    @Test func positiveVerticalDeltaMovesGuestTouchDown() {
        var machine = TouchpadDragMachine()
        _ = machine.handle(sample(.began))

        #expect(machine.handle(sample(.changed, delta: (0, 20))) == [.move(NormPoint(x: 0.5, y: 0.6))])
    }

    @Test func momentumDoesNotMoveFingerAndReleasePhaseStillEndsIt() {
        var machine = TouchpadDragMachine()
        _ = machine.handle(sample(.began))

        #expect(machine.handle(sample(.changed, delta: (20, 20), momentum: true)).isEmpty)
        #expect(machine.currentPoint == NormPoint(x: 0.5, y: 0.5))
        #expect(machine.handle(sample(.ended, momentum: true)) == [.up(NormPoint(x: 0.5, y: 0.5))])
    }

    @Test func movementClampsAtScreenEdges() {
        var machine = TouchpadDragMachine()
        _ = machine.handle(sample(.began, location: (98, 2)))

        #expect(machine.handle(sample(.changed, delta: (20, 40))) == [.move(NormPoint(x: 1, y: 1))])
        #expect(machine.handle(sample(.changed, delta: (-20, -40))) == [.move(NormPoint(x: 0.8, y: 0.8))])
    }

    @Test func leftMousePressPreventsOrReleasesTrackpadDrag() {
        var machine = TouchpadDragMachine()

        #expect(machine.handle(sample(.began, leftMouseDown: true)).isEmpty)
        _ = machine.handle(sample(.began))
        #expect(machine.handle(sample(.changed, delta: (10, 0), leftMouseDown: true)) == [.up(NormPoint(x: 0.5, y: 0.5))])
        #expect(!machine.isDragging)
    }

    @Test func losingFocusReleasesAtLastPoint() {
        var machine = TouchpadDragMachine()
        _ = machine.handle(sample(.began))
        _ = machine.handle(sample(.changed, delta: (10, 0)))

        #expect(machine.cancel() == [.up(NormPoint(x: 0.6, y: 0.5))])
        #expect(machine.cancel().isEmpty)
    }

    @Test func becomingIneligibleReleasesActiveDrag() {
        var machine = TouchpadDragMachine()
        _ = machine.handle(sample(.began))

        #expect(machine.handle(sample(.changed, delta: (10, 0), enabled: false)) == [.up(NormPoint(x: 0.5, y: 0.5))])
        #expect(!machine.isDragging)
    }

    @Test func ignoresWheelEventsWithoutPreciseDeltasOrPhase() {
        var machine = TouchpadDragMachine()

        #expect(machine.handle(sample(.began, precise: false)).isEmpty)
        #expect(machine.handle(sample(.began, hasPhase: false)).isEmpty)
        #expect(!machine.isDragging)
    }
}
