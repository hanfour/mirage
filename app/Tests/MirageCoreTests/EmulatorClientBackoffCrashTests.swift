import Foundation
import Testing
@testable import MirageCore

/// D74：真 probe + 預設 sleeper 的整合回歸，不需要模擬器。
/// ci.sh 閘門 0 先確認 DEAD_PORT（預設 45999）無人監聽，再 export MIRAGE_PORT，
/// 所以每次 CI 都會跑。單獨執行時也須將 MIRAGE_PORT 指向無人監聽的埠。
@Suite(.timeLimit(.minutes(1))) struct EmulatorClientBackoffCrashTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MIRAGE_PORT"] != nil,
                   "需 MIRAGE_PORT 指向無人監聽的埠；ci.sh 閘門 0 自動設定"))
    func defaultClientSurvivesRepeatedConnectionFailures() async {
        // 必須全部採預設參數；注入假 probe / sleeper 會繞過原本的崩潰路徑。
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)

        var seen: [ConnState] = []
        for await state in client.states {
            seen.append(state)
            // reconnecting(0) 在第一次 backoff 之前發布，只等它會假綠。
            // 等到第三次失敗，才證明兩次真實 backoff 都已返回；之前不呼叫 stop。
            if state == .reconnecting(attempt: 2) || state == .connected { break }
        }
        await client.stop()

        #expect(seen == [
            .connecting,
            .reconnecting(attempt: 0),
            .reconnecting(attempt: 1),
            .reconnecting(attempt: 2),
        ])
    }
}
