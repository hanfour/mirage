import Foundation
import Testing
@testable import MirageCore

@Suite struct TransitWindowTests {
    @Test func frameEqualityIgnoresTransit() {
        let a = Frame(width: 1, height: 1, rgba: Data([1, 2, 3, 4]), transitMs: 2)
        let b = Frame(width: 1, height: 1, rgba: Data([1, 2, 3, 4]), transitMs: 99)
        #expect(a == b)
        #expect(Frame(width: 1, height: 1, rgba: Data()).transitMs == nil)
    }

    @Test func invalidAndUnavailableAreNotLatencySamples() throws {
        var window = TransitWindow()
        window.record(-5)
        window.record(nil)
        #expect(window.latency.summary() == nil)
        window.record(0)
        window.record(20)
        let s = try #require(window.latency.summary())
        #expect(s.count == 2)
        #expect(s.p50 == 0)
        #expect(s.p95 == 20)
        #expect(window.invalid == 1)
        #expect(window.unavailable == 1)
        window.reset()
        #expect(window.invalid == 0)
        #expect(window.unavailable == 0)
        #expect(window.latency.summary() == nil)
    }
}
