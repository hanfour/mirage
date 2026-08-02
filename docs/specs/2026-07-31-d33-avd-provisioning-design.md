# D33：AVD provisioning 腳本 — 設計

**日期**：2026-07-31
**債務**：D33（`docs/specs/2026-07-29-project-review.md:131`）
**狀態**：設計已定案，尚未實作

---

## 0. 這份文件解決什麼

D33 記的是：**三台 AVD 是人手工建的，產品沒有一行碼能重現測試環境**。它讓 Phase-1
唯一通過的驗收線（「1 款指標遊戲開箱即玩」）站不住——那個 ✅ 的實際意思是「有人先幫你
把箱子拆好」。

D33 給了兩條出路。**(b) 已於 2026-07-30 完成**（§6 驗收表上的 ✅ 已標明前提，見 commit
`4c26b7e`）。這份文件是 **(a)**：一支冪等的 provisioning 腳本。

**這不是從零設計。** `docs/specs/2026-07-28-phase1-game-recon.md:132` 已經把整套手動程序
記下來並驗證過：直讀 Google 的 `sys-img2-3.xml` 取得 URL 與 SHA1 → `curl` → `unzip` 到
`system-images/` → 手寫 `.ini` 與 `config.ini` → `emulator -avd` 啟動成功。那份文件當時就
寫下「**這證明「下載映像 → 建立」可以做成不依賴 JDK 的產品功能**」。本設計是把那份已驗證
的程序編碼起來。

---

## 1. 為什麼不能用 `avdmanager`

**這台機器沒有 Java runtime。** `avdmanager` 與 `sdkmanager` 都在 PATH 裡（homebrew），
兩支都回：

```
/opt/homebrew/bin/avdmanager: line 173: test: : integer expression expected
The operation couldn’t be completed. Unable to locate a Java Runtime.
```

也就是說官方文件上「建 AVD 的標準方法」在此環境下**不可用**。這正是當初改用 curl + 手寫
`config.ini` 的原因，也是本設計刻意不引入 JDK 依賴的原因：多一個 JDK 依賴，就多一個新機器
上會卡住的地方，而 D33 要消除的就是「新機器到不了那個狀態」。

---

## 2. 範圍與邊界

### 做

1. 依 manifest 下載並安裝：`emulator`（stable 37.1.11）、`platform-tools`、兩份 android-35
   system image（`default` 與 `google_apis_playstore`，皆 arm64-v8a）。
2. 驗每個 zip 的 SHA-1（**checksum 由 Google 的 manifest 提供，不自己算、不寫死**）。
3. 產生兩台 AVD 的 `<name>.ini` 與 `<name>.avd/config.ini`。
4. 報告現況與規格的差異（漂移）。

### 不做

| 不做 | 為什麼 |
|---|---|
| Play Store 登入 | 需要 Google 帳號，**本質上不可自動化**。這是自動化的天花板。 |
| 安裝遊戲 | 同上；sideload 路線已有 `app/scripts/verify_apk_install.sh` 涵蓋。 |
| 安裝 JDK | 見 §1。引入它等於多一個新機器上的卡點。 |
| 刪除既有 AVD | 破壞性，且 `mirage-bench` 雖不再產出但既有量測記錄引用它。 |
| 啟動模擬器 | 那是 `verify_*.sh` 的事，不是 provisioning 的事。 |

**因此「開箱即玩」可自動化的邊界是「兩台一致的 AVD 可被重建」**，不是「開箱即玩」本身。
這條邊界已寫進 `docs/specs/2026-07-29-project-review.md` §6。

---

## 3. 已定的四個決策

brainstorming 產出，**不要重新討論**：

| # | 決策 | 理由 |
|---|---|---|
| 1 | **硬 pin stable 37.1.11**，不吃參數 | 可重現性是 D33 的全部目的，而只有 stable 會長期留在 manifest 上——canary 37.2.1 已經被刷掉了。換版必然留下 commit。順手關掉 D17。 |
| 2 | **收成兩台**：`mirage-poc`（default image）＋ `mirage-game`（playstore image），非映像設定完全一致 | 統一後 `mirage-bench` 與 `mirage-poc` 完全重複。兩台只差 system image，跨台的 fps 數字才可直接比較。 |
| 3 | **預設只讀**：不符只報告並 `exit 1`，要旗標才寫 | 「Never break userspace」。改 RAM 會讓既有快照失效，換 emulator 影響整台機器的所有量測。 |
| 4 | **Python，純邏輯與 I/O 分層** | 純函式可餵 fixture 離線測，不必為了測一行改動而下載 GB。 |

---

## 4. Pin 什麼、以及 manifest 漂移怎麼辦

### 4.1 三份 manifest

| Package | Manifest URL | zip 的 base |
|---|---|---|
| `emulator`、`platform-tools` | `https://dl.google.com/android/repository/repository2-3.xml` | 同層 |
| `system-images;android-35;default;arm64-v8a` | `https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml` | 同層 |
| `system-images;android-35;google_apis_playstore;arm64-v8a` | `https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml` | 同層 |

zip 的 `<url>` 是**相對於該 manifest 所在目錄**的。三條都已實測 HTTP 200。

### 4.2 pin 的內容（2026-07-31 由 manifest 取得）

| Package | Revision | zip | SHA-1 | Size |
|---|---|---|---|---|
| `emulator`（stable，macosx/aarch64） | 37.1.11（build 15917651） | `emulator-darwin_aarch64-15917651.zip` | `f22f44948a2b7f0a0103645b9a639290eef92426` | 394,555,844 |
| `platform-tools`（stable，macosx） | 37.0.1 | `platform-tools_r37.0.1-darwin.zip` | `6ae73f4de6452dc57e62ec02b68eed92a4c21661` | 16,110,554 |
| `system-images;android-35;default;arm64-v8a` | 2 | `arm64-v8a-35_r02.zip` | `2026a06409db630b56711afdbffb457c1dbaed49` | 769,099,654 |
| `system-images;android-35;google_apis_playstore;arm64-v8a` | 9 | `arm64-v8a-35_r09.zip` | `b01416bc0bca12a85295dad179f9b8a1cae3d1e6` | 1,789,211,399 |

### 4.3 規則：manifest 給的與 pin 的不同就報錯，不默默用新的

**這是本設計最重要的一條規則。**

manifest 對每個 package path 只提供**當下最新的一個 revision**。Google 一旦 bump，pin 的
版本就從 manifest 上消失——canary 37.2.1 就是這樣沒的（直連網址仍回 200，但已不在清單上、
沒有官方 checksum）。

所以腳本記下期望的 `(path, revision, sha1)`；解析 manifest 後：

- **完全相符** → 照常進行。
- **manifest 提供了不同的 revision** → **明確報錯並中止**，訊息要說清楚「pin 的是 X、
  manifest 現在是 Y，請確認要不要升版並更新 `versions.py`，這是一個需要 commit 的決定」。
- **checksum 對不上下載的檔案** → 中止，刪掉半成品，不留下壞檔案。

**絕對不可以**在 manifest 前進時默默改用新版——那會讓「同一份 commit 在不同日子跑出不同
環境」，正是 D33 要消滅的病。

**副作用（刻意的）**：這會讓腳本在 Google 每次 bump 後主動壞掉一次。那是特性不是 bug：
它把「環境變了」這件事變成一個必須有人做決定、且留下 commit 的事件。

---

## 5. 資料流

```
三份 manifest XML ──► PackageRef(path, revision, url, sha1, size)
                              │
                              ├─ 與 pin 比對 ──► 不符即中止（§4.3）
                              │
                              ▼
                        下載計畫（哪些缺、哪些已在）
                              │
                        curl ─┴─► 驗 SHA-1 ─► unzip 進 SDK

AvdSpec（純資料，兩台）──► render ──► config.ini 期望文字 ─┐
                                                            ├─► DriftReport
既有 <name>.avd/config.ini ──► parse ──────────────────────┘
                                                            │
                                          報告（預設）／寫入（--apply）
```

---

## 6. 檔案結構

```
tools/provision/
  lib/__init__.py
  lib/versions.py      pin 的 (path, revision, sha1, size)，§4.2 那張表
  lib/manifest.py      XML → PackageRef；與 pin 比對
  lib/sdkpaths.py      SDK 與 AVD 目錄解析
  lib/avdspec.py       兩台的規格（純資料）
  lib/config_ini.py    AvdSpec → config.ini 文字；也 parse 既有的
  lib/drift.py         現況 vs 期望 → 差異清單
  fetch.py             唯一碰網路與磁碟的模組
  provision.py         CLI 入口
  tests/               unittest，離線，fixture XML
  tests/fixtures/      三份 manifest 的截短樣本
```

**職責邊界**：`lib/` 底下**全部是純函式**——輸入資料、輸出資料，不碰網路、不碰磁碟、
不讀環境變數（環境變數由 `sdkpaths` 以參數形式接收）。`fetch.py` 是唯一有副作用的模組。
這條邊界就是「不下載 GB 也能測」的機制，也是每個模組能被獨立理解與測試的原因。

檔案大小預期都在 100–200 行以內。

---

## 7. 兩台 AVD 的規格

### 7.1 共用（base）

以現有 `mirage-game.avd/config.ini` 的 139 行為底（那是三台裡最乾淨的一份），扣掉 §7.2
的每台差異欄位。關鍵值：

```
hw.gpu.enabled = yes          hw.gpu.mode = host
hw.ramSize = 4096             hw.cpu.ncore = 4
hw.keyboard = yes             hw.keyboard.charmap = qwerty2
hw.lcd.width = 1080           hw.lcd.height = 2400      hw.lcd.density = 420
disk.dataPartition.size = 8589934592
abi.type = arm64-v8a          hw.cpu.arch = arm64
hw.device.name = pixel_7      hw.device.manufacturer = Google
target = android-35
```

其餘（感測器、多螢幕、gltransport、fastboot 等）原樣沿用。

### 7.2 每台的 overlay（僅 8 個欄位）

| 欄位 | `mirage-poc` | `mirage-game` |
|---|---|---|
| `avd.id` / `avd.name` | `mirage-poc` | `mirage-game` |
| `image.sysdir.1` | `system-images/android-35/default/arm64-v8a/` | `system-images/android-35/google_apis_playstore/arm64-v8a/` |
| `PlayStore.enabled` | `no` | `yes` |
| `tag.id` / `tag.ids` | `default` | `google_apis_playstore` |
| `tag.display` / `tag.displaynames` | `Default Android System Image` | `Google Play` |

### 7.3 **不從現有 config.ini 複製**

現有 `mirage-poc.avd/config.ini` 帶著字面上的未取代佔位符：

```
avd.id = <build>
avd.name = <build>
disk.dataPartition.path = <temp>
```

它照樣能跑，但那是手工來源的疤痕。複製它等於把疤痕永久化。base 模板進 git，由腳本產生。

### 7.4 `.ini` 指標檔

```
avd.ini.encoding=UTF-8
path=<AVD_HOME>/<name>.avd
path.rel=avd/<name>.avd
target=android-35
```

`path` 是**絕對路徑**，所以這個檔一定要產生、不能複製——這也是為什麼 provisioning 天生
就得是腳本而非「把目錄壓起來給別人」。

### 7.5 userdata 由誰建

不由腳本建。`emulator` 首次啟動時會依 `disk.dataPartition.size` 從 system image 產生
`userdata-qemu.img`。腳本只負責 `.ini` 與 `config.ini`。

---

## 8. CLI 行為

```
provision.py [--apply] [--upgrade] [--sdk-root PATH] [--avd-home PATH]
```

| 情況 | 預設（無旗標） | `--apply` | `--upgrade` |
|---|---|---|---|
| SDK package 缺失 | **直接安裝**（無破壞風險） | 同左 | 同左 |
| AVD 不存在 | **直接建立**（無破壞風險） | 同左 | 同左 |
| AVD 已存在但 `config.ini` 不符 | 報告，不寫 | **覆寫** | 報告 |
| SDK package 版本不符 | 報告，不寫 | 報告 | **覆蓋安裝** |

**兩個旗標分開的理由**：改 `config.ini` 的 RAM 會讓既有快照失效（這台機器的
`mirage-poc` 有 `mirage_suspend` 快照）；換 emulator 則影響整台機器上所有已量測的數字。
兩者的後果不同級，不該由同一個旗標決定。

**退出碼**：`0` = 跑完之後**沒有任何未解決的漂移**；`1` = 仍有漂移（含「給了 `--apply`
修好了 AVD、但 SDK 的漂移因為沒給 `--upgrade` 而還在」這種情況）；`2` = 錯誤（網路、
checksum、manifest 漂移）。

換句話說 `0` 的意思一律是「現況等於規格」，與給了哪些旗標無關。

**冪等**：`--apply --upgrade` 跑完後，再跑一次不帶旗標應該全 ✓ 且 `exit 0`。這是驗收條件。

### 8.1 輸出樣貌

```
SDK: /Users/hanfourhuang/Library/Android/sdk
  emulator          37.2.1     ≠ 37.1.11    ✗ 漂移（--upgrade 可更新）
  platform-tools    37.0.0     ≠ 37.0.1     ✗ 漂移（--upgrade 可更新）
  sysimg default    r02        = r02        ✓
  sysimg playstore  (無 package.xml，無從追溯)  ✗ 需重裝（--upgrade）
AVD: /Users/hanfourhuang/.android/avd
  mirage-poc        hw.ramSize 2G ≠ 4096    ✗ 漂移（--apply 可修正）
                    hw.gpu.enabled no ≠ yes ✗
                    avd.name <build> ≠ mirage-poc ✗
  mirage-game       ✓
```

---

## 9. 錯誤處理

| 失敗 | 行為 |
|---|---|
| manifest 抓不到（網路） | 中止，`exit 2`，訊息含 URL 與 HTTP 狀態 |
| manifest 的 revision ≠ pin | 中止，`exit 2`，訊息說明這是需要 commit 的決定（§4.3） |
| SHA-1 不符 | **刪掉下載的檔案**再中止，不留壞檔 |
| 解壓失敗 | 中止；解壓一律先進暫存目錄，成功後才 move 到位（不留半解壓的目錄） |
| 磁碟空間不足 | 下載前先估算所需空間（manifest 有 size），不足就先報 |
| SDK 路徑不存在 | 建立它——這正是新機器的情境 |

**`--upgrade` 的覆蓋語意**：先把舊目錄 move 到 `<name>.old-<revision>`，解壓新的到位，
成功後才刪掉舊的。中途失敗則把舊的 move 回來——**任何時刻都必須有一份可用的**。

**`mirage-bench` 不在腳本的認知範圍內**：不產出、不報告、不動它。既有的留著（量測記錄
`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §13.2 引用了它）。

**原則**：任何中止都不可以留下「看起來裝好了但其實壞掉」的狀態。半成品一律清掉。

---

## 10. 測試策略

### 10.1 離線單元測試（不下載任何東西）

| 模組 | 測什麼 |
|---|---|
| `manifest.py` | 餵 fixture XML → 正確的 `PackageRef`；channel 過濾；相對 URL 組成絕對 URL；revision 與 pin 不符時拋錯 |
| `config_ini.py` | `AvdSpec` → 文字的 round-trip（render 後 parse 回來要等值）；欄位排序穩定；兩台的 overlay 正確 |
| `drift.py` | 相同 → 空清單；單欄位差異 → 只報那一欄；缺欄位／多欄位；`<build>` 佔位符要被判為漂移 |
| `sdkpaths.py` | `ANDROID_SDK_ROOT` > `ANDROID_HOME` > 預設的優先序；`ANDROID_AVD_HOME` |
| `versions.py` | pin 表的結構完整（每筆都有 path/revision/sha1/size） |

fixture 是三份真 manifest 的**截短樣本**（只留相關 package），放 `tests/fixtures/`。

### 10.2 一次性的真下載驗證

用 `platform-tools`（16MB，四個 package 裡最小）做一次端到端：解析 → 下載 → 驗 SHA-1 →
解壓 → 比對。**不把 GB 級下載放進任何自動化流程。**

### 10.3 `ci.sh` 閘門 6

**新增一道閘門跑 `tools/provision/tests/` 的 unittest**（精確範圍：只有這個目錄，不含
`tools/probe/tests/`——理由見下）。

理由不是形式：`tools/probe/tests/` 有 13 個測試檔全部用 pytest，而**這台機器根本沒裝
pytest**（`python3 -m pytest` → `No module named pytest`），也沒有任何腳本或 CI 步驟會跑
它們。那 13 個檔案現在是死的。照抄同一個結構等於再寫一批沒人跑的測試。

所以：**用 `unittest`（Python 內建，零依賴）而非 pytest**，並加閘門讓它真的會紅。
閘門加上去之後要用故障注入證明會紅（本專案的既有規矩，見 `ci.sh` 閘門 4 與 5 的註解）。

---

## 11. 不在本次範圍的側面發現（記債）

實地查證時挖到三件，各自獨立於本設計：

1. **`tools/probe/tests/` 的 13 個測試檔從未被跑過。** 用 pytest，但 pytest 沒裝、
   沒有 requirements、沒有入口、不在 ci.sh 裡。與 D3（假 skip）同一族：**存在但不執行的
   測試比沒有測試更糟**，因為它讓人以為有涵蓋。（§10.3 的閘門 6 只跑 `tools/provision/`
   的 unittest，不會順帶救活它們。）
2. **`mirage-poc.avd/config.ini` 帶未取代的範本佔位符**（`<build>`、`<temp>`）。本設計
   會在 `--apply` 時修正，但這筆本身值得記錄為「手工環境的具體證據」。
3. **stable 已從 36.6.11 跳到 37.1.11，build 15917651 比我們在跑的 canary 37.2.1
   （15875889）還新。** MMAP transport 那筆記載的「等含上游修正的 build 發布」——當時
   manifest 上 aarch64 只有 37.2.1(canary)／37.1.10(beta)／36.6.11(stable)——**前提可能
   已經成立**。這正是「阻礙已消失但沒人回頭驗」那一類，值得回頭跑一次
   `app/scripts/verify_mmap.sh`。
