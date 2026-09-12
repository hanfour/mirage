import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct RemoteLaunchOptionsTests {
    private let token = "00112233445566778899aabbccddeeff"

    @Test func absentOrNotOneMeansNil() {
        #expect(RemoteLaunchOptions.parse([:]) == nil)
        #expect(RemoteLaunchOptions.parse(["MIRAGE_REMOTE": "0"]) == nil)
        #expect(RemoteLaunchOptions.parse(["MIRAGE_REMOTE": "yes"]) == nil)
    }

    @Test func defaultsToPort8765WithoutToken() throws {
        let options = try #require(RemoteLaunchOptions.parse(["MIRAGE_REMOTE": "1"]))
        #expect(options.port == 8765)
        #expect(options.token == nil)
        #expect(options.problems.isEmpty)
    }

    @Test func readsPortAndToken() throws {
        let options = try #require(RemoteLaunchOptions.parse([
            "MIRAGE_REMOTE": "1", "MIRAGE_REMOTE_PORT": "9000", "MIRAGE_REMOTE_TOKEN": token,
        ]))
        #expect(options.port == 9000)
        #expect(options.token == PairingToken(value: token))
    }

    /// 壞值不讓功能整個不開：退回預設並記下問題，`AppModel.start()` 會印出來。
    @Test func invalidPortOrTokenFallBackAndReportProblems() throws {
        let options = try #require(RemoteLaunchOptions.parse([
            "MIRAGE_REMOTE": "1", "MIRAGE_REMOTE_PORT": "70000", "MIRAGE_REMOTE_TOKEN": "ABC",
        ]))
        #expect(options.port == 8765)
        #expect(options.token == nil)
        #expect(options.problems.count == 2)
        #expect(options.problems[0].contains("MIRAGE_REMOTE_PORT"))
        #expect(options.problems[1].contains("MIRAGE_REMOTE_TOKEN"))
    }
}
