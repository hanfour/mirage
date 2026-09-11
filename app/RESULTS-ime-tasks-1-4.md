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

## Task 4 — Swift 真路徑的欄位驗收（完成，含保留的首次 FAIL）

- 判定器 red：3 測試、12 issue，確實拒絕 clipboard 相符但欄位錯誤、追加到尾端、
  丟前後綴、NFC/NFD 互換，以及 stale/null／錯焦點快照。
- 普通 EditText 原始完整 run：100／250 ms 各三輪，**60/60 通過**，每個配置包含
  三次中間插入、三次選取替換，以及六次 20 筆 burst。
- 第一個 LINE run：前 7 案通過，第 8 案 `100-r1-replace` **FAIL**。
  期望 `LEFT中文🙂RIGHT`，實際 `LEFTold中文🙂RIGHT`；RPC 全 OK、結果為
  submittedUnverified，欄位判定器仍拒絕。測試當場停止，沒有自動改跑 250 ms。
  原檔保存在 `live-line/`，由 `original-line-failure-hashes.json` 保護；摘要器拒絕該 run。

### 計畫錯誤與修正：Copy 驗證會改變 LINE 選取狀態

初稿假設以 sentinel＋Copy 讀到 old 之後，old 還保持選取，這在 LINE 的本次流程不成立。
獨立的 ASCII-only 診斷沒有再貼 Unicode：`before-copy.png` 的 old 有高亮，Copy 讀回 old，
`after-copy.png` 已變成 old 後方游標，`reselected.png` 才恢復高亮。
因此「選到什麼」有證據，不等於「驗證後仍保持選取」。

修正為 Copy 證明後**重新選取 old**，再以相同 Swift executor 與相同 100／250 ms 測 Paste。
沒有改產品提交程式、沒有調大等待，也沒有改掉失敗案例的 expected。

- 普通欄位只重跑受此修正影響的位置案例：**12/12 通過**，新目錄 `live-edittext-reselected/`。
- LINE 在新目錄 `live-line-reselected/` 重跑完整矩陣：**60/60 通過**，100／250 ms 各三輪。
  每個配置的三次中間插入、三次選取替換、六次 burst 全數通過；原 FAIL 未改判。
  兩種值仍是這組條件下的結果，不是通用安全下限。
- 新增既有證據目錄拒寫保護。Swift 先 red（1 issue）後 green；wrapper 的隔離負對照
  證明舊版會進入 Swift，新版在啟動前拒絕，原 failure 檔不變。

實際文字由 `InputQueue → TextCommitExecutor → EmulatorClient checked gRPC` 發出。
adb/Python 只作清理、ASCII seed、定位／選取、Copy 證明與 UIAutomator／截圖觀察；
不是拿先前 Python paste 代替 Swift 實作。


### 最終 Task 4 欄位證據

| 目標／run | 100 ms | 250 ms | 中間插入／選取替換 |
|---|---:|---:|---|
| 普通 EditText 完整矩陣 | 30/30 | 30/30 | 各配置插入 3/3、替換 3/3 |
| 普通 EditText 修正後位置重測 | 6/6 | 6/6 | Copy 後重新選取，兩項各 3/3 |
| LINE 原始 run | 7 通過、1 FAIL，當場停止 | 未執行 | Copy 驗證收合選取，FAIL 保留 |
| LINE 修正後完整矩陣 | 30/30 | 30/30 | 各配置插入 3/3、替換 3/3 |

LINE 的實際內容：

- 中間插入：`LEFTRIGHT` → `LEFT中文🙂RIGHT`，合計 **6/6**。
- 選取替換：`LEFToldRIGHT`，Copy 先證明選到 `old`，再重新選取 → `LEFT中文🙂RIGHT`，
  合計 **6/6**。這是 guest 的選取／Paste 語意，不是 Mac NSTextInputClient 的任意 replacementRange。
- 六種字串涵蓋中文、重複字串、emoji、NFC/NFD 重音與 ZWJ；burst 同時包含 20 筆同字與
  20 筆有序異字。所有 commit 的執行結果仍只叫 `submittedUnverified`，PASS 來自實際欄位。
- 修正後 run 各保持一條連線。結束時兩個欄位為空，LINE 可見對話節點仍為原先兩個，
  指紋與前一階段一致；沒有 Send／Enter 操作。guest 剪貼簿文字也讀回為原備份值。

| burst 實際時距（ms） | 普通 EditText 100 | 普通 EditText 250 | LINE 100 | LINE 250 |
|---|---:|---:|---:|---:|
| commit 起點間隔中位數 | 110.332 | 263.523 | 113.362 | 270.277 |
| 最短 key-up 回覆後保留時間 | 100.084 | 250.171 | 100.146 | 250.174 |

環境：emulator 37.1.11.0／15917651、Android API 35、LINE 26.14.0／261400121，
既有 Gboard LatinIME；未完整枚舉語言 subtype，不因類名推定英文。普通欄位為原生 Settings
搜尋 EditText；兩個目標均以新鮮 UI dump、精確碼位與欄位裁切圖驗證。

### 最後檢查與範圍

- Task 4 完整離線 `swift test`：**444 tests passed**。
- `ci.sh`：**全部通過**，保留預設三輪完整 suite，0 NIO ERROR，既有 lint、provision、
  共用函式庫與 Python 閘門均通過；沒有降低次數或用 live skip 代替欄位驗收。
- 原 LINE FAIL 的檔案雜湊再次核對未變；新舊 run 分開，摘要器拒絕原失敗 run。
- 案例中的 Copy 會改變驗證前置，是這次修正計畫的關鍵。另新增禁止覆寫既有證據目錄；
  這些是驗收 harness 變更，Task 1–3 的產品傳輸程式在修正前後沒有改動。
- **Task 5–8 沒有開始，Mac IME UI 尚未實作。** 這裡的放行是已測環境與配置下的提交／位置
  語意，不是所有 app／負載、所有輸入法或永不失敗的 ACK。

原始資料與重算方式見 [measurements/ime-tasks-1-4/README.md](measurements/ime-tasks-1-4/README.md)。
