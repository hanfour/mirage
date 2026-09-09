import Testing
@testable import MirageCore

@Suite struct EditorEntryDeciderTests {
    private let starter: [Binding] = [
        .tap(key: .key("j"), at: NormPoint(x: 0.8, y: 0.8)),
    ]
    private func profile(_ gameId: String) -> KeymapProfile {
        KeymapProfile(gameId: gameId, version: 3, bindings: [
            .tap(key: .key("z"), at: NormPoint(x: 0.1, y: 0.1)),
        ])
    }

    /// 已在編輯模式時，⌘E 永遠允許離開——即使途中偵測把遊戲切成 .inactive
    /// 導致 profile 變 nil，也不能卡死在編輯模式出不來。
    @Test func editingAlwaysAllowsLeaving() {
        #expect(EditorEntryDecider.decide(editing: true, profile: nil,
                                          currentPackage: nil, starterBindings: starter) == .leave)
    }

    /// 有 profile 就直接編它。
    @Test func existingProfileEntersDirectly() {
        let p = profile("com.game.a")
        #expect(EditorEntryDecider.decide(editing: false, profile: p,
                                          currentPackage: "com.game.a",
                                          starterBindings: starter) == .enter(p))
    }

    /// **本階段的重點**：沒有 profile 但知道當前遊戲 → 用 starter 版面建一份，
    /// gameId 是**當前遊戲**、version 從 1 起算。
    @Test func noProfileButKnownGameEntersWithStarter() {
        let decision = EditorEntryDecider.decide(editing: false, profile: nil,
                                                 currentPackage: "com.loomgames.pixelflow",
                                                 starterBindings: starter)
        #expect(decision == .enter(KeymapProfile(gameId: "com.loomgames.pixelflow",
                                                 version: 1, bindings: starter)))
    }

    /// 不知道在玩什麼（沒有 adb／沒有前景遊戲）就沒有 gameId 可以掛，只能不動作。
    @Test func noProfileAndNoPackageIsIgnored() {
        #expect(EditorEntryDecider.decide(editing: false, profile: nil,
                                          currentPackage: nil,
                                          starterBindings: starter) == .ignore)
    }

    /// starter 為空（理論上不會發生，`starterBindings` 有 fallback）也不建空 profile
    /// ——空白畫布是明確否決的起點。
    @Test func emptyStarterIsIgnored() {
        #expect(EditorEntryDecider.decide(editing: false, profile: nil,
                                          currentPackage: "com.game.a",
                                          starterBindings: []) == .ignore)
    }
    /// 不使用 starter 的三個分支不得觸發來源讀取。
    @Test func unusedStarterIsNotEvaluated() {
        var reads = 0
        func readStarter() -> [Binding] { reads += 1; return starter }
        let p = profile("com.game.a")
        #expect(EditorEntryDecider.decide(editing: true, profile: nil,
                                          currentPackage: "com.game.a", starterBindings: readStarter()) == .leave)
        #expect(EditorEntryDecider.decide(editing: false, profile: p,
                                          currentPackage: nil, starterBindings: readStarter()) == .enter(p))
        #expect(EditorEntryDecider.decide(editing: false, profile: nil,
                                          currentPackage: nil, starterBindings: readStarter()) == .ignore)
        #expect(reads == 0)
    }

    /// 建立 starter profile 時只讀一次，空版面仍維持忽略。
    @Test func neededStarterIsEvaluatedOnce() {
        var reads = 0
        func readStarter() -> [Binding] { reads += 1; return starter }
        #expect(EditorEntryDecider.decide(editing: false, profile: nil,
                                          currentPackage: "com.game.a", starterBindings: readStarter()) ==
                .enter(KeymapProfile(gameId: "com.game.a", version: 1, bindings: starter)))
        #expect(reads == 1)
    }

}
