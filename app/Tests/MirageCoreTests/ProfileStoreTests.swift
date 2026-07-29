import Foundation
import Testing
@testable import MirageCore

@Suite struct ProfileStoreTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-store-test-\(UInt64(bitPattern: Int64(ObjectIdentifier(NSObject()).hashValue)))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func sample() -> KeymapProfile {
        KeymapProfile(gameId: "com.example.game", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
        ])
    }

    @Test func saveThenLoadRoundTrip() throws {
        let store = ProfileStore(directory: tempDir())
        try store.save(sample())
        let loaded = try store.load(gameId: "com.example.game")
        #expect(loaded == sample())
    }

    @Test func loadMissingThrowsNotFound() {
        let store = ProfileStore(directory: tempDir())
        #expect(throws: StoreError.notFound) { try store.load(gameId: "nope") }
    }

    @Test func loadCorruptedThrowsCorrupted() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        try "{ not valid json".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("bad.json"))
        #expect(throws: StoreError.corrupted) { try store.load(gameId: "bad") }
    }

    @Test func loadInvalidSchemaThrows() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        let bad = KeymapProfile(gameId: "x", version: 1, bindings: [
            .tap(key: .key("j"), at: NormPoint(x: 2.0, y: 0.5)),   // 越界
        ])
        let data = try JSONEncoder().encode(bad)
        try data.write(to: dir.appendingPathComponent("x.json"))
        #expect(throws: ProfileError.invalidCoordinate) { try store.load(gameId: "x") }
    }

    // 這裡原本有一條 `bundledCanaryProfileLoads`：用 `#filePath` 往上爬三層拼出
    // `app/Resources/profiles/com.example.game.json`，再 `guard fileExists else { return }`。
    // **D4 把資源搬進 `Sources/MirageCore/Resources/profiles/` 之後，那個寫死路徑就指向
    // 不存在的檔案，guard 讓它變成零斷言卻仍回報 passed**——正是本專案上一輪花整輪
    // 清掉的那種假訊號，只是這次由「原始碼樹佈局」而不是環境變數觸發。
    //
    // 沒有把路徑改對，是因為 `BuiltInProfilesTests.seedingFromBundleProducesLoadableProfile`
    // 走 `Bundle.module` → `seed` → `ProfileStore.load`，涵蓋面嚴格更大（多驗了資源真的
    // 進得了 bundle 這一段），而且**不依賴原始碼樹的相對位置**——搬檔案不會讓它靜默失效。
    // 留兩份只是重複，而重複的那份還是脆的那份。
}
