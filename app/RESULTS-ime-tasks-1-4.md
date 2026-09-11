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

## Task 3–4

尚在執行，未宣稱通過。
