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
}
