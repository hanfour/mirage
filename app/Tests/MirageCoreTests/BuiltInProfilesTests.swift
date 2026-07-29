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
        let copied = BuiltInProfiles.seed(into: dst, from: [a])
        #expect(copied == ["com.example.one"])
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

        let copied = BuiltInProfiles.seed(into: dst, from: [a])

        #expect(copied.isEmpty)          // 什麼都沒複製
        #expect(try String(contentsOf: existing, encoding: .utf8) == "{\"userEdited\":true}")
    }

    /// 目的目錄不存在時要自己建，不能靜默失敗——首次啟動就是這個情境。
    @Test func seedCreatesDestinationDirectory() throws {
        let src = tempDir("src-c")
        let dst = tempDir("dst-c").appendingPathComponent("nested/deeper")
        let a = try writeSource(src, name: "com.example.one", body: "{\"x\":1}")
        let copied = BuiltInProfiles.seed(into: dst, from: [a])
        #expect(copied == ["com.example.one"])
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("com.example.one.json").path))
    }

    /// 來源不存在時跳過該筆、不中斷其餘——一份壞掉不該讓其他份也進不去。
    @Test func seedSkipsMissingSourceButContinues() throws {
        let src = tempDir("src-d"), dst = tempDir("dst-d")
        let missing = src.appendingPathComponent("com.example.ghost.json")
        let real = try writeSource(src, name: "com.example.real", body: "{\"x\":1}")
        let copied = BuiltInProfiles.seed(into: dst, from: [missing, real])
        #expect(copied == ["com.example.real"])
    }

    /// 空清單是合法輸入，不是錯誤。
    @Test func seedWithNoSourcesIsNoOp() {
        let dst = tempDir("dst-e")
        #expect(BuiltInProfiles.seed(into: dst, from: []).isEmpty)
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
        let copied = BuiltInProfiles.seed(into: dst, from: BuiltInProfiles.bundledSources())
        #expect(copied.contains("com.example.game"))

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
}
