import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteLatencyWindowTests {
    @Test func nearestRankAndStageCounts() throws {
        var window = RemoteLatencyWindow()
        for value in (1...20).reversed() {
            window.recordPull(age: .milliseconds(value), transitMs: Double(value * 2), heartbeat: false)
            window.recordCompletion(encode: .milliseconds(value * 3), send: .microseconds(value * 100))
        }
        let summary = window.drain(interval: .milliseconds(1020))
        #expect(summary.type == "stats")
        #expect(summary.intervalMs == 1020)
        #expect(summary.newFrames == 20)
        #expect(summary.heartbeatFrames == 0)
        #expect(summary.age == .init(p50: 10, p95: 19, count: 20))
        #expect(summary.encode == .init(p50: 30, p95: 57, count: 20))
        #expect(summary.send == .init(p50: 1, p95: 1.9, count: 20))
        #expect(summary.transitMs == 20)
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(RemoteLatencySummary.self, from: data)
        #expect(decoded == summary)
    }

    @Test func heartbeatExcludesCachedAgeAndTransitButMeasuresEncoding() {
        var window = RemoteLatencyWindow()
        window.recordPull(age: .milliseconds(5), transitMs: 8, heartbeat: false)
        for _ in 0..<4 {
            window.recordPull(age: .seconds(60), transitMs: 9999, heartbeat: true)
            window.recordCompletion(encode: .milliseconds(2), send: .microseconds(500))
        }
        let summary = window.drain(interval: .seconds(1))
        #expect(summary.newFrames == 1)
        #expect(summary.heartbeatFrames == 4)
        #expect(summary.age == .init(p50: 5, p95: 5, count: 1))
        #expect(summary.transitMs == 8)
        #expect(summary.encode?.count == 4)
        #expect(summary.send?.p50 == 0.5)
    }

    @Test func unavailableAndInvalidTransitDoNotBecomeZero() throws {
        var window = RemoteLatencyWindow()
        for transit in [nil, Double.nan, Double.infinity, -1] as [Double?] {
            window.recordPull(age: .zero, transitMs: transit, heartbeat: false)
        }
        let summary = window.drain(interval: .seconds(1))
        #expect(summary.transitMs == nil)
        #expect(summary.newFrames == 4)
        #expect(summary.age?.p50 == 0)
        #expect(summary.encode == nil)
        let data = try JSONEncoder().encode(summary)
        #expect(!data.isEmpty)
        window.recordPull(age: .zero, transitMs: 0, heartbeat: false)
        let valid = window.drain(interval: .seconds(1))
        #expect(valid.transitMs == 0)
    }

    @Test func drainResetsAllStagesAndCounts() {
        var window = RemoteLatencyWindow()
        window.recordPull(age: .milliseconds(10), transitMs: 20, heartbeat: false)
        window.recordPull(age: .seconds(1), transitMs: 20, heartbeat: true)
        window.recordCompletion(encode: .milliseconds(3), send: .milliseconds(1))
        _ = window.drain(interval: .seconds(1))
        let empty = window.drain(interval: .seconds(1))
        #expect(empty.age == nil)
        #expect(empty.encode == nil)
        #expect(empty.send == nil)
        #expect(empty.transitMs == nil)
        #expect(empty.newFrames == 0)
        #expect(empty.heartbeatFrames == 0)
        // 前一窗送入、這一窗完成；只有完成樣本，不製造新幀或重算 age。
        window.recordCompletion(encode: .milliseconds(1500), send: .microseconds(100))
        let late = window.drain(interval: .seconds(1))
        #expect(late.newFrames == 0)
        #expect(late.age == nil)
        #expect(late.encode?.p50 == 1500)
    }
}
