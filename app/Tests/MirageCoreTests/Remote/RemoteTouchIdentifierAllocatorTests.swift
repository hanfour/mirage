import Testing
@testable import MirageCore

@Suite struct RemoteTouchIdentifierAllocatorTests {
    private func message(_ id: Int, _ phase: RemoteTouchPhase, x: Double = 0.5, y: Double = 0.5) -> RemoteTouchMessage {
        RemoteTouchMessage(pointerId: id, phase: phase, point: NormPoint(x: x, y: y), time: 0)
    }

    @Test func downAllocatesLowestFreeIdentifierAndUpReleasesIt() {
        let (a1, o1) = RemoteTouchIdentifierAllocator().apply(message(7, .down, x: 0.1, y: 0.2))
        #expect(o1 == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.1, y: 0.2), down: true)))
        let (a2, o2) = a1.apply(message(9, .down))
        #expect(o2 == .emit(TouchSpec(identifier: 65, point: NormPoint(x: 0.5, y: 0.5), down: true)))
        let (a3, o3) = a2.apply(message(7, .move, x: 0.3, y: 0.4))
        #expect(o3 == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.3, y: 0.4), down: true)))
        #expect(a3.active[7] == RemoteActiveTouch(identifier: 64, point: NormPoint(x: 0.3, y: 0.4)))
        let (a4, o4) = a3.apply(message(7, .up, x: 0.35, y: 0.45))
        #expect(o4 == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.35, y: 0.45), down: false)))
        #expect(a4.active[7] == nil)
        let (_, o5) = a4.apply(message(11, .down))
        #expect(o5 == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.5, y: 0.5), down: true)))
    }

    @Test(arguments: [RemoteTouchPhase.move, .up, .cancel])
    func unknownPointerIsRejectedAndStateUnchanged(phase: RemoteTouchPhase) {
        let empty = RemoteTouchIdentifierAllocator()
        let (after, outcome) = empty.apply(message(3, phase))
        #expect(outcome == .rejected(.unknownPointer))
        #expect(after == empty)
    }

    @Test func repeatedDownOnActivePointerBehavesLikeMove() {
        let (a1, _) = RemoteTouchIdentifierAllocator().apply(message(1, .down))
        let (a2, outcome) = a1.apply(message(1, .down, x: 0.9, y: 0.9))
        #expect(outcome == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.9, y: 0.9), down: true)))
        #expect(a2.active.count == 1)
    }

    @Test func cancelReleasesLikeUp() {
        let (a1, _) = RemoteTouchIdentifierAllocator().apply(message(5, .down))
        let (a2, outcome) = a1.apply(message(5, .cancel))
        #expect(outcome == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.5, y: 0.5), down: false)))
        #expect(a2.active.isEmpty)
    }

    @Test func eleventhFingerIsRejectedUntilOneLifts() {
        var allocator = RemoteTouchIdentifierAllocator()
        for id in 0..<10 {
            let (next, outcome) = allocator.apply(message(id, .down))
            #expect(outcome == .emit(TouchSpec(identifier: 64 + id, point: NormPoint(x: 0.5, y: 0.5), down: true)))
            allocator = next
        }
        let (unchanged, rejected) = allocator.apply(message(10, .down))
        #expect(rejected == .rejected(.tooManyFingers))
        #expect(unchanged == allocator)
        let (afterUp, _) = allocator.apply(message(4, .up))
        let (_, accepted) = afterUp.apply(message(10, .down))
        #expect(accepted == .emit(TouchSpec(identifier: 68, point: NormPoint(x: 0.5, y: 0.5), down: true)))
    }

    @Test func identifiersStayInsideReservedBandUnderChurn() {
        var allocator = RemoteTouchIdentifierAllocator()
        var seen: Set<Int> = []
        for round in 0..<100 {
            let (down, outcome) = allocator.apply(message(round, .down))
            if case .emit(let spec) = outcome { seen.insert(spec.identifier) }
            let (up, _) = down.apply(message(round, .up))
            allocator = up
        }
        #expect(seen == [64])
        #expect(seen.allSatisfy { RemoteTouchIdentifierAllocator.identifierRange.contains($0) })
        #expect(allocator.active.isEmpty)
    }

    @Test func releaseAllLiftsEveryActiveFingerAtItsLastPointSortedByIdentifier() {
        let (a1, _) = RemoteTouchIdentifierAllocator().apply(message(20, .down, x: 0.2, y: 0.2))
        let (a2, _) = a1.apply(message(30, .down, x: 0.3, y: 0.3))
        let (a3, _) = a2.apply(message(30, .move, x: 0.33, y: 0.33))
        let (after, released) = a3.releaseAll()
        #expect(released == [
            TouchSpec(identifier: 64, point: NormPoint(x: 0.2, y: 0.2), down: false),
            TouchSpec(identifier: 65, point: NormPoint(x: 0.33, y: 0.33), down: false),
        ])
        #expect(after == RemoteTouchIdentifierAllocator())
        #expect(RemoteTouchIdentifierAllocator().releaseAll().released.isEmpty)
    }
}
