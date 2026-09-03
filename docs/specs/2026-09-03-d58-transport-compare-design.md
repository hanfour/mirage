# D58／D53／D54：把「raw RGBA vs MMAP」的對照做成一支可信的量測工具

- 日期：2026-09-03
- 狀態：任務簡報（交 codex 實作，PM 把關）
- 分支：`d58-transport-compare`
- 相關債務：D58（bench 寫死埠號、連不上時產出 0.0 fps 再下判讀）、D53（決定性的量測工具不在任何驗證腳本裡）、D54（MMAP 量測沒有負載門檻與交錯機制）

## 1. 背景：為什麼要做這件事

驗收線 7（全螢幕 60fps，門檻 55）未通過，中位數 48。目前唯一帶數字的候選解方是 MMAP transport（D16）：
D39 用 `phase0/harness/bench_mmap_vs_rgba.py` 量到 898×1996 上 raw 40.0 fps／MMAP 56.7 fps。

但 2026-08-07 用另一支工具 `fps_baseline.py` 在真實遊戲畫面上掃四個解析度，得到的方向與 D39 的頻寬模型相反（像素愈多 fps 愈高），且同一天發現 bench 有兩個缺陷（D58）：

1. `TARGET = "localhost:8554"` 寫死，沒有旗標。連錯埠會得到整組 0.0 fps，然後印一行「MMAP 未出幀，量測無效」。紅得像 MMAP 的問題，實際是連不上。
2. 第 144 行啟動 `animate.py` 時沒傳 `--serial`／`--port`，所以動畫源永遠連 5554／8554。在其他機台上動畫源與資料源都是斷的。

兩支工具量的是同一件事，數字差 100 倍時不能兩個都信。D16 要不要繼續追，取決於一次乾淨的對照：同一台 emulator、同一份畫面、同一個窗口，交錯量 raw 與 MMAP。這支工具現在不存在。本任務就是把它做出來。

## 2. 目標（一句話）

讓 `fps_baseline.py` 能用同一套狀態契約量 raw RGBA 與 MMAP 兩種傳輸，並有一支驗證腳本以交錯、帶負載門檻的方式跑多輪並印出中位數。

## 3. 範圍

### A. `phase0/harness/fps_baseline.py` 加 `--transport {rgba,mmap}`

- 預設 `rgba`，既有的旗標、輸出格式、退出碼（0 measured／1 error／2 static）一個都不能變。
- `mmap` 模式：用 `lib/mmap_source.py` 既有的 `open_frame_buffer`／`make_handle`／`frame_array` 建緩衝區（暫存檔用絕對路徑，放在 `tempfile.gettempdir()` 底下），`ImageFormat` 帶 `transport=ImageTransport(channel=MMAP, handle=...)`。量完要刪暫存檔。
- 兩種模式都要算 `distinct`：整個窗口內畫面內容不同的幀數。用便宜的指紋（例如每 4099 個位元組取樣一次再雜湊），不要每幀複製整張圖。rgba 模式從 `frame.image` 取樣，mmap 模式從映射區取樣。兩種模式用同一段程式算，不要各寫一份。
- 新增狀態 `stale`：`frames > 0` 但 `distinct < 2`。退出碼 3。意思是通知有來但內容沒變，這正是 D16 的症狀，必須與 `measured` 分開。
- JSON 與純文字輸出都要多帶 `transport` 與 `distinct`。
- docstring 頂端那張狀態表要更新。

### B. `phase0/harness/bench_mmap_vs_rgba.py` 修 D58

- 加 `--endpoint`（預設 `localhost:8554`，維持既有行為）與 `--serial`（預設 `emulator-5554`）。啟動 `animate.py` 時把埠號與序號傳過去，埠號從 endpoint 推導。
- 加 `--no-animate`：不啟動動畫源，畫面由呼叫端負責（量真實遊戲畫面時用）。
- 連線失敗要在印任何表格或判讀之前就明確報錯並以退出碼 1 結束。做法建議：開頭用 `grpc.channel_ready_future(channel).result(timeout=5)` 探一次。
- `animate.py` 若啟動後 3 秒內就結束（例如序號不存在），要報錯退出，不要繼續量。
- 這支工具的 CPU 與 gRPC 位元組量測保留，不動。

### C. 新增 `app/scripts/verify_transport_compare.sh`

- 用法：`verify_transport_compare.sh [-p 8556] [-r 3] [-d 20]`。預設 8556、3 輪、每輪 20 秒。
- 前置：`require_grpc`；venv python 存在（路徑照 `verify_fps_fullscreen.sh` 第 75 行的寫法）。
- 每一輪先過負載門檻（`load_gate`，`LOAD_LIMIT` 預設 12），量完回檢一次負載並印出。門檻不過就中止，不是印警告繼續。
- 交錯：每一輪各量一次 rgba 與 mmap，奇數輪先 rgba、偶數輪先 mmap，抵消順序效應。
- 每次量測呼叫 `fps_baseline.py --json --transport X --endpoint localhost:$PORT --seconds $D --width 900 --height 2000`，用 venv 的 python 解析 JSON，不要用 sed 抓欄位。
- 只有 `status == measured` 且 `elapsed <= D × 1.1` 的樣本算有效（後者的理由見 `verify_fps_fullscreen.sh` 第 372 行起的註解）。其他狀態如實印出理由，不計入中位數。
- 輸出：逐輪表格（輪次、順序、transport、fps、frames、elapsed、distinct、status、量測前後負載），兩種 transport 各自的中位數與有效輪數，以及差值。
- 斷言：兩種 transport 各至少 `MIN_VALID`（預設 2）個有效樣本，否則退出碼 1。這支腳本不對「誰比較快」下判定，判定是人的事；它只保證數字是在可信條件下量到的。
- 所有共用函式從 `app/scripts/lib/verify_common.sh` 與 `app/scripts/lib/load_sentinel.sh` 取用。`source` 的路徑要在 `cd` 之前解析成絕對路徑（D55 的坑，`verify_mmap.sh` 開頭有正確寫法）。

### D. `app/scripts/ci.sh` 加閘門 8：跑 `phase0/harness/tests/`

- 用 `phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests`。
- venv 或 pytest 不存在時閘門要紅並印出建立方式，不能 skip。這個 repo 的教訓是「存在但沒人跑的測試等於沒有」（D37、D49）。
- `requirements-d45.txt` 加 `pytest`，`README-venv.md` 同步更新。
- 既有的三個測試檔（`test_detector.py`、`test_mmap_source.py`、`test_stats.py`）從沒被跑過。跑起來若紅，原因在測試檔本身且十行內能修的就修；否則不要動，在結果文件裡寫清楚，由 PM 決定。

### E. 測試

放在 `phase0/harness/tests/`，pytest。不需要 emulator，用假的 stub 注入。至少涵蓋：

- rgba 與 mmap 兩種模式建出的 `ImageFormat` 內容正確
- 四種狀態的對映（含 `stale`）與退出碼
- `distinct` 的計算對兩種模式一致
- bench 的 endpoint 到 port 的推導、連線失敗的退出路徑
- 既有行為不變：不帶 `--transport` 時 JSON 欄位是既有欄位的超集合

要達成這點，`measure()` 需要能注入 stub 與（mmap 模式下）緩衝區的內容來源。重構時保持既有呼叫端 `verify_fps_fullscreen.sh` 不用改一個字。

### F. 結果文件 `app/RESULTS-d58.md`

寫下：改了什麼、每一條斷言用什麼故障注入證明它會紅（貼指令與輸出）、跑了哪些測試與結果、沒有驗的是什麼。沒驗過的不要寫成驗過。

## 4. 禁區

- 不動 `app/Sources/`、`app/Tests/`，這一輪與 Swift 無關。
- 不動 `verify_fps_fullscreen.sh`、`verify_mmap.sh`。
- 不改 `fps_baseline.py` 既有的預設值與退出碼 0／1／2。
- 不啟動 emulator、不執行 adb 或 emulator 指令。活體驗證由 PM 在有模擬器的機台上做。
- 不修改 `docs/specs/2026-07-29-project-review.md` 的債務表，那是 PM 把關後才寫。

## 5. 驗收條件

1. `bash app/scripts/ci.sh` 八道既有閘門全綠，閘門 8 綠。
2. 第 3 節 E 列的測試全部存在且通過。
3. `verify_transport_compare.sh` 的三條前置斷言（`require_grpc`、負載門檻、venv 存在）與有效輪數斷言，各有一份故障注入的輸出證明會紅，附在結果文件裡。在沒有 emulator 的機台上，`require_grpc` 本來就會紅，這是可以用的。
4. `fps_baseline.py` 不帶 `--transport` 時，輸出與退出碼跟改前一模一樣。用改前的版本對照一次。
5. 沒有 emulator 時，`bench_mmap_vs_rgba.py --endpoint localhost:45999` 以退出碼 1 結束，且輸出裡沒有任何 fps 數字。

## 6. 工作方式

- 先建 venv：照 `phase0/harness/README-venv.md`，再裝 pytest。
- 測試先寫（紅），再實作（綠）。
- 每完成一個部分就 commit，訊息格式 `<type>: <描述>`，描述用繁體中文。
- 註解與文件用繁體中文台灣用語。不用破折號接補充說明，用冒號、括號或分句。
- bash 腳本用 `set -uo pipefail`。裸變數後面不能直接接全形標點（閘門 4 會擋），例如 `$rc，` 要寫成 `${rc}，`。
- 結束前把最終報告寫進 `app/RESULTS-d58.md`，並在最後一則訊息裡列出：改動的檔案、每條驗收條件的證據、沒做到的事。

## 7. 把關退回的修正清單（第二輪，2026-09-03）

第一輪交付的東西 ci.sh 九道閘門全綠、39 條 pytest 綠，PM 在真實 emulator 上跑過三輪對照也正常。以下五點是 PM 與獨立審查找到的缺陷，修完才合併。每一點都要有測試證明它修好了（改壞實作會紅）。

### 7.1 `conftest.py` 的假模組永遠生效，`gen/` 從沒被測過

`conftest.py` 只把 `phase0/harness` 加進 `sys.path`，沒加 `phase0/harness/gen`，所以 `try: import emulator_controller_pb2` 在任何環境都失敗、`except` 必中，假模組永遠塞進 `sys.modules`。閘門 8 因此看不到 D49 那種「生成碼與 runtime 版本不合」的失敗。

修法：
- conftest 在 try 之前把 `HARNESS_DIR/gen` 也加進 `sys.path`，讓真的生成碼存在時就用真的。
- 新增 `tests/test_generated_proto.py`：斷言 `emulator_controller_pb2.__file__` 位於 `phase0/harness/gen/` 底下，且 `ImageFormat`、`ImageTransport`、`EmulatorControllerStub` 都存在。`gen/` 不存在時這條測試要紅，不能 skip。這是刻意的：fresh clone 沒生成碼就是不能量，閘門要說出來。
- `README-venv.md` 補上重新產生 `gen/` 的指令（你第一輪用的 grpcio-tools 那套），`requirements-d45.txt` 加 `grpcio-tools==1.83.0`。

### 7.2 mmap 建置失敗會漏 channel 與暫存檔

`measure()` 裡建 channel、建緩衝區、建請求都在 `try` 之前。`buffer_factory` 在建檔後失敗（磁碟滿、權限），例外直接往外拋，已開的 channel 不關、暫存檔留在磁碟。

修法：把這三步搬進 `try`，`finally` 對「已建立的東西」逐一清理。加一條測試：注入會拋例外的 `buffer_factory`，斷言暫存檔不存在、假 channel 的 `close()` 被呼叫過。

### 7.3 指紋取樣太稀，而且測試是對著取樣點寫的

每 4099 位元組取一個，7.2 MB 的畫面只看 1756 個位元組（約 0.024%），畫面只有小區域變化時整輪會被誤判成 `stale`。而 `test_transport_compare.py` 的 `_payloads()` 是 `second[4099] = 1`，剛好改在取樣點上，這種測試只證明實作跟測試互相同意。

修法：指紋改成 `hashlib.blake2b(bytes(view[::64]), digest_size=8)`，步長 64、C 速度、每幀約 112 KB。測試改成「兩幀只差一整列（3600 位元組）」與「兩幀只差第 1 個位元組」，兩者都要 distinct=2；再加一條「兩幀完全相同」distinct=1。不要在測試裡引用步長常數。

### 7.4 測試重複與只為測試存在的別名

`test_fps_baseline.py`、`test_bench_mmap_vs_rgba.py` 與 `test_transport_compare.py` 覆蓋高度重疊（狀態對映、ImageFormat、連線失敗、JSON 欄位各寫了兩次）。留一份：以 `pb_module` 注入那種寫法為準，刪掉重複的測試；`load_baseline`／`load_bench` 裡的 `sys.path.insert(0, "phase0/harness")` 是相對路徑，刪掉（conftest 已處理）。`bench_mmap_vs_rgba.py` 的 `endpoint_to_port = port_from_endpoint` 別名只為測試存在，刪掉，測試直接用 `port_from_endpoint`。

### 7.5 結果文件

`app/RESULTS-d58.md` 加一節「第二輪修正」，列每一點的修法與證明它會紅的測試（貼指令與輸出）。PM 在真實 emulator 上的活體結果由 PM 自己補寫，你不要寫。

### 工作方式（第二輪）

- 同一分支 `d58-transport-compare` 接著做，每一點一個 commit。
- 你的沙箱跑不了 `swift build`（巢狀 sandbox-exec），所以不要跑 `ci.sh`。你要跑的是：`phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests`、`bash -n` 檢查改過的腳本、以及 `grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[，。：；、）]' app/scripts/*.sh` 確認沒有裸變數接全形標點。ci.sh 由 PM 跑。
- 禁區不變（第 4 節）。
