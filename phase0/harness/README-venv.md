# `phase0/harness/` 的 venv（D45 用）

## 為什麼需要 venv

`phase0/harness/gen/emulator_controller_pb2.py` 是用 protobuf **7.35.0** 產生的
（檔頭標記 `Protobuf Python Version: 7.35.0`），一 import 就會呼叫
`_runtime_version.ValidateProtobufRuntimeVersion`，要求執行期的 protobuf 版本
不能舊於產生期的版本。

這台機器的系統 Python 裝的是 protobuf **4.25.4**（有別的東西依賴這個版本，
**不能動系統環境**）。結果是：`phase0/harness/` 底下所有會
`import emulator_controller_pb2` 的檔案，在系統 Python 下全部 import 不動，
直接炸 `ImportError` / `VersionError`。目前已知會這樣中的檔案（含本 task
新增的 `fps_baseline.py`）共 12 個：

```
animate.py, bench_mmap_vs_rgba.py, diag_fd_variable.py, e2e_latency.py,
encoded_bench.py, fps_baseline.py, input_latency.py, probe_mmap.py,
probe_mmap_explicit.py, probe_touch_coords.py, smoke_grpc.py, stream_bench.py
```

解法是用一個獨立的 venv（`.venv-d45/`），裡面裝相容版本的 protobuf，
跟系統環境完全隔離、互不影響。

## 怎麼建立

```bash
cd phase0/harness
python3 -m venv .venv-d45
./.venv-d45/bin/pip install --quiet --upgrade pip
./.venv-d45/bin/pip install --quiet 'protobuf>=7.35,<8' grpcio numpy
```

驗證 import 是否成功：

```bash
./.venv-d45/bin/python -c "
import sys; sys.path.insert(0, 'gen')
import emulator_controller_pb2 as pb
print('import OK, ImageFormat:', pb.ImageFormat.DESCRIPTOR.name)
"
```

預期輸出：`import OK, ImageFormat: ImageFormat`。

### 版本區間怎麼定出來的

一開始先試了較保守的 `protobuf>=5.29,<7`（裝到 6.33.6），import 立刻炸：

```
google.protobuf.runtime_version.VersionError: Detected incompatible Protobuf
Gencode/Runtime versions when loading emulator_controller.proto:
gencode 7.35.0 runtime 6.33.6. Runtime version cannot be older than the
linked gencode version.
```

錯誤訊息直講了：runtime 不能舊於 gencode 的 7.35.0。PyPI 上 protobuf 剛好有
`7.35.0`／`7.35.1` 兩個版本，所以改鎖 `protobuf>=7.35,<8`，改裝後 import 成功
（實際裝到 `7.35.1`）。

### 為什麼沒裝 `grpcio-tools`

一開始照做法安裝了 `grpcio-tools`，但它把 protobuf 硬性釘在 `<7.0.0`，
跟前面鎖定的 `protobuf>=7.35,<8` 直接衝突（`pip check` 會報
`grpcio-tools 1.81.1 has requirement protobuf<7.0.0,>=6.33.5, but you have
protobuf 7.35.1`）。檢查過 `phase0/harness/` 底下所有原始碼，
沒有任何檔案 `import grpc_tools`（它只在需要重新產生 `.proto` 的產生碼時才用得到，
而本 task 不重新產生任何東西），所以直接不裝，避免一個用不到、又會製造假衝突的
相依。

## `requirements-d45.txt` 鎖的版本

用 `./.venv-d45/bin/pip freeze | grep -iE '^(protobuf|grpcio|numpy)'` 取得的實際版本：

```
grpcio==1.83.0
numpy==2.4.6
protobuf==7.35.1
```

`pip check` 在這個組合下回報 `No broken requirements found.`。

## 這個 venv 解決的範圍——以及沒解決的部分

這個 venv **只保證 `fps_baseline.py` 這一條路徑能跑**：它只 import
`grpc`、`emulator_controller_pb2`、`emulator_controller_pb2_grpc`，
`requirements-d45.txt` 也只鎖了這幾個套件需要的版本。

`phase0/harness/` 其餘 11 個既有檔案（見上面清單，扣掉 `fps_baseline.py`
本身）**仍然是死的**——就算用這個 venv 執行，有些檔案還會缺其他套件
（例如 `encoded_bench.py` 用到的 `av`、測試用的 `pytest`，這個 venv
並未安裝），沒有一併驗證過。修好整個 `phase0/harness/` 不在 D45 範圍內，
另記債務。
