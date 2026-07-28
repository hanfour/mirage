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

**判定**：property 層面完全沒有遮掩。`ro.kernel.qemu=1` 是反作弊的第一個檢查點，`ro.build.characteristics` 字面上就寫著 `emulator`。帶反作弊的遊戲會在啟動的前幾秒擋下——**這不是機率問題，是這組 property 的必然結果**。

`test-keys` 簽章加上 `ro.kernel.qemu=1`，Play Integrity 亦不可能給出 device integrity 判定。

要繞過需做 build.prop 層級的裝置識別調校——母計畫 §8 R2 已明定**那是 Phase 2 的工作**，且明確不做核心層反偵測軍備競賽。

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

## 6. 尚未驗證，且需要使用者參與

1. **Pokémon TCG Pocket 是否真能在 Play Store 映像上安裝並執行**——需 Google 帳號登入，屬使用者的步驟。點擊型遊戲通常不掛重度反作弊，但**本次未驗證**，不得當作已知事實。
2. 新 AVD 在 `-gpu host` 下的實際 fps 表現（現有 AVD 的 `config.ini` 是 `hw.gpu.enabled = no`，但執行中的行程帶 `-gpu host` 覆蓋）。
3. 現有 AVD 規格 `hw.ramSize = 2G` / data partition 6 GB 是否足夠——建新 AVD 時應重新設定。

## 7. 相關文件

- 母計畫：`docs/specs/2026-07-22-mirage-project-plan.md` §7（已修訂）、§8 R2
- MMAP 的同類教訓：`app/RESULTS-mmap.md`
- App 層可測性現況：`app/RESULTS-shell-target.md`
