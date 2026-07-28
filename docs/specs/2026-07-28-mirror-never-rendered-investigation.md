# 調查記錄：鏡像顯示從未運作，且原因被記錯

- **日期**：2026-07-28
- **狀態**：根因未確立，交下一輪
- **影響**：Mirage 的核心功能（把模擬器畫面顯示出來）自 P1-a 起從未真正運作過

## 0. 一句話

`MIRAGE_FPS_LOG` 的 `fps=` 在這個專案的歷史上**從來沒有非零過**。`RESULTS-p1a.md` 把它歸因於「螢幕鎖定」並標記 `pending-unlock`，P1-e 沿用同一個歸因。**那個歸因是錯的**——今天在螢幕未鎖、使用者從自己的互動式終端機執行的條件下重現，仍然是 0，且視窗全黑、橫幅顯示紅字「未連線」。

## 1. 為什麼拖到現在才發現

App 層唯一的可觀測訊號就是 `fps=`，而它同時被三件事影響：

1. 有沒有連上
2. 連上後有沒有拉到幀
3. 拿到幀後有沒有畫出來

三者都沒發生時，「0 行輸出」分不出是哪一段斷掉。P1-a 挑了一個合理的解釋（螢幕鎖定會讓 `CVDisplayLink` 不觸發，這本身是真的）並誠實標成 pending，但**那個解釋沒有被獨立驗證過**——而它剛好能解釋觀察到的現象，於是三個階段都沿用了它。

今天新增 `MIRAGE_CONN_LOG=1`（commit `bc0d169`）把這三段拆開，第一次執行就看到了真相。

## 2. 已確立的事實

```
[app] endpoint=localhost:8558
[conn] UI 狀態消費者已啟動
[conn] connecting <--connectRequested  yield=enqueued(remaining: 9223372036854775807)
[conn] ensureChannel=true probe=healthy(version: "37.2.1.0 (37.2.1-15875889)")
[transport] raw rgba (default; set MIRAGE_TRANSPORT=mmap to try mmap)
[conn] connected <--connectSucceeded  yield=enqueued(remaining: 9223372036854775807)
[conn] attachStream 掛上，請求 540x1200
[conn] streamScreenshot 已送出，等第一幀…
[conn] 幀 #1 540x1200 bytes=2592000
[conn] 幀 #2 540x1200 bytes=2592000
```

| # | 事實 | 證據 |
|---|---|---|
| 1 | **連線是成功的** | 健康探測回報 `healthy`、狀態機到達 `connected`、`lsof` 顯示 TCP `[::1]:8558 ESTABLISHED` |
| 2 | **幀確實有進來，且內容正確** | `540x1200 bytes=2592000`＝`540×1200×4`，與 `Frame.isValid` 的要求一致；持續執行 3 分鐘可收到 360+ 幀 |
| 3 | **狀態永遠傳不到 UI** | `stateCont.yield()` 回報 `enqueued(remaining: Int.max)`（值確實進了無上限緩衝區），消費者停在 `for await` 且未結束，但**一個值都沒收到**。故 `connState` 停在初始的 `.disconnected` → 橫幅紅字「未連線」 |
| 4 | **有真實合成視窗時會 SIGSEGV** | 使用者環境：收到幀 #1、#2 之後 `segmentation fault`。無合成視窗的環境（背景執行）不崩，幀持續累積 → **崩潰在渲染路徑，不在網路路徑** |

## 3. 已測試並推翻的假設

| # | 假設 | 推翻方式 |
|---|---|---|
| 1 | 螢幕鎖定導致 `CVDisplayLink` 不觸發 | 螢幕未鎖、使用者自己的終端機執行，症狀相同 |
| 2 | 是 `configurable-endpoint` 分支改壞的 | `main` 版二進位（`/tmp/mirage-main`）同樣 0 取樣 |
| 3 | GUI app 被當成 background-only 所以不驅動 | 使用者從互動式終端機執行，症狀相同 |
| 4 | `AppModel` 與連線迴圈是不同的 `EmulatorClient` 實例 | `ObjectIdentifier` 兩邊一致（`0x…f61e0`） |
| 5 | 主 actor 被餓死，消費者的恢復排不上 | 改成 `Task.detached` 後症狀不變 |
| 6 | Swift concurrency 協作執行緒池卡住 | 探針證明健康：`activeProcessorCount=8`、detached 任務執行、MainActor 任務執行、5 秒逐秒心跳全數印出 |

另外排除：`client.states` 只有**一個**消費者（`AppModel.swift`，已 grep 全碼庫確認）；`stateCont.finish()` 全碼庫**無任何呼叫**；`states` 是 `nonisolated let` + `AsyncStream.makeStream`（預設 `.unbounded`）的標準寫法。

## 4. 下一輪的起點

**先寫一個會紅的測試。** `MirageShell` 於 `670369b` 之後可被 `@testable import`——「`EmulatorClient` 的 `states` 送不到消費者」這件事**應該能在單元測試裡重現，不需要 GUI、不需要模擬器**。這會是那筆跨三階段的架構債第一次真正兌現。

注意 [[nio-teardown-injectable-channel-debt]] 記載的判準：**任何讓 `EmulatorClient` 走到 `ensureChannel()` 建真 channel 的單元測試，都會加載 NIO 卡死那筆債**。所以測試要能在不建真 channel 的前提下驅動狀態轉換——若做不到，那本身就是「可注入 channel」該優先做的又一個理由。

**SIGSEGV 另案處理。** 它只在有合成視窗時發生（需要使用者環境），但已知它發生在幀送達之後、位於渲染路徑。P1-a 當時就存在，故嫌疑落在 `b2c0a5d` 當時就有的碼（`texture.replace` / `blit.copy` / `cb.present`），**不是** P1-e 新增的 `onFrameSize`。lldb 下不易重現（與 [[nio-teardown-injectable-channel-debt]] 記載的 Heisenbug 特性一致）。

**文件已更正**：`app/RESULTS-p1a.md`、`app/RESULTS-p1e.md` 的 `pending-unlock` 歸因已加註指向本文件。

## 5. 對 Phase-1 的影響

`docs/specs/2026-07-28-phase1-game-recon.md` 那一輪把驗收線縮成 1 款、並確認了「點擊型遊戲跑得起來、模擬器能以 46–59 fps 串流」。那些結論仍然成立——它們量的是**模擬器與環境**，用的是 Python harness，不經過 Mirage。

但**「Mirage 顯示遊戲時 60fps」這條驗收線目前無法量**，因為 Mirage 顯示不出東西。修好本文件的問題是 Phase-1 的前置。
