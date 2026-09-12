import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct InstanceMenuTests {
    private let game = EmulatorInstance(avdName: "mirage-game", consolePort: 5554, grpcPort: 8554, pid: 1)
    private let poc = EmulatorInstance(avdName: "mirage-poc", consolePort: 5556, grpcPort: 8556, pid: 2)
    private let onGame = EmulatorEndpoint(host: "localhost", port: 8554)

    @Test func listsAllInstancesAndMarksCurrentByGrpcPort() {
        let entries = InstanceMenu.entries(instances: [game, poc], current: onGame)
        #expect(entries == [
            InstanceMenuEntry(title: "mirage-game（console 5554／gRPC 8554）", instance: game, isCurrent: true),
            InstanceMenuEntry(title: "mirage-poc（console 5556／gRPC 8556）", instance: poc, isCurrent: false),
        ])
        #expect(entries.allSatisfy { $0.isEnabled })
    }

    /// 規格 §3.3：沒有其他實例時子選單只有一個停用項。
    @Test func onlyCurrentInstanceYieldsDisabledPlaceholder() {
        let entries = InstanceMenu.entries(instances: [game], current: onGame)
        #expect(entries.count == 1)
        #expect(entries[0].title == InstanceMenu.placeholderTitle)
        #expect(entries[0].instance == nil)
        #expect(!entries[0].isEnabled)
        #expect(!entries[0].isCurrent)
    }

    @Test func emptyListYieldsDisabledPlaceholder() {
        let entries = InstanceMenu.entries(instances: [], current: onGame)
        #expect(entries.map(\.title) == [InstanceMenu.placeholderTitle])
        #expect(!entries[0].isEnabled)
    }

    /// Mirage 指向的埠沒有探索檔（例如 MIRAGE_PORT 指到一台舊式啟動的實例）：
    /// 全部列出、沒有一個打勾——使用者仍然可以切到有探索檔的那台。
    @Test func currentNotDiscoveredListsEverythingUnchecked() {
        let entries = InstanceMenu.entries(instances: [game, poc],
                                           current: EmulatorEndpoint(host: "localhost", port: 8560))
        #expect(entries.map(\.isCurrent) == [false, false])
        #expect(entries.allSatisfy { $0.isEnabled })
    }

    /// 只看 gRPC 埠、不看 host：探索檔只描述本機實例，host 由 MIRAGE_HOST 決定且切換不改它。
    @Test func currentIsMatchedByPortOnly() {
        let entries = InstanceMenu.entries(instances: [game, poc],
                                           current: EmulatorEndpoint(host: "127.0.0.1", port: 8556))
        #expect(entries.map(\.isCurrent) == [false, true])
    }
}
