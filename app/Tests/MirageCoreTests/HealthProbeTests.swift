import Foundation
import Testing
@testable import MirageCore

/// 可腳本化假探測：照劇本回放結果，記錄呼叫次數。
final class ScriptedProbe: HealthProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HealthResult]
    private(set) var calls = 0
    init(_ results: [HealthResult]) { self.results = results }
    func probe(timeout: Duration) async -> HealthResult {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return results.isEmpty ? .healthy : results.removeFirst()
    }
}

@Suite struct HealthProbeTests {
    @Test func scriptedProbeReplaysResults() async {
        let p = ScriptedProbe([.failed, .timedOut, .healthy])
        #expect(await p.probe(timeout: .seconds(1)) == .failed)
        #expect(await p.probe(timeout: .seconds(1)) == .timedOut)
        #expect(await p.probe(timeout: .seconds(1)) == .healthy)
        #expect(p.calls == 3)
    }

    @Test func healthResultIsEquatable() {
        #expect(HealthResult.healthy == .healthy)
        #expect(HealthResult.healthy != .failed)
    }
}
