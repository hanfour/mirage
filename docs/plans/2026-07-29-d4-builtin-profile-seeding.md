# D4 內建 profile 上架 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓內建的範例 keymap profile 真的進得了 bundle、能在首次啟動時落到使用者目錄，並移除一條會載入錯誤 profile 的過期死路徑。

**Architecture:** 資源搬進 `Sources/MirageCore/Resources/`（SPM 要求資源位於 target 目錄下）並在 `Package.swift` 宣告；seeding 寫成 MirageCore 的純函式（輸入來源與目的 URL，可用暫存目錄逐條測試），唯一碰 `Bundle.module` 的查表獨立成一個函式；`AppModel` 啟動時呼叫一次 seeding，並刪掉寫死 `gameId` 的載入。

**Tech Stack:** Swift 6.2（語言模式 v5，`-strict-concurrency=complete`）、SwiftPM resources、swift-testing。

## Global Constraints

- 設計依據：`docs/specs/2026-07-29-d4-builtin-profile-seeding-design.md`。有衝突以設計文件為準。
- **範例 profile 的 `gameId` 維持 `com.example.game`**，不得改成任何真實遊戲的 package。理由見設計 §1.3：Pixel Flow 是點擊／拖曳型遊戲，不需要 keymap profile。
- **seeding 策略：不存在才複製，永不覆寫。** 使用者的編輯絕不能被吃掉。
- 純邏輯放 `MirageCore`（可單元測試），AppKit 相依只能留在 `MirageShell`。
- 測試框架用 swift-testing（`@Suite` / `@Test` / `#expect`）。**不得**用 `guard <env> else { return }` 做 skip。
- 暫存目錄的測試慣例照抄 `app/Tests/MirageCoreTests/ProfileStoreTests.swift:6-11` 的 `tempDir()`。
- **每個 task 結束前跑 `cd app && ./scripts/ci.sh`**（不只 `swift test`）。理由：D2 那輪有一條測試 50% 機率紅，只跑一次看不出來；ci.sh 的閘門 2 會連跑 3 次。
- 註解與 commit message 用繁體中文（台灣用語），解釋「為什麼」而非「做什麼」。
- **不得**在文件中用 `pending-human` / `pending-unlock` 描述未驗證項。

## File Structure

| 檔案 | 動作 | 責任 |
|---|---|---|
| `app/Resources/profiles/com.example.game.json` | **移動** → `app/Sources/MirageCore/Resources/profiles/` | SPM 資源必須在 target 目錄下 |
| `app/Package.swift` | 修改 | MirageCore target 加 `resources: [.copy("Resources/profiles")]` |
| `app/Sources/MirageCore/Keymap/BuiltInProfiles.swift` | 建立 | seeding 純函式 ＋ bundle 查表 |
| `app/Sources/MirageCore/Keymap/ProfileStore.swift` | 修改 | 抽出 `standardDirectory()`，讓 seeding 與 store 共用同一個路徑 |
| `app/Tests/MirageCoreTests/BuiltInProfilesTests.swift` | 建立 | 上述的單元測試 |
| `app/Sources/MirageShell/AppModel.swift` | 修改 | 啟動時 seeding；刪掉寫死 `gameId` 的死路徑 |
| `app/Sources/MirageShell/MirageScene.swift` | 修改 | 啟動流程加一步 seeding |
| `app/README.md`、`docs/specs/2026-07-29-project-review.md` | 修改 | 交付紀錄與債務表 |

---

### Task 1: 資源進 bundle（**這是風險閘門，失敗就停**）

**Files:**
- Move: `app/Resources/profiles/com.example.game.json` → `app/Sources/MirageCore/Resources/profiles/com.example.game.json`
- Modify: `app/Package.swift:20-27`（MirageCore target）
- Test: `app/Tests/MirageCoreTests/BuiltInProfilesTests.swift`（建立）

**Interfaces:**
- Consumes: 無。
- Produces: 資源可經 `Bundle.module` 取得。Task 3 的 `bundledSources()` 依賴這件事。

**⚠️ 這個 task 的存在目的是先擋掉一個未驗證的假設。** 設計 §4.1 寫明：本設計假設
`Bundle.module` 在 `MirageCoreTests` 執行時找得到資源，而**那件事沒有被驗證過**。
若這個 task 做不出綠燈，**停下來回報 BLOCKED**，不要改用絕對路徑、不要把資源複製進測試
target、不要任何繞路——繞路會讓「產品到底拿不拿得到資源」繼續沒被驗證，而那正是 D4 本身的成因。

- [ ] **Step 1: 搬檔案**

```bash
cd /Users/hanfourhuang/Projects/mirage/app
mkdir -p Sources/MirageCore/Resources/profiles
git mv Resources/profiles/com.example.game.json Sources/MirageCore/Resources/profiles/com.example.game.json
rmdir Resources/profiles Resources 2>/dev/null || true
```

- [ ] **Step 2: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/BuiltInProfilesTests.swift`：

```swift
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
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `cd app && swift test --filter bundleContainsSampleProfile 2>&1 | tail -20`
Expected: 失敗。可能是編譯錯誤（`Bundle.module` 不存在，因為 target 還沒宣告 resources），
也可能是 `#require` 失敗。**兩種都算「如預期失敗」**——重點是它現在不是綠的。

- [ ] **Step 4: 在 Package.swift 宣告資源**

`app/Package.swift` 的 MirageCore target 目前是：

```swift
        .target(
            name: "MirageCore",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: strict
        ),
```

改成：

```swift
        .target(
            name: "MirageCore",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            // 內建範例 profile。`.copy` 而非 `.process`：這是 JSON，不需要任何編譯期
            // 處理，`.copy` 保持 profiles/ 這層目錄結構原樣（查表時要用 subdirectory）。
            //
            // 這個宣告在 2026-07-29 之前**不存在**，所以 `app/Resources/profiles/` 裡那個
            // 檔案對建置系統而言不存在——它永遠到不了使用者的 Application Support 目錄。
            // 那就是債務 D4 的本體。
            resources: [.copy("Resources/profiles")],
            swiftSettings: strict
        ),
```

- [ ] **Step 5: 跑測試確認通過**

Run: `cd app && swift test --filter bundleContainsSampleProfile 2>&1 | grep -E '✔|✘|Test run|error:'`
Expected: `Test run with 1 test passed`。

**若仍失敗**：停下來回報 BLOCKED，附上實際錯誤訊息。見本 task 開頭的說明。

- [ ] **Step 6: 跑完整閘門**

Run: `cd app && ./scripts/ci.sh 2>&1 | tail -8`
Expected: 三道閘門全過、退出碼 0。

- [ ] **Step 7: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add -A
git commit -m "feat: 內建 profile 真的進 bundle

Package.swift 的 MirageCore target 先前無 resources 宣告，且 app/Resources/ 在
target 目錄之外——SPM 兩個條件都不滿足，所以磁碟上那個 JSON 對建置系統而言不存在，
永遠到不了使用者的 Application Support 目錄。那就是債務 D4 的本體。

資源搬進 Sources/MirageCore/Resources/profiles/ 並用 .copy 宣告（JSON 不需要編譯期
處理，.copy 保持目錄結構，查表時要用 subdirectory）。

先寫這條測試而不是先寫功能：整個 D4 設計建立在「Bundle.module 找得到資源」之上，
而那個假設在動手前沒有被驗證過。"
```

---

### Task 2: `BuiltInProfiles.seed` 純函式

**Files:**
- Create: `app/Sources/MirageCore/Keymap/BuiltInProfiles.swift`
- Test: `app/Tests/MirageCoreTests/BuiltInProfilesTests.swift`（在 Task 1 建立的 suite 內新增）

**Interfaces:**
- Consumes: 無（純檔案操作）。
- Produces: `BuiltInProfiles.seed(into directory: URL, from sources: [URL]) -> [String]`，
  回傳實際複製了哪些檔名（不含 `.json` 副檔名）。Task 4 的 `AppModel` 會呼叫它。

- [ ] **Step 1: 寫失敗測試**

在 `BuiltInProfilesTests` suite 內、`bundleContainsSampleProfile` 之後新增：

```swift
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
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter BuiltInProfilesTests 2>&1 | tail -20`
Expected: 編譯失敗，`cannot find 'BuiltInProfiles' in scope`。

- [ ] **Step 3: 寫實作**

建立 `app/Sources/MirageCore/Keymap/BuiltInProfiles.swift`：

```swift
import Foundation

/// 內建範例 profile 的上架。
///
/// **為什麼獨立成一個型別而不是塞進 `ProfileStore`**：seeding 是「把 bundle 的東西
/// 搬到使用者目錄」，與 `ProfileStore` 的「讀寫使用者目錄」是兩件事。塞進
/// `ProfileStore.standard()` 會讓那個工廠方法每次呼叫都做檔案 I/O——隱藏副作用。
public enum BuiltInProfiles {
    /// 把 `sources` 複製進 `directory`，**已存在者一律不動**。
    /// 回傳實際複製了哪些（檔名去掉 `.json`）；空陣列代表全都已存在。
    ///
    /// **永不覆寫是硬性語意，不是最佳化**：使用者用 ⌘E 編輯過的 profile 若被
    /// App 升級覆寫掉，那是不可回復的資料遺失。代價是新版內建 profile 不會自動
    /// 送到舊使用者手上——接受，換來零版本遷移機制與可預測的行為。
    ///
    /// 單一來源失敗（檔案不存在、無讀取權限）只跳過該筆、不中斷其餘：一份壞掉
    /// 不該讓其他份也進不去。回傳值只列成功的，呼叫端可據此如實回報。
    @discardableResult
    public static func seed(into directory: URL, from sources: [URL]) -> [String] {
        let fm = FileManager.default
        // 首次啟動時目的目錄不存在，這裡自己建——少了這步整個 seeding 會靜默無效，
        // 而那正是首次啟動這個最重要的情境。
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var copied: [String] = []
        for source in sources {
            let name = source.deletingPathExtension().lastPathComponent
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
                copied.append(name)
            } catch {
                continue        // 見上：單筆失敗不影響其餘
            }
        }
        return copied
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app && swift test --filter BuiltInProfilesTests 2>&1 | grep -E '✔|✘|Test run'`
Expected: `Test run with 6 tests passed`（Task 1 的 1 條 + 本 task 的 5 條）。

- [ ] **Step 5: 跑完整閘門**

Run: `cd app && ./scripts/ci.sh 2>&1 | tail -8`
Expected: 三道閘門全過、退出碼 0。

- [ ] **Step 6: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Sources/MirageCore/Keymap/BuiltInProfiles.swift app/Tests/MirageCoreTests/BuiltInProfilesTests.swift
git commit -m "feat: BuiltInProfiles.seed——不存在才複製，永不覆寫

輸入是來源與目的 URL，所以可以用暫存目錄逐條測試：已存在不覆寫、目的目錄不存在、
來源缺失、空清單。

永不覆寫是硬性語意不是最佳化——使用者用 ⌘E 編輯過的 profile 若被 App 升級覆寫掉，
那是不可回復的資料遺失。代價是新版內建 profile 不會自動送到舊使用者手上，接受。

獨立成一個型別而不是塞進 ProfileStore：塞進 standard() 會讓那個工廠方法每次呼叫
都做檔案 I/O，是隱藏副作用。"
```

---

### Task 3: `bundledSources()` 與 `ProfileStore.standardDirectory()`

**Files:**
- Modify: `app/Sources/MirageCore/Keymap/BuiltInProfiles.swift`（加 `bundledSources()`）
- Modify: `app/Sources/MirageCore/Keymap/ProfileStore.swift:15-21`（抽出 `standardDirectory()`）
- Test: `app/Tests/MirageCoreTests/BuiltInProfilesTests.swift`

**Interfaces:**
- Consumes: Task 1 的 bundle 資源、Task 2 的 `seed(into:from:)`。
- Produces:
  - `BuiltInProfiles.bundledSources() -> [URL]`
  - `ProfileStore.standardDirectory() -> URL`
  兩者 Task 4 的 `AppModel` 都會用。

**為什麼要動 `ProfileStore`**：seeding 的目的地必須與 `ProfileStore.standard()` 讀取的
目錄**是同一個**。那段路徑目前寫在 `standard()` 內部；若在 `AppModel` 或
`BuiltInProfiles` 再寫一次，就是同一個知識的第二份複本——這個 repo 剛因為
`EmulatorEndpoint` 的解析有兩份而吃過虧（見 `2026-07-29-project-review.md` §7）。
所以是把既有知識**暴露出來**，不是把 seeding 塞進 `ProfileStore`（那條設計 §5 明文禁止）。

- [ ] **Step 1: 寫失敗測試**

在 `BuiltInProfilesTests` suite 內新增：

```swift
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
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter BuiltInProfilesTests 2>&1 | tail -20`
Expected: 編譯失敗，`type 'BuiltInProfiles' has no member 'bundledSources'`
與 `type 'ProfileStore' has no member 'standardDirectory'`。

- [ ] **Step 3: 加 `bundledSources()`**

在 `app/Sources/MirageCore/Keymap/BuiltInProfiles.swift` 的 `seed` 之後加入：

```swift
    /// bundle 內建的 profile 檔案清單。
    ///
    /// **這是本型別唯一不可單元測試的部分**（`Bundle.module` 是建置系統產生的），
    /// 所以刻意獨立成一個函式，讓不可測的面積縮到最小——`seed` 的所有判斷都在
    /// 純函式那邊，用暫存目錄逐條驗過。
    ///
    /// `subdirectory: "profiles"` 對應 `Package.swift` 的 `.copy("Resources/profiles")`：
    /// `.copy` 保持目錄結構，所以查表要帶這一層。若改成 `.process`，目錄會被攤平、
    /// 這裡就要拿掉 subdirectory——兩者要一起改。
    public static func bundledSources() -> [URL] {
        Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "profiles") ?? []
    }
```

- [ ] **Step 4: 抽出 `ProfileStore.standardDirectory()`**

`app/Sources/MirageCore/Keymap/ProfileStore.swift` 目前是：

```swift
    /// App 預設位置。
    public static func standard() -> ProfileStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage/profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return ProfileStore(directory: base)
    }
```

改成：

```swift
    /// App 預設的 profile 目錄。
    ///
    /// 公開是因為 seeding（`BuiltInProfiles`）的目的地必須與這裡讀取的目錄**是同一個**。
    /// 讓呼叫端自己拼一次 "Mirage/profiles" 會產生第二份複本，而兩份同樣的知識遲早漂移
    /// ——這個 repo 剛因為 `EmulatorEndpoint` 的解析有兩份而吃過虧。
    public static func standardDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage/profiles", isDirectory: true)
    }

    /// App 預設位置。
    public static func standard() -> ProfileStore {
        let base = standardDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return ProfileStore(directory: base)
    }
```

- [ ] **Step 5: 跑測試確認通過**

Run: `cd app && swift test --filter BuiltInProfilesTests 2>&1 | grep -E '✔|✘|Test run'`
Expected: `Test run with 9 tests passed`。

- [ ] **Step 6: 跑完整閘門**

Run: `cd app && ./scripts/ci.sh 2>&1 | tail -8`
Expected: 三道閘門全過、退出碼 0。

- [ ] **Step 7: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Sources/MirageCore/Keymap/BuiltInProfiles.swift app/Sources/MirageCore/Keymap/ProfileStore.swift app/Tests/MirageCoreTests/BuiltInProfilesTests.swift
git commit -m "feat: bundledSources() 與 ProfileStore.standardDirectory()

bundledSources 是本型別唯一不可單元測試的部分（Bundle.module 是建置系統產生的），
刻意獨立成一個函式讓不可測的面積縮到最小。

standardDirectory 是把既有知識暴露出來，不是把 seeding 塞進 ProfileStore：
seeding 的目的地必須與 store 讀取的目錄是同一個，讓呼叫端自己拼一次
\"Mirage/profiles\" 會產生第二份複本，而兩份同樣的知識遲早漂移——這個 repo 剛因為
EmulatorEndpoint 的解析有兩份而吃過虧。

新增的端到端測試（不含 App 層）把「資源進得了 bundle」與「種下去的是合法 profile」
串起來：從 bundle 種進暫存目錄後，ProfileStore 要讀得回來。"
```

---

### Task 4: `AppModel` 接線與死路徑清除

**Files:**
- Modify: `app/Sources/MirageShell/AppModel.swift:57-59`（刪 `static let gameId`）、`:96-101`（`loadKeymap`）
- Modify: `app/Sources/MirageShell/MirageScene.swift:55`（啟動流程加一步）

**Interfaces:**
- Consumes: `BuiltInProfiles.seed(into:from:)`、`BuiltInProfiles.bundledSources()`、
  `ProfileStore.standardDirectory()`（皆 Task 2/3）。
- Produces: `AppModel.seedBuiltInProfiles()`，由 `MirageScene` 的 `.task` 呼叫。

**本 task 沒有單元測試**：`AppModel` 是 `@MainActor @Observable` 且建構時有多個全域副作用
（債務 D13 記載「光建構就有 8 個全域副作用」），在不做 D13 的前提下無法 hermetic 測試。
所有可測的判斷都已在 Task 2/3 的 `BuiltInProfiles` 逐條覆蓋，這裡只剩三行接線。
**這是刻意的取捨，Task 5 要如實記載。**

- [ ] **Step 1: 加 seeding 方法**

在 `app/Sources/MirageShell/AppModel.swift` 的 `loadKeymap()` **之前**加入：

```swift
    /// 首次啟動時把內建範例 profile 種進使用者目錄。已存在者不動（見 `BuiltInProfiles.seed`）。
    ///
    /// 一定要印出結果：沒有這行，「內建 profile 到底有沒有到位」就變成只能靠翻檔案系統
    /// 才知道的事——而 D4 的本體正是「那個檔案從來沒到位，卻沒有任何訊號」。
    func seedBuiltInProfiles() {
        let copied = BuiltInProfiles.seed(into: ProfileStore.standardDirectory(),
                                          from: BuiltInProfiles.bundledSources())
        if copied.isEmpty {
            print("[profile] 內建 profile 已存在，未複製")
        } else {
            print("[profile] 種下內建 profile：\(copied.joined(separator: ", "))")
        }
    }
```

- [ ] **Step 2: 刪掉寫死的 `gameId` 與那次載入**

`AppModel.swift:57-59` 目前是：

```swift
    /// PLACEHOLDER：目前哪個 game 在跑（gameId）尚未有偵測機制，先寫死——與 Task 7 brief
    /// 一致，實際綁定留待後續任務（見 task-7-report.md pending-human 清單）。
    static let gameId = "com.example.game"
```

**整段刪除**（三行連同註解）。

`AppModel.swift:98-102` 的 `loadKeymap()` 目前是：

```swift
    func loadKeymap() {
        profile = try? ProfileStore.standard().load(gameId: Self.gameId)
        keymap = KeymapController(client: client, profile: profile)
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }
```

改成（**注意：不能整段刪，它還負責建立 controller 與更新游標捕捉**）：

```swift
    /// 建立 keymap controller。**啟動時不載入任何 profile**——載入哪一份由遊戲偵測決定
    /// （`applyActivation()` → `keymap?.reload(p)`）。
    ///
    /// 更正（2026-07-29，D4）：這裡原本用寫死的 `Self.gameId`（`com.example.game`）載入，
    /// 而那行的註解寫「尚未有偵測機制」——**那句話在 P1-d 就過期了**，`GameDetector` →
    /// `currentPackage` → `applyActivation` 早已是唯一的真實來源。舊路徑的實際效果是
    /// 「不管使用者在玩什麼，啟動時都載入 com.example.game 的 profile」。
    ///
    /// **行為改變**：沒有 adb 的環境下偵測不會跑（`AdbClient.standard()` 靜默不偵測），
    /// 因此不會有任何 profile。逃生出口是選單列的「套用 profile ▸」手動覆寫。
    /// 這是刻意的取捨——寧可沒有 profile，也不要載入一份與當前遊戲無關的。
    func loadKeymap() {
        keymap = KeymapController(client: client, profile: nil)
        mouseCapture.updateCapture(shouldCapture: shouldCapture)
    }
```

- [ ] **Step 3: 在啟動流程加一步**

`app/Sources/MirageShell/MirageScene.swift` 的 `.task` 目前是：

```swift
            .task {
                appDelegate.model = model   // 供 applicationWillTerminate 使用
                await model.start()
                model.startLifecycle()
                model.loadKeymap()
                model.startDetection()
            }
```

改成（seeding 必須在 `startDetection()` **之前**——偵測一旦命中就會去讀那個目錄）：

```swift
            .task {
                appDelegate.model = model   // 供 applicationWillTerminate 使用
                await model.start()
                model.startLifecycle()
                model.seedBuiltInProfiles()   // 必須在 startDetection 之前：偵測命中就會讀那個目錄
                model.loadKeymap()
                model.startDetection()
            }
```

- [ ] **Step 4: 確認全碼庫無 `AppModel.gameId` 殘留**

Run: `cd app && grep -rn "Self.gameId\|AppModel.gameId" Sources/ Tests/ || echo "（無殘留）"`
Expected: `（無殘留）`

- [ ] **Step 5: 建置並跑完整套件**

Run: `cd app && swift build 2>&1 | grep -E 'error|Build complete' && swift test 2>&1 | grep -E '✘ Test|Test run with'`
Expected: `Build complete!`；測試全綠。

- [ ] **Step 6: 跑完整閘門**

Run: `cd app && ./scripts/ci.sh 2>&1 | tail -8`
Expected: 三道閘門全過、退出碼 0。

- [ ] **Step 7: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/Sources/MirageShell/AppModel.swift app/Sources/MirageShell/MirageScene.swift
git commit -m "feat: 啟動時種下內建 profile，並刪掉載入錯誤 profile 的死路徑

寫死的 gameId 不只是佔位，它是過期的死路徑：註解寫「尚未有偵測機制」，但 P1-d 就加了
GameDetector，applyActivation 用的正是 currentPackage。舊路徑的實際效果是「不管使用者
在玩什麼，啟動時都載入 com.example.game 的 profile」。

loadKeymap 不能整段刪——它還負責建立 KeymapController 與更新游標捕捉。改成建立不帶
profile 的 controller，由偵測填入。

行為改變（刻意）：沒有 adb 的環境下偵測不會跑，因此不會有任何 profile。逃生出口是
選單列的「套用 profile ▸」手動覆寫。寧可沒有 profile，也不要載入一份與當前遊戲無關的。

seeding 印一行結果：沒有它，「內建 profile 有沒有到位」就變成只能靠翻檔案系統才知道
的事——而 D4 的本體正是「那個檔案從來沒到位，卻沒有任何訊號」。"
```

---

### Task 5: 文件與債務表

**Files:**
- Modify: `app/README.md`（P1-c 段的 profile 描述）
- Modify: `docs/specs/2026-07-29-project-review.md`（債務表 D4、§8 A 節）

**Interfaces:** 無。

- [ ] **Step 1: 更新 README 的 profile 描述**

`app/README.md` 的 P1-c 段目前有這句（**請先 grep 確認實際文字再改**）：

```
位置 `~/Library/Application Support/Mirage/profiles/<gameId>.json`；內建指標 `com.example.game`。
```

改成：

```
位置 `~/Library/Application Support/Mirage/profiles/<gameId>.json`。
內建**範例** profile `com.example.game` 於首次啟動時複製到該目錄（已存在者不動，
使用者的編輯永不被覆寫）。

> **`com.example.game` 是格式範例，不對應任何真實遊戲。** `com.example.*` 是保留給
> 範例用的網域。Phase-1 的指標遊戲 Pixel Flow（`com.loomgames.pixelflow`）是點擊／
> 拖曳型，**不需要 keymap profile**——滑鼠直接 tap（無 profile 時的 P1-a 路徑）就是
> 對的輸入模型，這也正是驗收線「1 款指標遊戲開箱即玩」已經通過的原因。
> 實測記錄見 `../docs/specs/2026-07-29-d4-builtin-profile-seeding-design.md` §1.3。
>
> **因此 `.auto` 自動啟用目前沒有端到端的自動驗證**：`.auto` 要求 profile 的 `gameId`
> 對得上偵測到的前景 package，而範例是 `com.example.game`，不對應任何真實 App。
> 這**可以驗，只是沒人回頭驗**（§8 D 節的第三類）——手動放一份以真實 package 命名的
> profile（例如 `com.google.android.apps.nexuslauncher.json`，模擬器上一定存在的桌面），
> 用 `.app` bundle + `open` 啟動 Mirage，把該 App 帶到前景，看選單列的
> 「遊戲：… [keymap ✓]」是否切換。阻礙（`AVAudioEngine` NSException）已於 2026-07-28 修復。
```

- [ ] **Step 2: 更新債務表 D4**

`docs/specs/2026-07-29-project-review.md` 的 D4 那列目前是：

```
| **D4** | **內建 profile 沒進 bundle** + `AppModel.gameId` 寫死 `com.example.game` | `.auto` 自動啟用端到端不可能通；指標遊戲沒有可用 profile | 半天 | **P1** |
```

改成（**行號請自己 grep 確認後填正確的**）：

```
| ~~**D4**~~ | ~~**內建 profile 沒進 bundle** + `AppModel.gameId` 寫死~~ | **✅ 已修（2026-07-29）**。`Package.swift` 補 `resources: [.copy("Resources/profiles")]`、資源搬進 target 目錄；`BuiltInProfiles.seed` 首次啟動複製（永不覆寫）；刪掉寫死 `gameId` 的死路徑（其註解「尚未有偵測機制」自 P1-d 起就已過期）。**但記載的「指標遊戲沒有可用 profile」查證後不成立**——Pixel Flow 是點擊／拖曳型，不需要 keymap，見設計文件 §1.3。**`.auto` 端到端仍無自動驗證**（範例 profile 不對應真實 package），已如實記入 §8 D | 實際約半天 | — |
```

- [ ] **Step 3: 更新 §8 A 節「內建 profile」那列**

在 §8 A 節（根本沒做）的表格中，「內建 profile 上架」那列的「實際」欄位末尾加上：

```
**✅ 已於 2026-07-29 實作（D4）**
```

- [ ] **Step 4: 在 §8 D 節補一筆**

在 §8 D 節既有段落之後、下一個標題之前，新增：

```markdown
**D4 新增的一筆（2026-07-29）**：`.auto` 自動啟用的端到端路徑
（seeding → 偵測命中 → `applyActivation` → `keymap?.reload`）**沒有任何自動驗證**。
不是被什麼擋住——是內建的只有 `com.example.game` 這份格式範例，不對應任何真實 App，
所以 `.auto` 永遠不會為它啟用。驗法見 `app/README.md` 的 P1-c 段。
`AppModel` 本身無法 hermetic 測試（債務 D13：光建構就有 8 個全域副作用），
所以這條在 D13 完成前只能手動驗。
```

- [ ] **Step 5: 逐項查證寫進去的宣稱**

Run:
```bash
cd /Users/hanfourhuang/Projects/mirage
grep -rn "com.loomgames.pixelflow" docs/specs/2026-07-28-phase1-game-recon.md | head -2
ls app/Sources/MirageCore/Resources/profiles/
grep -n "resources:" app/Package.swift
```
Expected: 三項都要與文件寫的相符。**任何一項對不上就改文件，不要改測試或碼去遷就文件。**

- [ ] **Step 6: 跑完整閘門**

Run: `cd app && ./scripts/ci.sh 2>&1 | tail -8`
Expected: 三道閘門全過、退出碼 0。

- [ ] **Step 7: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add app/README.md docs/specs/2026-07-29-project-review.md
git commit -m "docs: D4 完成，並更正「指標遊戲沒有 profile」這項記載

債務表 D4 標記完成，同時更正其中一項不成立的記載：Pixel Flow 是點擊／拖曳型遊戲，
不需要 keymap profile——滑鼠直接 tap 就是對的輸入模型，這也正是驗收線已經通過的原因。

README 明寫 com.example.game 是格式範例、不對應任何真實遊戲，並如實記載
「.auto 端到端沒有自動驗證」及其原因（範例 profile 不對應真實 package），
歸類為 §8 D 的第三類「可以驗了但沒人回頭驗」，附具體驗法。

不寫成 pending-human——那個措辭在本專案有六次前科。"
```

---

## Self-Review

**規格涵蓋**：設計 §1.1（資源進不了 bundle）→ Task 1；§1.2（死路徑）→ Task 4；
§1.3（Pixel Flow 不需要 profile）→ Task 5 的文件更正；§2 的 D-1～D-6 分別對應
Task 5／Task 1／Task 2／Task 2／Task 5／Task 4；§3.1 → Task 2+3；§3.2 → Task 1；
§3.3 → Task 4；§3.4（行為改變）→ Task 4 Step 2 的註解 ＋ Task 5 的 README；
§4（驗收切分）→ Task 5 Step 4；§4.1（未驗證假設的閘門）→ Task 1 全體；
§6 驗收條目 1–2 → Task 1–3，條目 3–4 → Task 2 的 `seedNeverOverwritesExisting`
與 `seedCopiesWhenAbsent`（暫存目錄等價驗證），條目 5 → 每個 task 的 ci.sh，
條目 6 → Task 4 Step 4。

**型別一致性**：`BuiltInProfiles.seed(into:from:) -> [String]` 在 Task 2 定義、
Task 3 測試、Task 4 呼叫，簽章一致。`BuiltInProfiles.bundledSources() -> [URL]` 在
Task 3 定義、Task 4 呼叫。`ProfileStore.standardDirectory() -> URL` 在 Task 3 定義、
Task 4 呼叫。`AppModel.seedBuiltInProfiles()` 在 Task 4 定義並在同 task 由
`MirageScene` 呼叫。

**順序相依**：Task 2 可與 Task 1 並行（純函式不依賴 bundle）；Task 3 必須在 Task 1、2
之後（要 bundle 資源與 `seed`）；Task 4 必須在 Task 3 之後；Task 5 最後。

**一個刻意的缺口**：Task 4 無單元測試（`AppModel` 在 D13 完成前無法 hermetic 測試）。
設計 §4 已記載，Task 5 會如實寫進文件。**不接受用「加間接層以便測試」來繞過**——
那會為了測試而改產品結構，而被測的三行本身不含判斷。
