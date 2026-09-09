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
./.venv-d45/bin/pip install --quiet -r requirements-d45.txt
```

重新產生 protobuf 生成碼：

```bash
cd phase0/harness
mkdir -p gen
./.venv-d45/bin/python -m grpc_tools.protoc \
  -I protos \
  --python_out=gen \
  --grpc_python_out=gen \
  protos/emulator_controller.proto
```

`gen/` 是本機生成的忽略檔案。重新產生後再執行下面的 import 驗證。

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

### 為什麼鎖 `grpcio-tools`

`grpcio-tools==1.83.0` 提供上面的 `grpc_tools.protoc` 指令，並與目前生成碼標記的
gRPC 版本對齊。它只在重新產生 `gen/` 時使用，平常執行 harness 不會 import
`grpc_tools`；版本仍固定在 requirements，讓重新產生的結果可重現。

## `requirements-d45.txt` 鎖的版本

用 `./.venv-d45/bin/pip freeze | grep -iE '^(protobuf|grpcio|numpy|pytest)'` 取得的實際版本：

```
grpcio==1.83.0
grpcio-tools==1.83.0
numpy==2.4.6
protobuf==7.35.1
pytest==9.1.1
```

`pip check` 在這個組合下回報 `No broken requirements found.`。

## 這個 venv 解決的範圍——以及沒解決的部分

這個 venv **只保證 `fps_baseline.py` 這一條路徑能跑**：它只 import
`grpc`、`emulator_controller_pb2`、`emulator_controller_pb2_grpc`，
`requirements-d45.txt` 也列出 pytest 與 grpcio-tools，分別供 phase0/harness 的
測試閘門與生成碼重建使用。

`phase0/harness/` 其餘 11 個既有檔案（見上面清單，扣掉 `fps_baseline.py`
本身）**仍然是死的**——就算用這個 venv 執行，有些檔案還會缺其他套件
（例如 `encoded_bench.py` 用到的 `av`），沒有一併驗證過。pytest 測試由 CI 閘門 8
執行。修好整個 `phase0/harness/` 不在 D45 範圍內，
另記債務。

## 這個 venv 涵蓋到什麼程度（2026-09-09 逐檔實測）

D49 記載「11 個既有檔案全部 import 不動」。用 `.venv-d45` 逐檔驗過之後，
**9 個 import 得動**：`animate.py`、`bench_mmap_vs_rgba.py`、`diag_fd_variable.py`、
`e2e_latency.py`、`input_latency.py`、`probe_mmap.py`、`probe_mmap_explicit.py`、
`smoke_grpc.py`、`stream_bench.py`。

剩下兩個不是 protobuf 版本的問題：

- **`encoded_bench.py` 需要 `av`（PyAV）**，不在 `requirements-d45.txt` 裡。
  刻意不加：PyAV 要編 ffmpeg、體積與建置時間都不小，而這支是一次性的編碼實驗工具。
  真的要用時單獨裝：`./.venv-d45/bin/pip install av`。
- **`probe_touch_coords.py` 的預設目標是 `emulator-5558`／port 8558**，那是舊環境留下的，
  本專案現在用 5556／8556。裝置不存在時它原本會炸一個看不出原因的 `AttributeError`，
  已改成快速失敗並指出要用參數指定目標。
