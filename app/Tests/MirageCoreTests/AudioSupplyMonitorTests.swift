import Testing
import MirageCore

@Suite struct AudioSupplyMonitorTests {
    @Test func requiresFiveConsecutiveSeconds() {
        let initial = AudioSupplyMonitor()
        var monitor = initial
        for second in 1...4 {
            monitor = monitor.observing(packets: 88, supplyPercent: 6)
            #expect(monitor.state == .healthy)
            #expect(monitor.consecutiveLowSupplySeconds == second)
        }
        monitor = monitor.observing(packets: 88, supplyPercent: 6)
        #expect(monitor.state == .degraded)
        #expect(initial.state == .idle)
        #expect(initial.consecutiveLowSupplySeconds == 0)
        for _ in 0..<10 {
            monitor = monitor.observing(packets: 88, supplyPercent: 6)
            #expect(monitor.state == .degraded)
            #expect(monitor.consecutiveLowSupplySeconds == 5)
        }
    }

    @Test func healthyResetsAndRecovers() {
        var monitor = AudioSupplyMonitor()
        for _ in 0..<4 { monitor = monitor.observing(packets: 88, supplyPercent: 6) }
        monitor = monitor.observing(packets: 88, supplyPercent: 100)
        #expect(monitor.state == .healthy)
        #expect(monitor.consecutiveLowSupplySeconds == 0)
        for _ in 0..<4 {
            monitor = monitor.observing(packets: 88, supplyPercent: 6)
            #expect(monitor.state == .healthy)
        }
        monitor = monitor.observing(packets: 88, supplyPercent: 6)
        #expect(monitor.state == .degraded)
        monitor = monitor.observing(packets: 88, supplyPercent: 95)
        #expect(monitor.state == .healthy)
        #expect(monitor.consecutiveLowSupplySeconds == 0)
    }

    @Test func silenceResetsPendingAndDegradedStates() {
        for lowSeconds in [4, 5] {
            var monitor = AudioSupplyMonitor()
            for _ in 0..<lowSeconds { monitor = monitor.observing(packets: 88, supplyPercent: 6) }
            for _ in 0..<120 {
                monitor = monitor.observing(packets: 0, supplyPercent: 0)
                #expect(monitor.state == .idle)
                #expect(monitor.consecutiveLowSupplySeconds == 0)
            }
            for _ in 0..<4 {
                monitor = monitor.observing(packets: 88, supplyPercent: 6)
                #expect(monitor.state == .healthy)
            }
            monitor = monitor.observing(packets: 88, supplyPercent: 6)
            #expect(monitor.state == .degraded)
        }
    }

    @Test func supplyThresholdIsExclusive() {
        var monitor = AudioSupplyMonitor()
        // 剛好等於門檻視為健康，低於才累計。
        monitor = monitor.observing(packets: 11, supplyPercent: 49)
        #expect(monitor.consecutiveLowSupplySeconds == 1)
        monitor = monitor.observing(packets: 11, supplyPercent: 50)
        #expect(monitor.state == .healthy)
        #expect(monitor.consecutiveLowSupplySeconds == 0)
    }

    /// 低供應率的秒數裡封包數實測從 3 到 94 都出現過，所以封包數不參與判定，
    /// 只有「是不是 0」有意義。這一條鎖住那個設計，避免有人再加回封包門檻。
    @Test func packetCountDoesNotAffectJudgementWhenNonZero() {
        for packets in [3, 11, 30, 94] {
            var monitor = AudioSupplyMonitor()
            for _ in 0..<4 {
                monitor = monitor.observing(packets: packets, supplyPercent: 6)
                #expect(monitor.state == .healthy)
            }
            monitor = monitor.observing(packets: packets, supplyPercent: 6)
            #expect(monitor.state == .degraded)
        }
    }

    @Test func configurableThresholds() {
        var monitor = AudioSupplyMonitor(supplyThresholdPercent: 20,
                                         consecutiveSecondsToDegrade: 2)
        monitor = monitor.observing(packets: 10, supplyPercent: 20)
        #expect(monitor.consecutiveLowSupplySeconds == 0)
        monitor = monitor.observing(packets: 10, supplyPercent: 19)
        #expect(monitor.state == .healthy)
        monitor = monitor.observing(packets: 10, supplyPercent: 19)
        #expect(monitor.state == .degraded)
    }
}

@Suite struct AudioSupplyNoticeTests {
    typealias Notice = AudioSupplyMonitor.TransitionNotice

    @Test func degradedTransitionsAlwaysNotify() {
        #expect(AudioSupplyMonitor.notice(from: .healthy, to: .degraded) == Notice.degraded)
        #expect(AudioSupplyMonitor.notice(from: .idle, to: .degraded) == Notice.degraded)
    }

    /// 這一條是抽成純函式的理由：degraded 轉 idle 只代表 guest 不放音訊了，
    /// 供應率沒有被驗證過，不可以印 recovered；但它仍然是判定的結束，要有標記。
    /// 實務上每一次真實的恢復都會先經過 idle，所以這兩條都必須存在。
    @Test func degradedToIdleIsClearedNotRecovered() {
        #expect(AudioSupplyMonitor.notice(from: .degraded, to: .idle) == Notice.cleared)
    }

    @Test func degradedToHealthyIsRecovery() {
        #expect(AudioSupplyMonitor.notice(from: .degraded, to: .healthy) == Notice.recovered)
    }

    @Test func transitionsNotInvolvingDegradedAreSilent() {
        #expect(AudioSupplyMonitor.notice(from: .idle, to: .healthy) == Notice.none)
        #expect(AudioSupplyMonitor.notice(from: .healthy, to: .idle) == Notice.none)
    }

    @Test func sameStateNeverNotifies() {
        for state in [AudioSupplyMonitor.State.idle, .healthy, .degraded] {
            #expect(AudioSupplyMonitor.notice(from: state, to: state) == Notice.none)
        }
    }
}
