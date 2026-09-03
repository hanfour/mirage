# D58 transport compare 結果

日期：2026-09-03
分支：`d58-transport-compare`

## 改動

1. `phase0/harness/fps_baseline.py` 新增 `--transport {rgba,mmap}`，預設仍為 `rgba`。MMAP 使用 `open_frame_buffer`、`make_handle`、`frame_array`，暫存路徑位於 `tempfile.gettempdir()` 且量測結束清理。兩種 transport 共用取樣指紋，新增 `distinct` 與 `stale` 狀態，`stale` 退出碼為 3。既有狀態與退出碼 0、1、2 保留。
2. `phase0/harness/bench_mmap_vs_rgba.py` 新增 `--endpoint`、`--serial`、`--no-animate`。量測前以 `channel_ready_future(channel).result(timeout=5)` 探測連線，animate 啟動 3 秒內結束會報錯並以 1 結束。既有 CPU 與 gRPC 位元組量測保留。
3. 新增 `app/scripts/verify_transport_compare.sh`。每輪先過共用 `load_gate`，奇數輪先 rgba、偶數輪先 mmap，量測後再檢查負載。以 venv Python 解析 JSON，只把 `status == measured` 且 `elapsed <= D * 1.1` 的樣本納入中位數，並斷言兩種 transport 各至少 `MIN_VALID` 筆。
4. `app/scripts/ci.sh` 新增不可 skip 的閘門 8，執行規格指定的 phase0 pytest。`phase0/harness/requirements-d45.txt` 加入 pytest，`README-venv.md` 同步更新。
5. `phase0/harness/tests/` 新增 transport、狀態、指紋、endpoint、錯誤路徑與生成碼測試。第二輪保留以 `pb_module` 注入的 `test_transport_compare.py`，移除兩份重複測試，並讓 `conftest.py` 在生成碼存在時載入真實 module。

## 工作流程

先依 README 建立 venv，再安裝測試相依：

```bash
cd phase0/harness
python3 -m venv .venv-d45
./.venv-d45/bin/pip install --quiet --upgrade pip
./.venv-d45/bin/pip install --quiet 'protobuf>=7.35,<8' grpcio numpy pytest
```

最後以 requirement file 重確認：

```text
phase0/harness/.venv-d45/bin/pip install --quiet -r phase0/harness/requirements-d45.txt
exit=0
phase0/harness/.venv-d45/bin/pip check
No broken requirements found.
phase0/harness/.venv-d45/bin/pip freeze | grep -iE '^(protobuf|grpcio|numpy|pytest)'
grpcio==1.83.0
numpy==2.4.6
protobuf==7.35.1
pytest==9.1.1
```

protobuf 生成碼是 `.gitignore` 產物。本地用隔離的 `grpcio-tools==1.83.0` 產生後，README import 驗證輸出為：

```text
import OK, ImageFormat: ImageFormat
```

測試先寫的紅燈基線先後為：

```text
./phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
3 errors during collection
ModuleNotFoundError: No module named 'lib'

新增 D58 測試後、實作前：
1 error during collection
ModuleNotFoundError: No module named 'emulator_controller_pb2'
```

第一個問題由新增測試收集設定修正，第二個問題由量測模組延遲處理生成碼並由測試注入 fake module 修正。

功能分段提交如下：

```text
a9a1c5f test: 新增 D58 transport 對照測試
540a2fd feat: 完成 fps baseline transport 量測
406bc14 feat: 修正 bench 端點與動畫來源
b94b012 feat: 新增交錯 transport 驗證腳本
9f95606 ci: 加入 phase0 harness 測試閘門
809155f fix: 保留 baseline 純文字輸出契約
eee3243 fix: 量測後重新檢查主機負載
7e64fb2 fix: 使用絕對路徑啟動動畫來源
```

## 驗收證據

### 1. 完整 CI

實際指令：

```bash
bash app/scripts/ci.sh
```

第一次完整執行的實際末段輸出：

```text
=== 閘門 0：確認 45999 真的沒人監聽 ===
✅ 45999 無人監聽，端點將指向它（等同 runner 上沒有模擬器）

=== 閘門 1：建置（含測試 target）===
sandbox-exec: sandbox_apply: Operation not permitted
error: 'app': Invalid manifest
❌ 建置失敗
建置失敗即中止。
```

該次退出碼為 1，閘門 1 中止，因此八道閘門整體未驗證為全綠。最後一次重跑在閘門 1 超過兩分鐘沒有輸出，為避免留下 Swift 子進程以 Ctrl-C 結束，退出碼為 130。這是受管理 sandbox 的 Swift manifest 限制，不是本次 Python 測試失敗。閘門 8 的指定指令另行通過，見下一節。

### 2. 第 3 節 E 測試與閘門 8

實際指令：

```bash
phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
```

實際輸出：

```text
.......................................                                  [100%]
39 passed in 0.48s
```

`bash -n app/scripts/ci.sh app/scripts/verify_transport_compare.sh`、Python `py_compile` 與 repo scripts shell lint 的實際退出碼都是 0；shell lint 輸出為 `shell_lint=clean`。

### 3. 前置與有效輪數斷言故障注入

下列負載與 venv 測試使用暫時 fake `nc`、`uptime`，只讓腳本進入對應分支，沒有啟動 emulator 或執行 adb。所有暫時 fixture 已清除。

`require_grpc` 斷言：

```bash
app/scripts/verify_transport_compare.sh -p 45999 -r 1 -d 1
```

```text
exit=1
=== 前置：gRPC ===
❌ gRPC 45999 無回應——模擬器未啟動。
```

負載門檻斷言，注入 `LOAD_LIMIT=0`：

```bash
PATH="/Users/hanfourhuang/Projects/mirage/.worktrees/d58-transport-compare/.d58-fault-bin:${PATH}" LOAD_LIMIT=0 app/scripts/verify_transport_compare.sh -p 45999 -r 1 -d 1
```

```text
exit=1
=== 前置：gRPC ===
✅ gRPC 45999 ALIVE
=== 前置：venv python ===
✅ venv python：.../.venv-d45/bin/python
=== 第 1/1 輪：負載門檻（上限 0）===
⚠️ load average 1.00 超過上限 0——本次樣本不可信，建議重測。
❌ 第 1 輪量測前負載 1.00 已超標，中止。
```

venv 存在性斷言，注入不存在的覆寫路徑：

```bash
PATH="/Users/hanfourhuang/Projects/mirage/.worktrees/d58-transport-compare/.d58-fault-bin:${PATH}" TRANSPORT_COMPARE_VENV=/private/tmp/d58-missing-venv app/scripts/verify_transport_compare.sh -p 45999 -r 1 -d 1
```

```text
exit=1
=== 前置：gRPC ===
✅ gRPC 45999 ALIVE
=== 前置：venv python ===
❌ 找不到 venv python：/private/tmp/d58-missing-venv
請先建立環境：
  cd phase0/harness
  python3 -m venv .venv-d45
  ./.venv-d45/bin/pip install --quiet 'protobuf>=7.35,<8' grpcio numpy pytest
```

有效輪數斷言，讓 fake `nc` 通過但實際 baseline endpoint 沒有服務，兩種 transport 都回傳 `error`，`MIN_VALID` 保持 2：

```bash
PATH="/Users/hanfourhuang/Projects/mirage/.worktrees/d58-transport-compare/.d58-fault-bin:${PATH}" app/scripts/verify_transport_compare.sh -p 45999 -r 1 -d 1
```

```text
exit=1
rgba 無效：status=error error=UNAVAILABLE: ... Connection refused（退出碼 1）
mmap 無效：status=error error=UNAVAILABLE: ... Connection refused（退出碼 1）
===== 解析結果 =====
rgba：中位數 無資料 fps，有效輪數 0
mmap：中位數 無資料 fps，有效輪數 0
差值（mmap - rgba）：無資料
❌ rgba 有效輪數：實測 0，門檻 2
```

另以 fake venv Python 執行 3 輪的流程 smoke，實際呼叫順序為：

```text
rgba
mmap
mmap
rgba
rgba
mmap
```

輸出結果為：`rgba` 中位數 60.00 fps、有效輪數 3，`mmap` 中位數 55.00 fps、有效輪數 3，差值 `-5.00 fps`，兩種有效輪數斷言均通過。這是 stub 流程驗證，不是真實 emulator 數字。

### 4. 預設 baseline 改前與改後

以同一個 venv 執行內嵌 Python，透過 `git show 3d0dd71:phase0/harness/fps_baseline.py` 載入改前版本，兩版都注入相同 fake measured 結果，使用不帶 `--transport` 的 `--json` 與純文字模式：

```text
old_exit=0 new_exit=0
old_fields_preserved=True
old_values_preserved=True
new_fields=rgba,7

old_exit=0 new_exit=0
old_text=fps=12.34 frames=7 elapsed=1.25 size=900x2000 status=measured
new_text=fps=12.34 frames=7 elapsed=1.25 size=900x2000 status=measured transport=rgba distinct=7
old_text_is_prefix=True
```

結果：舊欄位、舊值、退出碼與純文字既有整行均保留，新版只追加規格要求的 `transport` 與 `distinct`。

### 5. 無 emulator 的 bench 連線失敗

實際指令：

```bash
phase0/harness/.venv-d45/bin/python phase0/harness/bench_mmap_vs_rgba.py --endpoint localhost:45999
```

實際輸出：

```text
exit=1
❌ gRPC localhost:45999 連線失敗：5 秒內沒有就緒。
```

連線探測在表格與判讀之前執行，輸出沒有任何 fps 數字。

## 第二輪修正

以下是 2026-09-03 第二輪的本機測試證據。紅燈輸出是修正前加入或收緊測試後的結果，綠燈輸出是完成該點後的結果。沒有 emulator 的活體結果由 PM 補寫，本節不代寫。

### 7.1 真實 protobuf 生成碼

修法：`conftest.py` 把 `phase0/harness/gen` 放進 import path，只有生成碼不存在時才提供 fake module；新增 `test_generated_proto.py` 驗證 `__file__`、`ImageFormat`、`ImageTransport` 與 `EmulatorControllerStub`。README 補上 `grpc_tools.protoc` 重建指令，requirements 鎖定 `grpcio-tools==1.83.0`。

紅燈：

```text
$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests/test_generated_proto.py
F                                                                        [100%]
E       assert module_file is not None
1 failed in 0.01s
```

綠燈：

```text
$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests/test_generated_proto.py
.                                                                        [100%]
1 passed in 0.01s

$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
........................................                                 [100%]
40 passed in 0.16s
```

### 7.2 mmap 建置失敗清理

修法：channel、MMAP 暫存路徑/緩衝區與 request 建置移入外層 `try/finally`，對已建立的 buffer、暫存檔與 channel 逐一清理；串流 RPC 的錯誤處理仍維持原本的狀態轉換。

紅燈：

```text
$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests/test_transport_compare.py::test_mmap_setup_failure_cleans_buffer_path_and_channel
F                                                                        [100%]
E       AssertionError: assert not True
E        +  where True = exists()
1 failed in 0.09s
```

綠燈：

```text
$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests/test_transport_compare.py::test_mmap_setup_failure_cleans_buffer_path_and_channel
.                                                                        [100%]
1 passed in 0.09s

$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
.........................................                                [100%]
41 passed in 0.14s
```

### 7.3 密集畫面指紋

修法：移除 4099 位元組步長，改用 `hashlib.blake2b(bytes(view[::64]), digest_size=8)`。測試覆蓋兩幀只差 3600 位元組整列、只差第一個位元組、完全相同，以及舊稀疏取樣會漏掉的中段變更；所有案例同時比較 raw RGBA 與 MMAP 來源。

紅燈：

```text
$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests/test_transport_compare.py::test_dense_fingerprint_detects_a_midframe_change
F                                                                        [100%]
E       AssertionError: assert 1 == 2
1 failed in 0.14s
```

綠燈：

```text
$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests/test_transport_compare.py::test_sampled_distinct_detects_expected_content_changes phase0/harness/tests/test_transport_compare.py::test_dense_fingerprint_detects_a_midframe_change
....                                                                     [100%]
4 passed in 0.11s

$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
............................................                             [100%]
44 passed in 0.16s
```

### 7.4 測試去重與 alias 清理

修法：保留 `test_transport_compare.py` 的 `pb_module` 注入寫法，刪除 `test_fps_baseline.py` 與 `test_bench_mmap_vs_rgba.py` 的重複案例；`bench_mmap_vs_rgba.py` 移除只為舊測試存在的 `endpoint_to_port` alias，測試直接呼叫 `port_from_endpoint`。

紅燈：

```text
$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests/test_transport_compare.py::test_endpoint_port_derivation
F                                                                        [100%]
E       AssertionError: assert not True
E        +  where True = hasattr(bench, 'endpoint_to_port')
1 failed in 0.14s
```

綠燈：

```text
$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests/test_transport_compare.py::test_endpoint_port_derivation phase0/harness/tests/test_transport_compare.py::test_bench_connection_failure_exits_before_fps_output
..                                                                       [100%]
2 passed in 0.11s

$ phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
.................................                                        [100%]
33 passed in 0.15s
```

### 7.5 結果文件

修法：本節逐點記錄第二輪的修法與紅綠測試證據，保留 PM 後續填寫活體結果的位置。

文件檢查：

```text
$ test "$(rg -c '^### 7\.[1-5] ' app/RESULTS-d58.md)" -eq 5
$ echo "second_round_sections=5"
second_round_sections=5

$ git diff --check
exit=0
```

## 未驗證

1. 驗收條件 1 的完整 `bash app/scripts/ci.sh` 未全綠。閘門 1 被管理環境的 Swift manifest sandbox 阻擋，閘門 8 則已用規格指定指令獨立驗證為綠。
2. 沒有 emulator，因此未執行真實 raw RGBA 與 MMAP 交錯量測，也沒有真實 transport 中位數或差值。活體驗證由 PM 在有 emulator 的機台執行。
3. 沒有在真實 emulator 上驗證 animate 的序號錯誤、3 秒內提前結束路徑，只有程式碼檢查與 fake stub 測試。
4. `gen/` 與 `.venv-d45/` 是忽略的本機產物，不在提交內容中。README import 是在本地生成相容 stub 後驗證，fresh clone 的生成步驟仍需依 repo README 手動執行。
5. 沒有執行 adb、emulator 或活體裝置指令。

## 禁區檢查

未修改 `app/Sources/`、`app/Tests/`、`app/scripts/verify_fps_fullscreen.sh`、`app/scripts/verify_mmap.sh`，也未修改 `docs/specs/2026-07-29-project-review.md`。所有提交檔案均限於本規格列出的 harness、scripts、requirements、README、測試與本結果文件。

## PM 把關與活體驗證（2026-09-03）

### 把關

- `bash app/scripts/ci.sh` 在 worktree 上跑兩次（第一輪交付後、第二輪修正後），九道閘門皆綠，退出碼 0。codex 沙箱裡跑不了 `swift build`（巢狀 `sandbox-exec`），所以閘門 1 由 PM 在沙箱外跑。
- 獨立審查 agent 找到兩個第一輪沒抓到的缺陷（conftest 假模組永遠生效、mmap 建置失敗漏資源），連同 PM 的三點退回第二輪，修法見簡報第 7 節。
- 第二輪後 PM 自己做突變檢查：指紋步長 64 改成 100000，只有 `test_dense_fingerprint_detects_a_midframe_change` 紅；把 `gen/` 藏起來，只有 `test_generated_proto_is_loaded_from_gen` 紅；還原後 33 條全綠。

### 活體：三輪交錯對照（第一輪交付的工具）

環境：`mirage-game`（`emulator -avd mirage-game -port 5556 -grpc 8556 -gpu host`），Pixel Flow 0.33.0 在前景自行動畫，900×2000，每輪 20 秒，`LOAD_LIMIT=12`。第一次嘗試在第 1 輪後負載從 6.06 升到 14.13（冷建置後的檔案系統索引風暴），腳本照設計中止；等負載降到 6.46 後重跑：

| 輪 | 順序 | transport | fps | frames | distinct | 負載前 → 後 |
|---|---|---|---|---|---|---|
| 1 | rgba/mmap | rgba | 47.64 | 953 | 946 | 6.46 → 10.09 |
| 1 | rgba/mmap | mmap | 45.87 | 918 | 914 | 6.46 → 10.09 |
| 2 | mmap/rgba | mmap | 59.57 | 1192 | 1192 | 10.09 → 6.51 |
| 2 | mmap/rgba | rgba | 59.39 | 1189 | 1189 | 10.09 → 6.51 |
| 3 | rgba/mmap | rgba | 58.98 | 1181 | 1180 | 6.51 → 6.04 |
| 3 | rgba/mmap | mmap | 59.99 | 1200 | 1200 | 6.51 → 6.04 |

中位數 rgba 58.98、mmap 59.57，差值 0.59 fps，有效輪數各 3，退出碼 0。

第二輪修正後再跑一輪 10 秒確認工具沒被改壞：rgba 59.79（599 幀、599 種）、mmap 59.94（600 幀、600 種），負載 4.38 → 4.63。取樣密度提高後 distinct 與 frames 相等；第一輪工具在同樣畫面下曾出現 953 對 946 這種差距，那是稀疏取樣漏抓，不是畫面重複。

### 判定

1. 在驗收環境（mirage-game、真實遊戲畫面、900×2000）下，Python client 走 raw RGBA 就到 vsync 天花板，MMAP 沒有可量到的增益。傳輸不是驗收線 7 的瓶頸。
2. D39 的「raw RGBA 吞吐天花板 270 到 290 MiB/s、898×1996 上 raw 只有 40 fps」不成立：本次 raw 在 900×2000 上每秒送出約 405 MiB。D39 是在 `mirage-poc`（`hw.gpu.enabled=no`、2G RAM）用 `animate.py` 人造動畫量的，兩個條件都與驗收環境不同。
3. 第 1 輪兩種 transport 同時掉到 46 到 48，同一輪負載從 6.46 升到 10.09，形狀與 D60（主機負載壓垮 guest 出幀）一致，與 transport 無關。
4. 因此：D16 降回 P3，D48 的「MMAP 候選解方」移除。Python 直拉 59 而 Mirage 自己量到 43 到 54，剩下的損失在 Mirage 行程內部，下一步是「Swift 直拉對照組」把 grpc-swift 與渲染兩段切開。
