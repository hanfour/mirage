import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct InstanceMenuTests {
    private let game = EmulatorInstance(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 1)
    private let poc = EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 2)
    private let gameEntry = InstanceEntry(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554)
    private let pocEntry = InstanceEntry(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556)
    private let onGame = EmulatorEndpoint(host: "localhost", port: 8554)

    @Test func listsAllInstancesAndMarksCurrentByGrpcPort() {
        let entries = InstanceMenu.entries(table: [gameEntry, pocEntry], discovered: [game, poc], current: onGame)
        #expect(entries == [
            InstanceMenuEntry(title: "mirage-game（console 5554／gRPC 8554）", entry: gameEntry,
                              isCurrent: true, isRunning: true),
            InstanceMenuEntry(title: "mirage-poc（console 5556／gRPC 8556）", entry: pocEntry,
                              isCurrent: false, isRunning: true),
        ])
        #expect(entries.allSatisfy { $0.isEnabled })
    }

    @Test func tableRowsWithoutDiscoveryAreSelectableAndMarkedNotStarted() throws {
        let entries = InstanceMenu.entries(table: [gameEntry, pocEntry], discovered: [game], current: onGame)

        let row = try #require(entries.dropFirst().first)
        #expect(row.title == "mirage-poc（console 5556／gRPC 8556）（未啟動）")
        #expect(row.entry == pocEntry)
        #expect(!row.isRunning)
        #expect(row.isEnabled)
    }

    @Test func discoveredInstancesMissingFromTableAreStillListed() throws {
        let other = EmulatorInstance(avdName: "local-test", consolePort: 5560, grpcPort: 8560, pid: 3)
        let entries = InstanceMenu.entries(table: [gameEntry], discovered: [game, other], current: onGame)

        #expect(entries.map(\.entry) == [gameEntry,
                                         InstanceEntry(avdName: "local-test", consolePort: 5560, grpcPort: 8560)])
        let row = try #require(entries.dropFirst().first)
        #expect(row.isRunning)
        #expect(!row.isCurrent)
    }

    /// 規格 §3.3：沒有其他實例時子選單只有一個停用項。
    @Test func onlyCurrentInstanceYieldsDisabledPlaceholder() {
        let entries = InstanceMenu.entries(table: [gameEntry], discovered: [game], current: onGame)
        #expect(entries.count == 1)
        #expect(entries[0].title == InstanceMenu.placeholderTitle)
        #expect(entries[0].entry == nil)
        #expect(!entries[0].isEnabled)
        #expect(!entries[0].isCurrent)
    }

    @Test func emptyListYieldsDisabledPlaceholder() {
        let entries = InstanceMenu.entries(table: [], discovered: [], current: onGame)
        #expect(entries.map(\.title) == [InstanceMenu.placeholderTitle])
        #expect(!entries[0].isEnabled)
    }

    /// Mirage 指向的埠沒有探索檔（例如 MIRAGE_PORT 指到一台舊式啟動的實例）：
    /// 全部列出、沒有一個打勾——使用者仍然可以切到有探索檔的那台。
    @Test func currentNotDiscoveredListsEverythingUnchecked() {
        let entries = InstanceMenu.entries(table: [gameEntry, pocEntry], discovered: [game, poc],
                                           current: EmulatorEndpoint(host: "localhost", port: 8570))
        #expect(entries.map(\.isCurrent) == [false, false])
        #expect(entries.allSatisfy { $0.isEnabled })
    }

    /// 只看 gRPC 埠、不看 host：探索檔只描述本機實例，host 由 MIRAGE_HOST 決定且切換不改它。
    @Test func currentIsMatchedByPortOnly() {
        let entries = InstanceMenu.entries(table: [gameEntry, pocEntry], discovered: [game, poc],
                                           current: EmulatorEndpoint(host: "127.0.0.1", port: 8556))
        #expect(entries.map(\.isCurrent) == [false, true])
    }
}
