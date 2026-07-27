import Foundation
import Testing
@testable import MirageCore

/// 可腳本化假探測：照劇本回放結果，記錄呼叫次數。
///
/// **預設（腳本用盡）回報版本刻意 <37**（Task 6 調整）：`EmulatorClient.makeDisplayTransport()`
/// 現在會依這個版本字串決定 display transport——若 ≥37 會建立**真正**的
/// `MmapStreamTransport(channel:)`，對著測試用、實際上沒有 emulator 監聽的 `GrpcChannelBox`
/// 發真實 gRPC 呼叫。這批既有測試的 `makeTransport` 才是它們想控制的假件；`ScriptedProbe`
/// 只是「隨便給個健康版本」，不是在測 MMAP 選路——用 <37 讓 makeDisplayTransport() 走
/// `makeTransport(boxCh)`（原本、也是這些測試唯一預期的路徑），避免真連線嘗試在測試行程中
/// 反覆重連、與既有的 NIO teardown 架構債疊加（實測會讓 `swift test` 尾聲以
/// `freed pointer was not the last allocation` 整個崩潰）。
final class ScriptedProbe: HealthProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HealthResult]
    private(set) var calls = 0
    init(_ results: [HealthResult]) { self.results = results }
    func probe(timeout: Duration) async -> HealthResult {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return results.isEmpty ? .healthy(version: "36.6.11.0") : results.removeFirst()
    }
}

@Suite struct HealthProbeTests {
    @Test func scriptedProbeReplaysResults() async {
        let p = ScriptedProbe([.failed, .timedOut, .healthy(version: "37.2.1.0")])
        #expect(await p.probe(timeout: .seconds(1)) == .failed)
        #expect(await p.probe(timeout: .seconds(1)) == .timedOut)
        #expect(await p.probe(timeout: .seconds(1)) == .healthy(version: "37.2.1.0"))
        #expect(p.calls == 3)
    }

    @Test func healthResultIsEquatable() {
        #expect(HealthResult.healthy(version: "1") == .healthy(version: "1"))
        #expect(HealthResult.healthy(version: "1") != .healthy(version: "2"))
        #expect(HealthResult.healthy(version: "1") != .failed)
    }
}
