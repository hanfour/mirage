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


private actor ForegroundResultSequence: ForegroundPackageProviding {
    private var values: [ForegroundResult]
    init(_ values: [ForegroundResult]) { self.values = values }
    func dumpsysForegroundPackage(timeout: Duration) async -> String? {
        Issue.record("GameDetector 應使用保留逾時狀態的查詢")
        return nil
    }
    func foregroundResult(timeout: Duration) async -> ForegroundResult {
        #expect(timeout == .seconds(2))
        return values.removeFirst()
    }
}

extension GameDetectorTests {
    @Test func thirdTimeoutReschedulesAndSuccessRestoresTimer() async {
        let detector = GameDetector(adb: ForegroundResultSequence([
            .timeout, .timeout, .timeout, .timeout, .success("game.a")
        ])) { _ in }
        detector.start()
        defer { detector.stop() }
        #expect(detector.scheduledPollingInterval == 1.5)
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 1)
        #expect(detector.scheduledPollingInterval == 1.5)
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 2)
        #expect(detector.scheduledPollingInterval == 1.5)
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 3)
        #expect(detector.scheduledPollingInterval == 10)
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 3)
        #expect(detector.scheduledPollingInterval == 10)
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 0)
        #expect(detector.scheduledPollingInterval == 1.5)
    }

    @Test func successfulEmptyForegroundResetsTimeouts() async {
        var changes: [String?] = []
        let detector = GameDetector(adb: ForegroundResultSequence([
            .timeout, .timeout, .timeout, .success(nil), .timeout
        ])) { changes.append($0) }
        for _ in 0..<3 { await detector.tick()?.value }
        #expect(detector.pollingInterval == 10)
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 0)
        #expect(detector.pollingInterval == 1.5)
        #expect(changes == [nil])
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 1)
        #expect(detector.pollingInterval == 1.5)
    }

    @Test func failureBreaksTimeoutStreakBeforeBackoff() async {
        let detector = GameDetector(adb: ForegroundResultSequence([
            .timeout, .timeout, .failure, .timeout, .timeout
        ])) { _ in }
        for _ in 0..<3 { await detector.tick()?.value }
        #expect(detector.consecutiveTimeouts == 0)
        for _ in 0..<2 { await detector.tick()?.value }
        #expect(detector.consecutiveTimeouts == 2)
        #expect(detector.pollingInterval == 1.5)
    }

    @Test func failureDuringBackoffWaitsForSuccess() async {
        let detector = GameDetector(adb: ForegroundResultSequence([
            .timeout, .timeout, .timeout, .failure, .success(nil)
        ])) { _ in }
        for _ in 0..<4 { await detector.tick()?.value }
        #expect(detector.pollingInterval == 10)
        await detector.tick()?.value
        #expect(detector.pollingInterval == 1.5)
    }

    @Test func stopDuringPollDoesNotRestartTimer() async {
        let detector = GameDetector(adb: ForegroundResultSequence([
            .timeout, .timeout, .timeout
        ])) { _ in }
        detector.start()
        await detector.tick()?.value
        await detector.tick()?.value
        let third = detector.tick()
        detector.stop()
        await third?.value
        #expect(detector.consecutiveTimeouts == 3)
        #expect(detector.scheduledPollingInterval == nil)
    }

    @Test func repeatedEmptyForegroundNeverBacksOff() async {
        let detector = GameDetector(adb: ForegroundResultSequence([
            .success(nil), .success(nil), .success(nil), .success(nil)
        ])) { _ in }
        for _ in 0..<4 { await detector.tick()?.value }
        #expect(detector.consecutiveTimeouts == 0)
        #expect(detector.pollingInterval == 1.5)
    }

    @Test func restoresConfiguredInterval() async {
        let detector = GameDetector(adb: ForegroundResultSequence([
            .timeout, .timeout, .timeout, .success("game.a")
        ]), interval: .seconds(4)) { _ in }
        for _ in 0..<3 { await detector.tick()?.value }
        #expect(detector.pollingInterval == 10)
        await detector.tick()?.value
        #expect(detector.pollingInterval == 4)
    }

    @Test func slowerConfiguredIntervalIsNeverShortened() async {
        let detector = GameDetector(adb: ForegroundResultSequence([
            .timeout, .timeout, .timeout
        ]), interval: .seconds(20)) { _ in }
        for _ in 0..<3 { await detector.tick()?.value }
        #expect(detector.consecutiveTimeouts == 3)
        #expect(detector.pollingInterval == 20)
    }

    @Test func successBreaksPartialStreakAndPreservesNotifications() async {
        var changes: [String?] = []
        let detector = GameDetector(adb: ForegroundResultSequence([
            .timeout, .timeout, .success("game.a"), .timeout, .timeout, .success("game.b")
        ])) { changes.append($0) }
        for _ in 0..<3 { await detector.tick()?.value }
        #expect(detector.consecutiveTimeouts == 0)
        #expect(detector.pollingInterval == 1.5)
        #expect(changes == [nil, "game.a"])
        await detector.tick()?.value
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 2)
        #expect(detector.pollingInterval == 1.5)
        await detector.tick()?.value
        #expect(detector.consecutiveTimeouts == 0)
        #expect(changes == [nil, "game.a", nil, "game.b"])
    }

}
