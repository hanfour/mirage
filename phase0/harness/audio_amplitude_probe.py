"""量 `streamAudio` 的交付率、振幅與逐秒時間軸，一次跑完。

**為什麼不用 `audio_client_parity.py`**：那支只給交付率與平均包大小，不看振幅。
在 D44 的崩潰狀態下，大聲播放的 YouTube 與完全無聲的畫面都會讀成峰值 4，
只看交付率會把無聲誤判成正常。判「有沒有聲音」必須自己算 `np.abs(samples).max()`。

輸出三個獨立的訊號，因為 D44 有兩種不同的失效：

- `SUPPLY_PCT` 與逐秒 `TIMELINE`：交付率崩潰（掉到約 6.5% 並閂鎖，不自行恢復）。
- `LAST_PKT_AT` 與 `TAIL_SILENCE`：長時間執行的 RPC 靜默停止交付（D70）。
  尾端超過 2 秒沒有封包就判為「封包中途停止」，與交付率崩潰是兩件事。
- `PEAK` 與 `RMS`：內容本身有沒有聲音。

`TIMELINE` 每秒印 `交付率%/峰值`，崩潰的時點直接看得出來，這是用平均值看不到的。

**必須用 `.venv-d45` 的 python**：`gen/` 下的產生碼是 protobuf 7.x 產的，系統 python 是 4.x，
一 import 就炸（D49）。

用法：
    phase0/harness/.venv-d45/bin/python phase0/harness/audio_amplitude_probe.py \
        --seconds 30 --label baseline
"""

import argparse
import importlib.util
import os
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "gen"))


import numpy as np
import grpc
from google.protobuf import empty_pb2
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg

CHANNELS = {"mono": 1, "stereo": 2}

# 尾端多久沒有封包才算「中途停止」。封包間隔約 11ms，2 秒等於漏掉約 180 個。
TAIL_SILENCE_THRESHOLD_SECONDS = 2.0

CONFLATION_CAUTION = (
    "⚠️ 封包停止不等於 RPC 壞了：guest 停止輸出音訊時 emulator 會關閉主機輸出裝置、"
    "封包歸零，形狀與 RPC 停止交付完全相同。判定前先確認 guest 當下還有沒有音軌"
    "（`adb shell dumpsys audio | grep state:started`），"
    "`app/scripts/measure_audio_window.sh` 會自動幫你查。")


def _load_grpc_auth():
    """按檔案路徑載入 `tools/probe/lib/grpc_auth.py`，不動 `sys.path`。

    把 `tools/probe` 加進 `sys.path` 會讓 `lib` 這個名字指到那邊，
    於是 `phase0/harness/lib/*` 全部 import 不到，本目錄的 pytest 會整批失敗。
    """
    path = os.path.join(_HERE, "..", "..", "tools", "probe", "lib", "grpc_auth.py")
    spec = importlib.util.spec_from_file_location("mirage_probe_grpc_auth", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def tail_verdict(elapsed, last_packet_offset, threshold=TAIL_SILENCE_THRESHOLD_SECONDS):
    """判斷尾端的空白算不算「封包中途停止」，並在算的時候附上警告。

    **這個警告是有代價換來的**：2026-09-08 曾把「封包中途停止」直接記成一筆缺陷（D70），
    說 `streamAudio` 的長連線會靜默停止交付。後來在同一台機器上連續量了 21 分鐘、七個 RPC
    都沒有重現，而故意在量測中途停掉 guest 音訊就能穩定產生一模一樣的輸出
    （`LAST_PKT_AT=23.0s TAIL_SILENCE=42.0s`）。這把尺分不出那兩件事。
    """
    gap = elapsed - last_packet_offset
    stopped = gap > threshold
    verdict = "封包中途停止" if stopped else "交付持續到結束"
    return gap, verdict, CONFLATION_CAUTION if stopped else ""



def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", default="localhost:8556")
    p.add_argument("--seconds", type=float, default=15.0)
    p.add_argument("--rate", type=int, default=48000)
    p.add_argument("--channels", default="stereo", choices=list(CHANNELS))
    p.add_argument("--label", default="")
    args = p.parse_args()

    grpc_auth = _load_grpc_auth()
    nch = CHANNELS[args.channels]
    realtime_bps = args.rate * nch * 2

    # emu.sh 開的 emulator 帶 `-grpc-use-token`，不附 token 會一律 UNAUTHENTICATED。
    # token 每次開機重產，所以從探索檔即時讀，不快取、不寫進參數。
    channel = grpc.intercept_channel(
        grpc.insecure_channel(args.target, options=[("grpc.max_receive_message_length", -1)]),
        grpc_auth.AuthInterceptor(grpc_auth.auth_metadata(int(args.target.rsplit(":", 1)[1]))))
    stub = ecg.EmulatorControllerStub(channel)

    fmt = ec.AudioFormat()
    fmt.samplingRate = args.rate
    fmt.channels = ec.AudioFormat.Channels.Value(args.channels.capitalize())
    fmt.format = ec.AudioFormat.SampleFormat.Value("AUD_FMT_S16")
    fmt.mode = ec.AudioFormat.DeliveryMode.Value("MODE_REAL_TIME")

    try:
        stub.getStatus(empty_pb2.Empty(), timeout=5)
    except grpc.RpcError as e:
        print(f"getStatus 失敗：{e}", file=sys.stderr)
        return 2

    started = time.monotonic()
    deadline = started + args.seconds
    last_pkt = None
    packets = 0
    total_bytes = 0
    peak_all = 0
    sumsq = 0.0
    nsamp = 0
    # 逐秒桶：(bytes, peak)
    buckets: dict[int, list] = {}

    try:
        for pkt in stub.streamAudio(fmt, timeout=args.seconds + 5):
            now = time.monotonic()
            last_pkt = now
            packets += 1
            raw = pkt.audio
            total_bytes += len(raw)
            if raw:
                s = np.frombuffer(raw, dtype=np.int16)
                if s.size:
                    pk = int(np.abs(s.astype(np.int32)).max())
                    peak_all = max(peak_all, pk)
                    sumsq += float(np.square(s.astype(np.float64)).sum())
                    nsamp += s.size
                else:
                    pk = 0
            else:
                pk = 0
            b = int(now - started)
            slot = buckets.setdefault(b, [0, 0])
            slot[0] += len(raw)
            slot[1] = max(slot[1], pk)
            if now >= deadline:
                break
    except grpc.RpcError as e:
        if e.code() is not grpc.StatusCode.DEADLINE_EXCEEDED:
            print(f"streamAudio 失敗：{e}", file=sys.stderr)
            return 1

    elapsed = time.monotonic() - started
    if packets == 0 or elapsed <= 0:
        print(f"沒有收到任何封包（elapsed={elapsed:.2f}s）", file=sys.stderr)
        return 1

    rms = (sumsq / nsamp) ** 0.5 if nsamp else 0.0
    tag = f"[{args.label}] " if args.label else ""
    print(f"{tag}REQ={args.rate}Hz/{args.channels}  ELAPSED={elapsed:.2f}s")
    print(f"{tag}PACKETS={packets}  PKT_PER_SEC={packets/elapsed:.1f}  "
          f"MEAN_PKT_BYTES={total_bytes/packets:.1f}")
    print(f"{tag}SUPPLY_PCT={total_bytes/elapsed/realtime_bps*100:.1f}")
    print(f"{tag}PEAK={peak_all}/32767  RMS={rms:.1f}")
    gap, verdict, caution = tail_verdict(elapsed, (last_pkt - started) if last_pkt else 0.0)
    print(f"{tag}LAST_PKT_AT={(last_pkt - started) if last_pkt else 0.0:.1f}s  "
          f"TAIL_SILENCE={gap:.1f}s  {verdict}")
    if caution:
        print(f"{tag}{caution}")
    line = "  ".join(
        f"{k}s:{buckets[k][0]/realtime_bps*100:.0f}%/pk{buckets[k][1]}"
        for k in sorted(buckets) if k < int(elapsed))
    print(f"{tag}TIMELINE {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
