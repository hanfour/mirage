import Testing
@testable import MirageShell

private actor ForegroundSequence: ForegroundPackageProviding {
    private var values: [String?]
    init(_ values: [String?]) { self.values = values }
    func dumpsysForegroundPackage(timeout: Duration) async -> String? {
        values.removeFirst()
    }
}

@MainActor
struct GameDetectorTests {
    @Test func overlappingTickIsSkipped() async {
        var changes: [String?] = []
        let detector = GameDetector(adb: ForegroundSequence(["game.a", "game.b"])) { changes.append($0) }
        let first = detector.tick()
        let overlapping = detector.tick()
        #expect(overlapping == nil)
        await first?.value
        #expect(changes == ["game.a"])
        await detector.tick()?.value
        #expect(changes == ["game.a", "game.b"])
    }

    @Test func unchangedDoesNotNotifyAgain() async {
        var changes: [String?] = []
        let detector = GameDetector(adb: ForegroundSequence(["game.a", "game.a", "game.a"])) { changes.append($0) }
        await detector.tick()?.value
        #expect(changes == ["game.a"])
        await detector.tick()?.value
        await detector.tick()?.value
        #expect(changes == ["game.a"])
    }

    @Test func changedPackageNotifiesOnce() async {
        var changes: [String?] = []
        let detector = GameDetector(adb: ForegroundSequence(["game.a", "game.b", "game.b"])) { changes.append($0) }
        await detector.tick()?.value
        await detector.tick()?.value
        await detector.tick()?.value
        #expect(changes == ["game.a", "game.b"])
    }

    @Test func packageBecomesNil() async {
        var changes: [String?] = []
        let detector = GameDetector(adb: ForegroundSequence(["game.a", nil, nil])) { changes.append($0) }
        for _ in 0..<3 { await detector.tick()?.value }
        #expect(changes == ["game.a", nil])
    }

    @Test func initialNilThenPackage() async {
        var changes: [String?] = []
        let detector = GameDetector(adb: ForegroundSequence([nil, nil, "game.a"])) { changes.append($0) }
        await detector.tick()?.value
        #expect(changes == [nil])
        await detector.tick()?.value
        #expect(changes == [nil])
        await detector.tick()?.value
        #expect(changes == [nil, "game.a"])
    }
}
