import Foundation
import Testing
@testable import MirageCore

@Suite struct BuiltInProfilesTests {
    /// 這條是 D4 的風險閘門：整個設計建立在「Bundle.module 找得到資源」之上，
    /// 而那件事在動手前沒有被驗證過。先讓它綠，其餘才有意義。
    @Test func bundleContainsSampleProfile() throws {
        let url = Bundle.module.url(forResource: "com.example.game",
                                    withExtension: "json",
                                    subdirectory: "profiles")
        let found = try #require(url, "Bundle.module 找不到 profiles/com.example.game.json——資源沒進 bundle")
        let data = try Data(contentsOf: found)
        let profile = try JSONDecoder().decode(KeymapProfile.self, from: data)
        #expect(profile.gameId == "com.example.game")
    }

    /// 直接解碼產品 bundle，避免 starter 的 fallback 路徑掩蓋不同步。
    @Test func fallbackMatchesBundledSampleBindings() throws {
        let source = try #require(BuiltInProfiles.bundledSources().first {
            $0.lastPathComponent == "com.example.game.json"
        })
        let profile = try JSONDecoder().decode(KeymapProfile.self, from: Data(contentsOf: source))
        #expect(BuiltInProfiles.fallbackStarterBindings == profile.bindings)
    }

    /// 目的地不是目錄時，每筆複製失敗都必須有名稱與原因。
    @Test func seedReportsEveryFailure() throws {
        let src = tempDir("all-fail")
        defer { try? FileManager.default.removeItem(at: src) }
        let a = try writeSource(src, name: "one", body: "{}")
        let b = try writeSource(src, name: "two", body: "{}")
        let outcome = BuiltInProfiles.seed(into: URL(fileURLWithPath: "/dev/null/profiles"), from: [a, b])
        #expect(outcome.copied.isEmpty)
        #expect(outcome.failed.map(\.name) == ["one", "two"])
        #expect(outcome.failed.allSatisfy { !$0.error.localizedDescription.isEmpty })
    }

    /// 暫存目錄慣例照抄 ProfileStoreTests.tempDir()。
    private func tempDir(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-seed-\(tag)-\(UInt64(bitPattern: Int64(ObjectIdentifier(NSObject()).hashValue)))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 寫一個來源檔並回傳它的 URL。
    private func writeSource(_ dir: URL, name: String, body: String) throws -> URL {
        let u = dir.appendingPathComponent("\(name).json")
        try body.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    @Test func seedCopiesWhenAbsent() throws {
        let src = tempDir("src-a"), dst = tempDir("dst-a")
        let a = try writeSource(src, name: "com.example.one", body: "{\"x\":1}")
        let outcome = BuiltInProfiles.seed(into: dst, from: [a])
        #expect(outcome.copied == ["com.example.one"])
        let landed = dst.appendingPathComponent("com.example.one.json")
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(try String(contentsOf: landed, encoding: .utf8) == "{\"x\":1}")
    }

    /// **最重要的一條**：使用者編輯過的 profile 絕不能被覆寫。
    @Test func seedNeverOverwritesExisting() throws {
        let src = tempDir("src-b"), dst = tempDir("dst-b")
        let a = try writeSource(src, name: "com.example.one", body: "{\"builtin\":true}")
        let existing = dst.appendingPathComponent("com.example.one.json")
        try "{\"userEdited\":true}".write(to: existing, atomically: true, encoding: .utf8)

        let outcome = BuiltInProfiles.seed(into: dst, from: [a])

        #expect(outcome.failed.isEmpty)
        #expect(outcome.copied.isEmpty)          // 什麼都沒複製
        #expect(try String(contentsOf: existing, encoding: .utf8) == "{\"userEdited\":true}")
    }

    /// 目的目錄不存在時要自己建，不能靜默失敗——首次啟動就是這個情境。
    @Test func seedCreatesDestinationDirectory() throws {
        let src = tempDir("src-c")
        let dst = tempDir("dst-c").appendingPathComponent("nested/deeper")
        let a = try writeSource(src, name: "com.example.one", body: "{\"x\":1}")
        let outcome = BuiltInProfiles.seed(into: dst, from: [a])
        #expect(outcome.copied == ["com.example.one"])
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("com.example.one.json").path))
    }

    /// 來源不存在時跳過該筆、不中斷其餘——一份壞掉不該讓其他份也進不去。
    @Test func seedSkipsMissingSourceButContinues() throws {
        let src = tempDir("src-d"), dst = tempDir("dst-d")
        let missing = src.appendingPathComponent("com.example.ghost.json")
        let real = try writeSource(src, name: "com.example.real", body: "{\"x\":1}")
        let outcome = BuiltInProfiles.seed(into: dst, from: [missing, real])
        #expect(outcome.copied == ["com.example.real"])
        #expect(outcome.failed.map(\.name) == ["com.example.ghost"])
        #expect(try !#require(outcome.failed.first).error.localizedDescription.isEmpty)
    }

    /// 空清單是合法輸入，不是錯誤。
    @Test func seedWithNoSourcesIsNoOp() {
        let dst = tempDir("dst-e")
        #expect(BuiltInProfiles.seed(into: dst, from: []).copied.isEmpty)
    }

    /// bundle 查表要真的找得到東西——這是 seeding 在產品路徑上的來源。
    @Test func bundledSourcesFindsTheSampleProfile() {
        let sources = BuiltInProfiles.bundledSources()
        #expect(sources.contains { $0.lastPathComponent == "com.example.game.json" })
    }

    /// 端到端（不含 App 層）：從 bundle 種進暫存目錄後，ProfileStore 要讀得回來。
    /// 這條把「資源進得了 bundle」與「種下去的東西是合法 profile」串起來。
    @Test func seedingFromBundleProducesLoadableProfile() throws {
        let dst = tempDir("dst-bundle")
        let outcome = BuiltInProfiles.seed(into: dst, from: BuiltInProfiles.bundledSources())
        #expect(outcome.copied.contains("com.example.game"))

        let profile = try ProfileStore(directory: dst).load(gameId: "com.example.game")
        #expect(profile.gameId == "com.example.game")
        #expect(!profile.bindings.isEmpty)
    }

    /// seeding 的目的地與 ProfileStore 讀取的目錄必須是同一個——
    /// 兩份路徑複本遲早會漂移。
    @Test func standardDirectoryIsUnderApplicationSupport() {
        let dir = ProfileStore.standardDirectory()
        #expect(dir.path.contains("Application Support"))
        #expect(dir.lastPathComponent == "profiles")
    }

    /// starter 借的是**版面**，不是 gameId——借了 gameId 就會存回那個佔位檔（D5 §1 的死路）。
    @Test func starterBindingsComeFromTheFirstReadableSource() throws {
        let dir = tempDir("starter-ok")
        let json = """
        {"gameId":"whatever","version":9,"bindings":[
          {"tap":{"at":{"x":0.5,"y":0.5},"key":{"key":{"_0":"z"}}}}
        ]}
        """
        let src = try writeSource(dir, name: "a.json", body: json)
        let bindings = BuiltInProfiles.starterBindings(from: [src])
        #expect(bindings.count == 1)
        if case .tap(let key, _) = bindings[0] { #expect(key == .key("z")) }
        else { Issue.record("期待 .tap，實得 \(bindings[0])") }
    }

    /// 沒有來源（bundle 壞掉，見 D25）時退回寫死的 starter——編輯器不該因為資源問題
    /// 而完全打不開。
    @Test func starterBindingsFallBackWhenNoSourceIsReadable() {
        let bindings = BuiltInProfiles.starterBindings(from: [])
        #expect(bindings == BuiltInProfiles.fallbackStarterBindings)
        #expect(!bindings.isEmpty)
    }

    /// 來源存在但內容壞掉，也要退回 fallback，不能回空陣列——空的 starter 等於空白畫布，
    /// 而那是我們明確否決掉的起點。
    @Test func starterBindingsFallBackWhenSourceIsCorrupt() throws {
        let dir = tempDir("starter-corrupt")
        let src = try writeSource(dir, name: "bad.json", body: "{ not json")
        #expect(BuiltInProfiles.starterBindings(from: [src]) == BuiltInProfiles.fallbackStarterBindings)
    }

    /// fallback 本身必須是一份合法 profile 的 bindings。
    @Test func fallbackStarterIsValid() throws {
        let p = KeymapProfile(gameId: "g", version: 1,
                              bindings: BuiltInProfiles.fallbackStarterBindings)
        _ = try p.validated()
    }

    /// 即使來源能正常 decode，但 bindings 為空也要退回 fallback——空畫布正是
    /// 設計時明確否決的起點。
    @Test func starterBindingsFallBackWhenSourceHasEmptyBindings() throws {
        let dir = tempDir("starter-empty")
        let json = """
        {"gameId":"test.game","version":1,"bindings":[]}
        """
        let src = try writeSource(dir, name: "empty.json", body: json)
        #expect(BuiltInProfiles.starterBindings(from: [src]) == BuiltInProfiles.fallbackStarterBindings)
    }

    /// I4（Important，D5 階段 A 終審）：來源座標越界（`x > 1`）也要退回 fallback。
    /// `JSONDecoder().decode` 本身不會拒絕越界座標，只有 `.validated()` 會——而
    /// `KeymapEngine.snapshot()` 對 tap／靜止搖桿點刻意不夾取，安全性建立在
    /// 「profile 必經 validated()」這條不變式上，starter 這條路徑不能是例外。
    @Test func starterBindingsFallBackWhenSourceHasOutOfRangeCoordinate() throws {
        let dir = tempDir("starter-oob")
        let json = """
        {"gameId":"test.game","version":1,"bindings":[
          {"tap":{"at":{"x":1.5,"y":0.5},"key":{"key":{"_0":"z"}}}}
        ]}
        """
        let src = try writeSource(dir, name: "oob.json", body: json)
        #expect(BuiltInProfiles.starterBindings(from: [src]) == BuiltInProfiles.fallbackStarterBindings)
    }
}
