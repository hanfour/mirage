import Foundation
import Testing
@testable import MirageCore

@Suite struct ProfileStoreTests {
    /// 每次呼叫給一個**保證唯一**的目錄。
    ///
    /// 原本用 `ObjectIdentifier(NSObject()).hashValue` 當後綴——那是剛配置的物件位址，
    /// 而位址在前一個 `NSObject` 釋放後**會被重用**，所以兩條測試拿到同一個目錄是可能的。
    /// 先前沒人踩到是因為沒有測試斷言「目錄是空的」；I2 新增的兩條正是那種形態，於是
    /// 這個既有的隱患會變成間歇失敗。UUID 沒有這個問題。
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-store-test-\(UUID().uuidString)")
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

    /// I2（Important，D5 階段 B 終審）：`save` 也要驗證，否則「存得進去、載不出來」的
    /// profile 會被寫上磁碟，而 load 端的錯誤被 `AppModel.applyActivation` 的 `try?` 吞掉
    /// ——症狀只剩「keymap 就是不生效」。
    ///
    /// 用 `identifierConflict` 當樣本是刻意的：那正是**夾取擋不住的那一類**（兩個 joystick
    /// 各自的座標與半徑都完全合法），也是階段 C「新增 binding」必然會踩到的形態。
    @Test func saveRejectsInvalidProfile() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        let conflicting = KeymapProfile(gameId: "com.game.conflict", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
            .joystick(up: .key("i"), down: .key("k"), left: .key("j"), right: .key("l"),
                      center: NormPoint(x: 0.8, y: 0.75), radius: 0.12),
        ])

        #expect(throws: ProfileError.identifierConflict) { try store.save(conflicting) }
        // **擲例外還不夠**：真正要防的是壞檔留在磁碟上，所以要斷言什麼都沒寫出去。
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// 數值型的違規同樣擋下來——`radius: 0` 是階段 B 半徑把手往左拖過圓心的產物。
    @Test func saveRejectsZeroRadius() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        let bad = KeymapProfile(gameId: "com.game.zero", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.2, y: 0.75), radius: 0),
        ])

        #expect(throws: ProfileError.invalidRadius) { try store.save(bad) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
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
