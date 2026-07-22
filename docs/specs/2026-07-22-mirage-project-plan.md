# Mirage 專案計畫 — macOS 原生 Android 遊戲模擬器

- **日期**：2026-07-22
- **狀態**：草案（待核准）
- **專案代號**：Mirage（取「鏡像」之意，正式名稱另議）
- **團隊規模**：1–2 人
- **目標平台**：macOS on Apple Silicon（M1 以上），不支援 Intel Mac

---

## 1. 願景與定位

**一句話說清楚**：做一台「住在 Mac 裡的 Android 遊戲手機」。

體驗對標 macOS Sequoia 的 **iPhone 鏡像輸出（iPhone Mirroring）**：
點開就是一個乾淨的原生視窗，低延遲、鍵鼠直控、剪貼簿互通、拖放安裝，
用起來不像「開了一個模擬器」，而像 Mac 本來就會跑 Android。

**目標用戶**：在 Mac 上玩手遊的玩家。優先順序依序為——

1. 遊戲相容性與幀率
2. 鍵位映射體驗
3. Mac 原生整合感

開發者用途（adb、多版本 Android、CI）**不是**本專案的目標。核心本來就是官方
emulator，開發者功能免費附送，但我們一行力氣都不為它花。

---

## 2. 巨人解剖：三個競品的優點與缺點

> 站在巨人的肩膀上的前提，是先搞清楚巨人哪裡壯、哪裡瘸。
> 以下為 2026-07 查證的現況（來源見附錄）。

### 2.1 MuMu 模擬器 Pro（網易）

Apple Silicon 專屬的付費安卓模擬器，Mac 平台效能標竿。

| 優點（我們要學的） | 缺點（我們要避的） |
|---|---|
| Apple Silicon 原生，啟動快（宣稱 3 秒）、記憶體佔用低 | **訂閱制付費**（30/90/365 天會員，7 天試用），玩家有價格門檻 |
| 獨家圖形技術，最高 240fps、4K 畫質 | 簡中封閉生態，需網易帳號，台灣玩家有疑慮 |
| 智慧鍵鼠方案成熟，支援主流手把 | 閉源、遙測不透明 |
| 多開且各實例可獨立配置 | 僅服務中國市場遊戲優化為主 |

**結論**：MuMu Pro 證明了「Apple Silicon 原生 + 高幀率」在 Mac 上做得到，
效能天花板就在那裡。它的弱點不是技術，是**商業模式與生態封閉**。

### 2.2 BlueStacks Air

2024 年推出、2025 年轉正式版的免費 Mac 模擬器，主打「暢玩主流遊戲」。

| 優點（我們要學的） | 缺點（我們要避的） |
|---|---|
| **免費**，玩家零門檻 | 靠廣告與遊戲推廣變現，介面夾帶推銷 |
| 遊戲相容性資料庫深厚（原神、崩鐵、Pokémon TCG Pocket 等數百款逐一驗證） | 包袱重：首次啟動慢、整體臃腫 |
| 正式版支援 Vulkan，渲染品質提升 | 曾在 macOS 大版本更新後長時間掉幀（macOS 26 低 FPS 問題） |
| 多開管理器、手把、Retina、全螢幕優化、Mission Control 整合 | 「像 Windows 軟體移植來的」，非 Mac 原生質感 |

**結論**：BlueStacks Air 證明了「免費 + 相容性清單」是玩家買單的組合。
它的弱點是**臃腫與非原生感**——這正是我們的主攻面。

### 2.3 Android Studio 官方 AVD（AOSP Emulator）

Google 官方模擬器，開源（AOSP），全世界 Android 開發的基礎設施。

| 優點（我們要拿的） | 缺點（我們要補的） |
|---|---|
| **開源**，可 fork、可深度客製 | UI 是工程師審美，對玩家不可用 |
| Apple Silicon 上跑 ARM64 映像 = 近乎裸機速度（QEMU + Hypervisor.framework） | 零遊戲功能：無鍵位映射、無遊戲庫、無多開管理 |
| GPU 直通（gfxstream → 主機 GPU），圖形路徑成熟 | 不做模擬器偽裝，部分遊戲直接偵測拒跑 |
| **內建 gRPC 控制介面**：headless 執行、串流畫面（streamScreenshot）、注入輸入、同步剪貼簿——Android Studio 的嵌入式模擬器視窗就是靠這條路 | Play 映像授權限制，不可隨產品再散布 |
| Google 持續維護：新 Android 版本、安全更新、bug 修復全部免費 | 預設參數保守，未針對遊戲調校 |

**結論**：這是唯一開源的巨人，而且 Google 已經替我們把「headless 核心 +
串流介面」鋪好了。**核心用它，一行虛擬化程式碼都不必自己寫。**

### 2.4 交叉結論：我們的配方

```
核心正確性與效能地基  ← AVD（開源核心，Google 維護）
效能與幀率的標竿      ← MuMu Pro（證明 Mac 上做得到，我們照著打）
免費 + 相容性清單策略 ← BlueStacks Air（商業與營運思路）
Mac 原生鏡像體驗      ← 三家都沒有。這是我們的差異化，全部火力灌在這裡。
```

---

## 3. 核心洞察

**Bad programmers worry about the code. Good programmers worry about data structures.**
這個專案的關鍵資料流只有兩條：

1. **畫面流**：Guest GPU 畫格 → 主機 → Metal 呈現到視窗
2. **輸入流**：NSEvent（鍵鼠）→ 映射轉譯 → 注入 Guest 觸控/按鍵

商業模擬器 90% 的工程量在虛擬化核心，但那部分 Google 已經開源做完了。
剩下的 10%——這兩條流的延遲與品味——就是整個產品。
兩個人做 10%，可行；兩個人做 100%，自殺。

**架構的鐵律**：核心（GPL 開源義務）與殼（我們的商業資產）必須是
**兩個獨立行程**，只透過 gRPC 通訊。這不只是授權防火牆，也是故障隔離
——核心崩潰時殼還活著，能重啟核心、能回報錯誤，而不是整個 App 陪葬。

---

## 4. 系統架構

```
┌─────────────────────────────────────────────────┐
│  Mirage.app（SwiftUI + Metal，閉源，我們的資產）    │
│                                                 │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐  │
│  │ 鏡像視窗   │ │ 鍵位映射   │ │ 遊戲庫/設定    │  │
│  │ Metal 渲染 │ │ 引擎      │ │ 實例生命週期   │  │
│  └─────┬─────┘ └─────┬─────┘ └───────┬───────┘  │
│        │             │               │          │
│  ┌─────┴─────────────┴───────────────┴───────┐  │
│  │        EmulatorClient（gRPC 封裝層）        │  │
│  └────────────────────┬──────────────────────┘  │
└───────────────────────┼─────────────────────────┘
                        │ gRPC（localhost）
                        │ 畫面串流 / 輸入注入 / 剪貼簿 / 生命週期
┌───────────────────────┼─────────────────────────┐
│  mirage-core（AOSP emulator fork，headless，開源）│
│                                                 │
│  QEMU + Hypervisor.framework（ARM64 原生虛擬化）  │
│  gfxstream（Guest GPU 指令 → 主機 Metal/ANGLE）   │
│  AOSP 系統映像（ARM64，遊戲導向調校）              │
└─────────────────────────────────────────────────┘
```

### 4.1 元件職責

**mirage-core（AOSP emulator fork）**
- 職責：虛擬化、Android 執行、GPU 轉譯、gRPC 服務端
- 維護策略：**最小 patch set**。只改三類東西——
  1. 遊戲導向預設參數（記憶體、CPU 核數、GPU 模式、幀率上限）
  2. 裝置識別調整（build.prop 層級，Phase 2 之後才碰）
  3. 串流路徑優化（僅在 Phase 0 實測不達標時）
- 每個 patch 必須有一行理由。patch 越少，跟上游同步越便宜。
- 授權：QEMU 部分為 GPLv2，修改處依約開源（公開 repo）；gfxstream 為
  Apache-2.0。這是義務，不是選項。

**Mirage.app（Swift 原生殼）**
- `MirrorWindow`：Metal 渲染串流畫格。視窗可自由縮放，維持裝置長寬比，
  Retina 對齊。全螢幕 = 遊戲模式（隱藏所有 chrome）。
- `KeymapEngine`：見第 6 節。
- `EmulatorClient`：gRPC 的唯一封裝點。殼內任何元件不得直接碰 gRPC
  ——介面收窄，之後底層換傳輸方式（如共享記憶體）殼不用重寫。
- `InstanceManager`：核心行程的生命週期（啟動、監看、崩潰重啟、關機快照）。
- `Library`：已安裝遊戲清單、每遊戲設定檔、APK 拖放安裝。

### 4.2 資料流與延遲預算

輸入到光子（input-to-photon）總預算：**目標 < 50ms，上限 80ms**。
超過 80ms，玩家會說「這是模擬器」；50ms 以內，玩家說「這是遊戲」。

| 階段 | 預算 |
|---|---|
| NSEvent 擷取 + 鍵位轉譯 | < 2ms |
| gRPC 輸入注入（localhost） | < 3ms |
| Guest 處理 + 出一幀（60fps） | ~16.7ms |
| 畫格取出 + 串流傳輸 | < 10ms |
| Metal 上屏（含合成器） | < 16.7ms |

Phase 0 的唯一任務就是實測這張表。量測方法：guest 端跑 timestamp
overlay 測試 App + 主機端高速錄影對幀，不靠感覺。

---

## 5. 「鏡像體驗」規格（對標 iPhone Mirroring）

iPhone Mirroring 之所以好，不是因為功能多，是因為**沒有東西擋在你和
手機之間**。逐項對標：

| iPhone Mirroring 行為 | Mirage 對應規格 | 階段 |
|---|---|---|
| 點開即用，無設定精靈 | 首次啟動自動下載映像並建立實例；之後冷啟動 < 30 秒、快照喚醒 < 5 秒 | P1 |
| 乾淨原生視窗，無工具列噪音 | 預設無邊框 chrome，控制項藏在 hover 標題列 | P1 |
| 鍵盤直接打字 | 實體鍵盤事件直通 guest（IME 文字走剪貼簿橋接） | P1 |
| 滑鼠即觸控 | 點擊=tap、拖曳=swipe、滾輪=scroll，手感調校 | P1 |
| 剪貼簿互通 | 雙向同步（emulator gRPC 原生支援） | P1 |
| 拖檔案進視窗 | 拖 APK = 安裝；拖圖片/檔案 = 存入 guest 下載區 | P1 |
| 視窗大小自由調整 | 任意縮放，維持長寬比，動態 DPI | P1 |
| 通知轉發到 Mac 通知中心 | guest 通知橋接 → macOS 通知（需 guest 端 companion 服務） | P2 |
| 待機低耗 | 視窗關閉 = 快照凍結，不佔資源；選單列常駐快速喚醒 | P2 |
| 音訊隨畫面走 | guest 音訊 → CoreAudio 輸出 | P1 |

**明確不做**（YAGNI）：手機實機投放（我們不是 scrcpy）、Windows/Linux
版、Intel Mac、平板/摺疊螢幕模擬、root 開關 UI。

---

## 6. 鍵位映射引擎

遊戲產品的命根子。設計原則：**設定檔是資料，不是程式碼**。

- 每遊戲一份 JSON profile（schema 驗證，載入時 fail fast）：
  - `tap`：按鍵 → 座標點擊（技能鍵）
  - `joystick`：WASD → 虛擬搖桿圓域（移動）
  - `look`：滑鼠移動 → 視角拖曳（射擊遊戲的 free look，含滑鼠捕捉模式）
  - `swipe`、`repeat`、`combo`：進階手勢
- 座標一律存**正規化座標**（0.0–1.0），與解析度解耦——換視窗大小、換
  裝置 DPI，profile 不變。消滅特殊情況，而不是為每種解析度寫分支。
- Profile 不可變（immutable）：編輯產生新版本，可一鍵回滾。
- 內建 overlay 編輯器：半透明覆蓋在遊戲畫面上直接拖放鍵位（P1 出陽春版，
  P2 打磨）。
- Profile 格式從第一天就設計成可分享（單檔、自含、有版本欄位），P2 做
  社群分享時不必遷移格式。

---

## 7. 里程碑

### Phase 0：技術驗證（2–4 週）——go/no-go 閘門

用**官方 prebuilt emulator**（先不 fork）驗證整條命脈：

1. headless 啟動（`-no-window` + gRPC 端點）於 macOS 實測可用
2. `streamScreenshot` 串流：實測可穩定拿到 60fps 畫格流，量測格式成本
   （raw RGBA vs PNG）
3. 輸入注入：sendTouch/sendKey 延遲實測
4. 端到端 input-to-photon 量測，對照第 4.2 節預算表
5. Swift 最小 POC：一個 Metal 視窗顯示串流 + 滑鼠點擊直通

**Go**：延遲 < 80ms 且 60fps 穩定 → 進 Phase 1。
**No-go**：gRPC 串流不達標 → 備援路線依序為 (a) WebRTC 通道（官方
container scripts 已有實作可抄）、(b) fork 後加共享記憶體畫格交換。
備援再驗 2 週，仍不達標則重新評估專案（這比做完才發現便宜 20 倍）。

### Phase 1：MVP（Phase 0 後 2–3 個月）

- 單實例完整生命週期（下載映像 → 建立 → 快照休眠/喚醒）
- 鏡像視窗：Metal 渲染、縮放、全螢幕遊戲模式、音訊
- 拖放安裝 APK、剪貼簿雙向同步、鍵盤直通
- 鍵位映射引擎 + 陽春 overlay 編輯器
- **3 款指標遊戲**開箱即玩（涵蓋三種輸入型態）：
  1. Pokémon TCG Pocket（點擊型，輕量）
  2. 傳說對決或同級 MOBA（虛擬搖桿 + 技能鍵）
  3. 原神或同級 3D 大作（GPU 壓力 + free look）
- 驗收標準：三款遊戲 60fps 穩定、輸入延遲 < 80ms、冷啟動 < 30 秒

### Phase 2：遊戲化（MVP 後 2–3 個月）

- 遊戲庫 UI 與 per-game 相容性清單（學 BlueStacks：逐款驗證、公開透明）
- Profile 匯入/匯出/分享
- 多開（InstanceManager 天生就為此設計，此時才開 UI）
- 通知橋接、選單列常駐
- 裝置識別調校（處理反模擬器偵測，見風險 R2）

### Phase 3：打磨與發布

- 效能調校衝 120fps（對標 MuMu Pro）
- 崩潰回報、自動更新、上架/發行通路
- 公開 mirage-core 開源 repo 與授權聲明

**人力配置**（2 人）：一人扛核心與串流管線（C++/建置/量測），一人扛
Swift 殼與鍵位引擎（UX）。單人執行時程乘以 1.8。

---

## 8. 風險與對策

| # | 風險 | 嚴重度 | 對策 |
|---|---|---|---|
| R1 | **GMS/Play Store 授權**：Google Play 映像不可隨產品再散布。多數遊戲依賴 Play 服務。 | 高 | MVP 用 AOSP 映像 + 引導使用者自行安裝 GApps/Aurora Store（文件化、一鍵輔助，但不代為散布）。這是全行業灰色地帶，我們選擇最保守的一端：**不重散布任何 Google 專有元件**。 |
| R2 | **反模擬器/反作弊偵測**：部分大廠遊戲偵測到模擬器即封鎖或封號。 | 高 | 不承諾「全部能玩」。維護公開相容性清單（學 BlueStacks），只對清單內遊戲掛保證。裝置識別調校僅做 build.prop 層級、Phase 2 才碰；**不做**核心層反偵測軍備競賽——那是 30 人團隊的戰場。 |
| R3 | **上游變動**：AOSP emulator 架構調整導致 patch 失效。 | 中 | 最小 patch set + 每季同步上游一次 + patch 全部附理由文件。Phase 0 用 prebuilt 驗證，能不 fork 就先不 fork。 |
| R4 | **串流路徑效能天花板**：gRPC 畫面串流延遲/吞吐不達標。 | 中 | 這正是 Phase 0 存在的理由。備援路線已排序（WebRTC → 共享記憶體），失敗條件與停損點明確。 |
| R5 | **1–2 人維護量**：產品上線後相容性維護吃人。 | 中 | 相容性清單控制範圍（先 20 款，不貪多）；profile 社群化分攤（P2）；核心升級跟 Google 不自扛。 |
| R6 | **macOS 大版本更新破壞相容**（BlueStacks 在 macOS 26 踩過的坑）。 | 中 | 每年 WWDC beta 期即上機測試；Hypervisor.framework 與 Metal 是 Apple 一級公民 API，風險低於私有 API 路線。 |

---

## 9. 成功指標

**Phase 1（MVP）出貨線**：
- 3 款指標遊戲開箱即玩，60fps 穩定
- input-to-photon < 80ms（目標 50ms）
- 冷啟動 < 30 秒、快照喚醒 < 5 秒
- 記憶體閒置佔用 < 4GB

**Phase 2 後的產品線**：
- 相容清單 ≥ 20 款主流遊戲
- 120fps 模式（對標 MuMu Pro 的高幀體驗）
- 使用者留存與 profile 分享數（具體目標於 P2 開始時定）

---

## 10. 已決事項與預設立場

避免懸而未決的 TBD，以下皆有預設立場，推翻需要新事實：

| 事項 | 預設立場 |
|---|---|
| 商業模式 | MVP 完全免費（學 BlueStacks Air 的進場策略）；變現於 P3 再議，傾向「免費 + 進階訂閱（多開/高幀）」的 MuMu 混合式，**永不做廣告夾帶** |
| 正式名稱 | 沿用 Mirage 直到有更好的；命名不擋任何工程進度 |
| 開源範圍 | mirage-core（fork + patches）開源履行 GPL；Swift 殼閉源 |
| Android 版本 | 跟隨官方 emulator 最新穩定映像，不自維舊版本 |
| 發行通路 | 直接下載（.dmg + Sparkle 自動更新）；App Store 因虛擬化與 JIT 限制不可行，不浪費時間申請 |

---

## 附錄：參考資料

- MuMu 模擬器 Pro 官網（功能、240fps、訂閱制）：
  - https://mumu.163.com/mac/mk1/
  - https://mumu.163.com/mac/subscribe/20240126/40027_1134545.html
  - 第三方測評：https://zhuanlan.zhihu.com/p/683192192 、https://www.pkstep.com/mumuplayer/
- BlueStacks Air（正式版公告、功能、疑難排解）：
  - https://www.bluestacks.com/blog/bluestacks-exclusives/bluestacks-air-launch-en.html
  - https://www.bluestacks.com/blog/bluestacks-exclusives/bluestacks-air-top-features-en.html
  - https://support.bluestacks.com/hc/en-us/articles/32442693360397-Troubleshooting-common-issues-with-BlueStacks-Air
  - https://www.techspot.com/news/105974-bluestacks-air-new-android-emulator-natively-runs-mobile.html
- 官方 Android Emulator（gRPC / headless / 串流）：
  - https://developer.android.com/studio/releases/emulator
  - https://medium.com/androiddevelopers/android-emulator-in-a-ci-environment-dd65f63cdcd
  - https://github.com/google/android-emulator-container-scripts （WebRTC 串流橋實作參考）
  - gRPC 介面說明：https://gist.github.com/mrk-han/fa5c6e8951919b7efc1ba99fcd10496e
