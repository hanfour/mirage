import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@MainActor
@Suite struct AppModelEditingTests {
    /// 測試用的暫存 store——**不得碰使用者真實的 Application Support 目錄**。
    static func tempStore(_ tag: String) -> (ProfileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-appmodel-\(tag)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ProfileStore(directory: dir), dir)
    }

    /// 注入縫本身：構造時用得上注入的 store 與 starter 來源，且不碰真實目錄。
    @Test func constructsWithInjectedDependencies() {
        let (store, dir) = Self.tempStore("construct")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))]

        let model = AppModel(store: store, starterBindings: { starter })

        #expect(model.currentPackage == nil)
        model.currentPackage = "com.game.injected"      // private(set) 時這行編不過
        #expect(model.currentPackage == "com.game.injected")
    }

    /// 階段 A 的核心：沒有 profile 但知道在玩什麼 → ⌘E 要打得開，且帶著 starter 版面。
    @Test func editingOpensWithStarterWhenNoProfileExists() {
        let (store, dir) = Self.tempStore("starter")
        defer { try? FileManager.default.removeItem(at: dir) }
        let starter: [Binding] = [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))]
        let model = AppModel(store: store, starterBindings: { starter })
        model.currentPackage = "com.loomgames.pixelflow"

        model.toggleEditing()

        #expect(model.editing)
        #expect(model.profile?.gameId == "com.loomgames.pixelflow")
        #expect(model.profile?.version == 1)
        #expect(model.profile?.bindings == starter)
    }

    /// **未存檔不落檔**：⌘E 只在記憶體裡建 starter，磁碟上不得出現任何檔案。
    /// 不小心按到 ⌘E 就憑空生出一個檔案，是「明確存檔」語意不能接受的。
    @Test func openingEditorWritesNothingToDisk() throws {
        let (store, dir) = Self.tempStore("nodisk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })
        model.currentPackage = "com.game.nodisk"

        model.toggleEditing()

        // 先確認 toggleEditing 真的做了事——否則下面的「目錄是空的」會因為
        // 「什麼都沒發生」而通過，那是綠得毫無意義。
        #expect(model.editing)
        #expect(model.profile?.gameId == "com.game.nodisk")

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.isEmpty, "⌘E 不得落檔，實得 \(files)")
    }

    /// 不知道在玩什麼就沒有 gameId 可以掛——維持現行的「不動作」。
    @Test func editingStaysClosedWithoutPackageOrProfile() {
        let (store, dir) = Self.tempStore("nopkg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })

        model.toggleEditing()

        #expect(!model.editing)
        #expect(model.profile == nil)
    }

    /// 已在編輯模式時一定出得來——即使途中 profile 被收成 nil。
    @Test func editingAlwaysCloses() {
        let (store, dir) = Self.tempStore("close")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(store: store,
                             starterBindings: { [.tap(key: .key("q"), at: NormPoint(x: 0.3, y: 0.3))] })
        model.currentPackage = "com.game.close"
        model.toggleEditing()
        #expect(model.editing)

        model.profile = nil          // 模擬偵測途中把遊戲切成 .inactive
        model.toggleEditing()

        #expect(!model.editing)
    }
}
