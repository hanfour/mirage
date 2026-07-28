# Phase-1 指標遊戲偵察記錄

- **日期**：2026-07-28
- **目的**：在投入「3 款指標遊戲開箱即玩」的實作前，先確認三款遊戲在現有環境下**跑不跑得起來**
- **結論**：驗收線自 3 款下修為 1 款（母計畫 §7 已修訂）

## 0. 為什麼先偵察

這個專案剛在 MMAP 上付過一次學費：Phase-0 用 Python 探測腳本斷定「明確帶 width/height 即可繞過上游 bug」，據此把 MMAP 排進計畫——結果那個結論**只對 Python client 成立**，產品的 Swift client 在同樣條件下凍結，整輪工作最後以「預設關閉」收場（見 `app/RESULTS-mmap.md`）。

教訓是：**投入前先用產品真正會遇到的條件探測一次。** 本次偵察成本約半天，若略過，代價是先建完整套基礎設施才發現兩款遊戲根本進不去。

## 1. 方法與界線

全部在**現有的共享模擬器**（`emulator-5554`，AVD `mirage-poc`）上以唯讀方式進行，未建立新 AVD、未下載映像、未安裝任何遊戲。

**本次沒有做、也不該由自動化代理做的事**：Play Store 需要 Google 帳號登入，那一步屬於使用者。因此「Pokémon TCG Pocket 實際能否安裝並執行」**至今未驗證**（見 §6）。

## 2. F1：磁碟是第一道硬牆（實測）

```
$ df -h ~
可用 9.0 GiB（95% 已滿）
```

Play Store arm64 映像的下載量（直讀 Google 的 `sys-img2-3.xml`，免 Java）：

| 映像 | 下載量 |
|---|---|
| `system-images;android-37.0;google_apis_playstore;arm64-v8a` | 2.10 GB |
| `system-images;android-36.1;google_apis_playstore_ps16k;arm64-v8a` | 1.88 GB |

解開後佔用更大。建完新 AVD 後大約剩 5 GB。

可回收空間（實測）：

| 項目 | 大小 | 備註 |
|---|---|---|
| `app/.build` | 2.1 G | 隨時可重建 |
| `phase0/`（venv、gen） | 1.9 G | 部分可重建 |
| 現有 AOSP 映像 | 1.6 G | **不可刪**——共享模擬器在用 |

全清也僅能到 13 GB 上下。

**判定**：點擊型遊戲塞得下；MOBA 很緊；**3D 大作的安裝量級遠超此數字**。

> ⚠️ 最後一句是依公開規格判斷，**未實測**。但差距不是「再清一點就好」的等級。

## 3. F2：反模擬器指紋全裸（實測，決定性）

```
$ adb shell getprop <各項>
ro.kernel.qemu             1
ro.boot.qemu               1
ro.build.characteristics   emulator
ro.hardware                ranchu
ro.product.model           Android SDK built for arm64
ro.product.manufacturer    unknown
ro.product.device          emu64a
ro.build.fingerprint       Android/sdk_phone64_arm64/emu64a:15/AE3A.240806.019/12368160:userdebug/test-keys
```

老派的檔案痕跡**不在**（新版 ranchu 已換機制）：

```
/dev/socket/qemud                      無
/dev/qemu_pipe                         無
/system/lib/libc_malloc_debug_qemu.so  無
```

**判定**：property 層面完全沒有遮掩。`ro.kernel.qemu=1` 是反作弊的第一個檢查點，`ro.build.characteristics` 字面上就寫著 `emulator`。

要繞過需做 build.prop 層級的裝置識別調校——母計畫 §8 R2 已明定**那是 Phase 2 的工作**，且明確不做核心層反偵測軍備競賽。

### 3.1 更正：上述指紋量自 AOSP 映像，Play Store 映像明顯較好（同日稍後實測）

本節原本寫下「帶反作弊的遊戲會在啟動的前幾秒擋下——**這不是機率問題**」。**那句話下得太重，依據不足**：它量的是 AOSP（`default` tag）映像，而 Phase-1 實際要用的是 Play Store 映像。建立 `mirage-game` AVD（`android-35;google_apis_playstore;arm64-v8a`）後重量，差異是實質的：

| property | AOSP 映像 | Play Store 映像 |
|---|---|---|
| `ro.build.tags` | `test-keys` | **`release-keys`** |
| `ro.build.flavor` | `sdk_phone64_arm64-**userdebug**` | `sdk_gphone64_arm64-**user**` |
| `ro.product.manufacturer` | `unknown` | **`Google`** |
| `ro.build.fingerprint` | `Android/sdk_phone64_arm64/…:userdebug/test-keys` | `google/sdk_gphone64_arm64/emu64a:15/AE3A.240806.036/12592187:user/release-keys` |
| `ro.kernel.qemu` | `1` | `1`（未變） |
| `ro.boot.qemu` | `1` | `1`（未變） |
| `ro.build.characteristics` | `emulator` | `emulator`（未變） |
| `ro.hardware` | `ranchu` | `ranchu`（未變） |
| `ro.product.model` | `Android SDK built for arm64` | `sdk_gphone64_arm64`（仍寫著 sdk） |

`test-keys` → `release-keys` 與 `userdebug` → `user` 這兩項改變了 Play Integrity 的前提——Google 的 Play Store 模擬器映像本就是 Play 認證過的。**所以「必然被擋」這個結論不成立。**

修正後的判定：
- **直接讀 property 的反作弊**（檢查 `ro.kernel.qemu`／`ro.hardware`／`ro.build.characteristics`）——仍然一驗就中，這幾項在 Play Store 映像上完全沒變。多數重度反作弊屬此類。
- **靠 Play Integrity 判定的**——basic integrity 有機會通過，device integrity 不會。實際結果取決於個別遊戲要求哪一級。

**這不改變「驗收線縮為 1 款」的決定**（磁碟對 3D 大作仍是硬牆，直接讀 property 的反作弊仍然擋得住），但**確定性的措辭要收回**：哪些遊戲會被擋，是要逐款實測的事，不是能從這組 property 推導出來的。

方法論教訓與 §0 同源：**探測條件必須與產品實際會用的一致。** 我用 AOSP 映像量指紋、卻對 Play Store 映像下結論，犯的是跟 Phase-0 MMAP 那次同一類的錯。

## 4. F3：`sdkmanager` 目前不可用，且這影響 Phase-1 的設計（實測）

```
$ sdkmanager --list
Unable to locate a Java Runtime.
```

本機未安裝 Android Studio，亦無可用的 JDK。

短期可用 `curl` 直抓映像 zip 繞過。**但長期更重要**：母計畫 Phase-1 第一項要求「下載映像 → 建立」做進產品（目前只有 `phase0/scripts/01_create_avd.sh`，未進產品）。若產品打算包 `sdkmanager`，就會**繼承 JDK 依賴**——對一個「開箱即玩」的消費級 App 而言，要求使用者先裝 JDK 不可接受。

好消息是免 Java 的路徑已在本次偵察中被證明可行：直讀 `https://dl.google.com/android/repository/sys-img/.../sys-img2-3.xml` 即可取得完整映像清單與大小。

## 5. 對驗收線的影響

原驗收線把**「我們的軟體行不行」跟「別人讓不讓我們跑」綁在同一個閘門上**。鍵位引擎、串流、輸入注入可能全都正確，驗收卻因反作弊而不過——那不是在量本專案的工程品質。

母計畫 §7 已修訂：Phase 1 驗 1 款點擊型遊戲；MOBA 與 3D 大作移入 Phase 2，與裝置識別調校同批驗（兩者成敗本就綁在一起）。

## 5.1 已建立的偵察環境（2026-07-28）

為封死 §6 的最後一個未知，已建立**第二台**模擬器，不影響共享的 `emulator-5554`：

| 項目 | 值 |
|---|---|
| AVD | `mirage-game`（`~/.android/avd/mirage-game.avd`） |
| 映像 | `system-images;android-35;google_apis_playstore;arm64-v8a`（1.67 GB 下載、2.2 GB 解開，SHA1 已驗） |
| 裝置 | `emulator-5556`，gRPC `8556` |
| 規格 | RAM 4096 MB、data partition 8 GB（實測 `/data` 7.7 G，可用 6.9 G）、`hw.gpu.mode = host`、`PlayStore.enabled = yes`、device profile `pixel_7` |
| Play Store | ✅ `com.android.vending`、`com.google.android.gms`、`com.google.android.gsf` 皆在 |

**建立方式全程未用 `sdkmanager`／`avdmanager`（見 F3）**：直讀 Google 的 `sys-img2-3.xml` 取得 URL 與 SHA1 → `curl` → `unzip` 到 `system-images/` → 手寫 `mirage-game.ini` 與 `config.ini`（以既有 AVD 的 config 為範本）→ `emulator -avd`。**這證明 Phase-1 那段「下載映像 → 建立」可以做成不依賴 JDK 的產品功能。**

啟動指令：

```bash
~/Library/Android/sdk/emulator/emulator -avd mirage-game -port 5556 -grpc 8556 -gpu host
```

## 5.2 三款實測結果（2026-07-28，使用者登入 Play Store 後）

**偵察的核心問題「點擊型遊戲跑不跑得起來」已回答：可以。**

| 遊戲 | 套件 | 引擎 | 結果 |
|---|---|---|---|
| **Pixel Flow** | `com.loomgames.pixelflow` | Unity | ✅ **可遊玩**（RSS 115 MB） |
| Pikmin Bloom | `com.nianticlabs.pikmin` | Unity | 畫面停住（非崩潰） |
| Pokémon TCG Pocket | `jp.pokemon.pokemontcgp` | Unity | ❌ 確定性 SIGSEGV |

**三款皆為 Unity，其中一款可玩** → Unity 在此模擬器上無普遍性問題；TCG Pocket 的崩潰是該遊戲特有的。

### TCG Pocket 崩潰（根因未確立，且刻意不再往下追）

崩潰前它其實跑得很好：`Fully drawn +3s857ms`，且 `exportSyncFdForQSRILocked` 每 ~16.6 ms 一次（20 幀 / 0.315 s）——**約 60 fps**。Vulkan（`Created VkDevice … ASTC emulation:on`）、音訊、網路 HTTP handler 皆正常載入。

崩潰形態：

```
pc = lr = x8 = 0x00102d66'37a429e0
Fault address falls at 00102d66'37a429e0 after any mapped regions
2 total frames，皆 <unknown>（無符號）
```

正常指標全在 `0x73`–`0x79` 開頭。兩次獨立執行（pid 8829 / 9152）的 `x9 = 0x2359`、`x15 = 0xffffd52a`、`x17 = 0x791a29fbc0` **完全相同**——**確定性路徑，非隨機記憶體損毀**。

**停止追查的理由**：再往下就是分析該遊戲被剝除符號的保護機制；若根因是完整性檢查，「修好」等同繞過它。母計畫 §8 R2 明定「不做核心層反偵測軍備競賽」。**且不得宣稱這是反作弊**——系統中 SafetyNet 服務的綁定／解綁時間點與兩次崩潰對不上，無證據可歸因。

### Pikmin Bloom 畫面停住（根因未查，非目標）

已確立的事實：行程存活、`UnityGfxDeviceW` 20% CPU、`UnityMain` 10% CPU，但 **3 秒內 0 次 present**。無 ANR、無 OOM kill。GPS 有 fix（預設的 37.421998,-122.084000）。

**排除了記憶體**：guest 顯示 3633/3920 MB used 看似吃緊，但 `top` 顯示其中 1.86 GB 是 page cache，非壓力。Pikmin RSS 僅 625 MB。

### 觸控板的畫面亂跳

模擬器自身的 Qt UI 把觸控板多指手勢當成多點觸控，log 中大量 `skipping QEventPoint … no target window`。與閃退無關。

**這一項有產品意涵**：那正是 Mirage 要取代的東西——用原生 macOS 前端與正確的輸入映射取代模擬器自己的 UI（母計畫 §4.1）。

## 6. 尚未驗證，且需要使用者參與

1. ~~**Pokémon TCG Pocket 是否真能在 Play Store 映像上安裝並執行**~~ — **已驗（見 §5.2）**：可安裝，但啟動約 12–32 秒後確定性崩潰。改以 **Pixel Flow** 作為 Phase-1 的點擊型指標遊戲候選。
2. 新 AVD 在 `-gpu host` 下的實際 fps 表現（現有 AVD 的 `config.ini` 是 `hw.gpu.enabled = no`，但執行中的行程帶 `-gpu host` 覆蓋）。
3. 現有 AVD 規格 `hw.ramSize = 2G` / data partition 6 GB 是否足夠——建新 AVD 時應重新設定。

## 6.1 偵察之後發現的前置阻礙（2026-07-28 同日）

本文件的結論（點擊型遊戲可跑、模擬器能以 46–59 fps 串流）**仍然成立**——那些量的是模擬器
與環境，用的是 Python harness，不經過 Mirage。

但接著要量「Mirage 顯示遊戲時的 fps」時發現：**Mirage 的鏡像顯示自 P1-a 起從未運作過**。
連線成功、幀確實進來，但狀態傳不到 UI（橫幅顯示「未連線」）、畫面全黑，且在有真實合成視窗
的環境會 SIGSEGV。`fps=` 恆為 0 先前被歸因於螢幕鎖定，該歸因已被推翻。

→ **Phase-1 驗收線 1（60fps 穩定）在修好那個問題之前無法量。**
完整證據與已推翻的六個假設見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md`。

## 7. 相關文件

- 母計畫：`docs/specs/2026-07-22-mirage-project-plan.md` §7（已修訂）、§8 R2
- MMAP 的同類教訓：`app/RESULTS-mmap.md`
- App 層可測性現況：`app/RESULTS-shell-target.md`
