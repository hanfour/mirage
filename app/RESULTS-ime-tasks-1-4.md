# Mac IME 提交通道實作：Task 1–4（2026-09-11）

範圍：依已核准計畫完成至 UI 前的 Task 4；Task 5–8 不在本輪範圍。
本文件逐 task 記錄真正的 red/green 與 live 證據，不把 RPC OK 當欄位成功。

## Task 1 — 政策與狀態（完成）

- 行為 red：7 個測試、22 個斷言 issue，涵蓋非法設定被吞、settle 提前完成、
  dispatch 後仍被分類為未送出。不是只靠缺型別的編譯錯誤。
- 延遲消費 fake 在 Paste RPC 時只排隊，真正消費時才讀當下 clipboard：
  無等待的 A/B 穩定得到 B/B；政策到期前擋住覆寫則得到 A/B。
- policy 支援配置與交易快照；候選 250 ms 沒有被命名為安全值。
  結果保留 `submittedUnverified`，另有四類失敗／取消／拒收結果。
- 完整 `swift test`：**418 tests passed**。live 測試依既有閘門 skipped，不當活體證據。
- 證據：`measurements/ime-tasks-1-4/task1-red.txt`、`task1-green.txt`。

計畫細化：duration 限制在 1–60000 ms，作為有限資源／取消延遲的工程界線，
不是表示這個區間都有正確性保證；0、非法／溢位設定明確拒絕。

## Task 2 — checked transport 與單筆 executor（完成）

- 行為 red：8 個測試、19 個 issue，捕捉缺少真實操作／等待、吞錯及取消錯誤分類。
- checked API 將 deadline 傳給實際 gRPC，未連線會拋錯；不使用原先 `try?` wrapper。
- Unicode 整串只寫 clipboard；鍵事件只有 Control/v 的 down/up，沒有 KeyboardEvent.text。
- 六個 RPC 位置分別注入失敗，Paste down 至多一次；dispatch 後錯誤為 unknown，
  會盡力補 v/Control up。清理使用有期限、不繼承 cancellation 的工作，沒有重按 Paste。
- 回讀以 UTF-8 碼位比對，NFC/NFD 不同不當成相符；保留期由最後 key-up RPC 回覆起算。
- 完整 `swift test`：**426 tests passed**；證據在 `task2-red.txt`／`task2-green.txt`。

## Task 3 — 共享 queue／clipboard gate（完成）

- 主要 red：10 測試、16 issue。扣住 fake 真正消費的 checkpoint，仍容許 RPC 返回；
  獨立 Task 的原型得到 **B/B**，watcher 寫入順序為 **A／watcher-C／B**。
  不只檢查 RPC 次數，而是讓消費者讀取當下 clipboard，看見真實錯字。
- 改成一個 consumer await 整筆 executor，coordinator 的 hostValue 也在 active／paused 時拒絕
  提前覆寫。相同 fake 得到 **A/B**，writer 順序為 **A／B／watcher-C**。
- 仍保留「guest 比 policy 更慢」的負對照：延後到政策外消費可得到 B/B，結果也只叫
  submittedUnverified。測試沒有把 fake 強制限制在 250 ms 內而宣稱通用 ACK。
- 暫停時仍處理普通 key-up；unknown 有獨立保留欄位，不會被後續 queued 的取消結果蓋掉。
  resume 不重播舊 commit；未知交易需要明確承認不確定性。新政策只影響新的 admission。
- 補接模式／profile／焦點失效與 echo LRU 的 red：2 測試、4 issue，修正後全綠。
  AppModel 的 watcher 不再另開 setClipboard Task，自己送出的 echo 不寫回 Mac。
- 完整 `swift test`：**438 tests passed**。證據在 `task3-red.txt`、
  `task3-routing-red.txt`、`task3-green.txt`。

計畫細化／修正：

1. 保留舊 InputInjecting 的鍵／觸控介面，以獨立 TextCommitTransport capability 提供 checked
   文字操作，避免替舊 fake 加一個會吞錯的預設文字實作。
2. 暫停／失焦後的舊 queued commit 回具名結果、保留字串，不在 consumer 裡等待使用者。
   resume 只開放新的請求與最新延後的 host clipboard，不自動重新入列舊 commit。
3. own echo 只追蹤近期 64 個不同內容（使用時刷新順序）；proto 沒有來源 ID，同值外部複製
   或超出記錄範圍的遲到 echo 仍有歧義，不宣稱能完美辨識來源。
4. 核對到 InputQueue 原註解把順序寫成「到達順序」，已改成實際能保證的傳輸呼叫順序，
   不把 RPC 完成／clipboard 相符說成 guest 已消費。

## Task 4

尚在執行，未宣稱 live 通過。
