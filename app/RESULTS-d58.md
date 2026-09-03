# D58 transport compare 結果

日期：2026-09-03
分支：`d58-transport-compare`

## 改動

- `phase0/harness/fps_baseline.py` 新增 `--transport {rgba,mmap}`，預設仍是 `rgba`。MMAP 使用 `open_frame_buffer`、`make_handle`、`frame_array`，暫存路徑在 `tempfile.gettempdir()` 下，量測結束會清理。兩種 transport 共用取樣指紋，新增 `distinct` 與 `stale` 狀態，退出碼為 3。
- `phase0/harness/bench_mmap_vs_rgba.py` 新增 `--endpoint`、`--serial`、`--no-animate`。量測前用 `channel_ready_future(...).result(timeout=5)` 探測連線，animate 啟動後 3 秒內提前結束會以 1 結束。CPU 與 gRPC 位元組量測保留。
- 新增 `app/scripts/verify_transport_compare.sh`。每輪交錯順序、量測前後都用共用 `load_gate`，以 venv Python 解析 JSON，只把 `status == measured` 且 `elapsed <= D * 1.1` 的樣本納入中位數，並斷言兩種 transport 各至少 `MIN_VALID` 筆。
- `app/scripts/ci.sh` 新增不可 skip 的閘門 8。`requirements-d45.txt` 加入 pytest，`README-venv.md` 同步安裝與範圍說明。
- `phase0/harness/tests/` 新增 transport、狀態、指紋、endpoint 與錯誤路徑測試，以及 repo root 執行時所需的測試 import 支援。既有三個測試檔沒有修改。

## 工作方式

先依 `phase0/harness/README-venv.md` 建立 `phase0/harness/.venv-d45`，再安裝 pytest：

```text
phase0/harness/.venv-d45/bin/pip install --quiet -r phase0/harness/requirements-d45.txt
No broken requirements found.
grpcio==1.83.0
numpy==2.4.6
protobuf==7.35.1
pytest==9.1.1
```

測試先寫的紅燈基線：

```text
phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
11 failed, 17 passed
```

分部分提交如下：

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

結果文件本身尚未建立提交。實際嘗試 `git commit` 的輸出是：

```text
fatal: Unable to create '/Users/hanfourhuang/Projects/mirage/.git/worktrees/d58-transport-compare/index.lock': Operation not permitted
```

這是本工作環境對共享 `.git` 的寫入限制。主要功能部分已按上列分段提交，結果文件由 `git status --short` 顯示為新增檔案。

## 驗收證據

### 1. CI 八道閘門

實際指令：

```bash
bash app/scripts/ci.sh
```

實際輸出：

```text
=== 閘門 0：確認 45999 真的沒人監聽 ===
✅ 45999 無人監聽，端點將指向它（等同 runner 上沒有模擬器）

=== 閘門 1：建置（含測試 target）===
sandbox-exec: sandbox_apply: Operation not permitted
error: 'app': Invalid manifest
❌ 建置失敗
建置失敗即中止。
```

結果：未驗過。受管理 sandbox 不允許 Swift manifest 的 `sandbox-exec`，所以 CI 在閘門 1 中止，沒有到閘門 8。閘門 8 的指定指令另行執行並通過，見下一節。

### 2. 第 3 節 E 測試

實際指令：

```bash
phase0/harness/.venv-d45/bin/python -m pytest -q phase0/harness/tests
```

實際輸出：

```text
.......................................                                  [100%]
39 passed in 0.34s
```

閘門 8 使用的相同指令也得到 `39 passed`。`bash -n app/scripts/ci.sh app/scripts/verify_transport_compare.sh` 與 Python 編譯檢查均以退出碼 0 結束。

### 3. 前置與有效輪數故障注入

下列測試使用一般 TCP listener 讓 `require_grpc` 通過。listener 不是 emulator，也沒有執行 adb 或 emulator 指令。

require_grpc 故障注入：

```bash
bash app/scripts/verify_transport_compare.sh -p 45999 -r 1 -d 1
```

```text
exit=1
=== 前置：gRPC ===
❌ gRPC 45999 無回應——模擬器未啟動。
```

負載門檻故障注入，使用 `LOAD_LIMIT=0`：

```bash
LOAD_LIMIT=0 bash app/scripts/verify_transport_compare.sh -p 45998 -r 1 -d 1
```

```text
exit=1
=== 前置：gRPC ===
✅ gRPC 45998 ALIVE
=== 前置：venv python ===
✅ venv python：.../.venv-d45/bin/python
=== 第 1/1 輪：負載門檻（上限 0）===
❌ 第 1 輪量測前負載 4.15 已超標，中止。
stderr: ⚠️ load average 4.15 超過上限 0
```

venv 存在性故障注入，使用不存在的覆寫路徑：

```bash
TRANSPORT_COMPARE_VENV=/tmp/d58-missing-python bash app/scripts/verify_transport_compare.sh -p 45997 -r 1 -d 1
```

```text
exit=1
=== 前置：gRPC ===
✅ gRPC 45997 ALIVE
=== 前置：venv python ===
❌ 找不到 venv python：/tmp/d58-missing-python
請先建立環境：
  cd phase0/harness
  python3 -m venv .venv-d45
  ./.venv-d45/bin/pip install --quiet 'protobuf>=7.35,<8' grpcio numpy pytest
```

有效輪數故障注入，讓假 TCP endpoint 通過 gRPC 前置但兩種 baseline 都沒有有效 JSON，`MIN_VALID` 保持 2：

```bash
LOAD_LIMIT=100000 bash app/scripts/verify_transport_compare.sh -p 45995 -r 1 -d 1
```

```text
exit=1
=== 解析結果 ===
rgba：中位數 無資料 fps，有效輪數 0
mmap：中位數 無資料 fps，有效輪數 0
差值（mmap - rgba）：無資料
❌ rgba 有效輪數：實測 0，門檻 2
```

結果：四個故障注入都確實以非零退出，前置與有效輪數斷言會紅。

### 4. 預設 baseline 改前/改後對照

實際執行方式：以原始 commit `3d0dd71` 的 `fps_baseline.py` 和目前版本，在同一個假的兩幀 stub、固定時鐘、相同 `--json`（不帶 `--transport`）下各執行一次，程式內容由 `git show 3d0dd71:phase0/harness/fps_baseline.py` 讀取原始版本。

實際輸出：

```text
old_rc= 0
new_rc= 0
old_json= {"elapsed": 0.2, "error": null, "fps": 10.0, "frames": 2, "height": 2000, "status": "measured", "width": 900}
new_json= {"distinct": 2, "elapsed": 0.2, "error": null, "fps": 10.0, "frames": 2, "height": 2000, "status": "measured", "transport": "rgba", "width": 900}
legacy_fields_equal= True
new_fields= ['distinct', 'transport']
stderr_empty= True
```

結果：既有欄位與退出碼一致，新欄位只有規格要求的 `transport` 與 `distinct`。

### 5. 無 emulator 的 bench 連線失敗

實際指令：

```bash
phase0/harness/.venv-d45/bin/python phase0/harness/bench_mmap_vs_rgba.py --endpoint localhost:45999 --no-animate
```

實際輸出：

```text
exit=1
stdout:
stderr:
❌ gRPC localhost:45999 連線失敗：5 秒內沒有就緒。
```

stdout 沒有任何表格或 fps 數字。

## 未驗證項目

- 驗收條件 1 的完整 `bash app/scripts/ci.sh` 未全綠，原因是執行環境阻擋 Swift manifest sandbox，不是閘門 8 測試失敗。
- 沒有 emulator，因此沒有執行真實 raw RGBA/MMAP 交錯量測，也沒有產生真實 transport 中位數；這是規格禁區明確要求由 PM 在有 emulator 的機台完成。
- README 的 protobuf import 指令實際得到 `ModuleNotFoundError: No module named 'emulator_controller_pb2'`，因本工作樹沒有被 `.gitignore` 排除的 `phase0/harness/gen/` 產生碼。venv 套件與 pytest 已驗證，產生碼 import 未驗證。
- 沒有執行 adb、emulator 或其他活體裝置指令。

禁區檢查：

```text
git diff 3d0dd71..HEAD --name-status
只包含 app/scripts/ci.sh、app/scripts/verify_transport_compare.sh、phase0/harness 量測器/測試/venv 文件與 requirements。
沒有 app/Sources、app/Tests、verify_fps_fullscreen.sh、verify_mmap.sh 或 project-review 文件變更。
```
