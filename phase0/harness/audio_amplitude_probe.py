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
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen"))

import numpy as np
import grpc
from google.protobuf import empty_pb2
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg

CHANNELS = {"mono": 1, "stereo": 2}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--target", default="localhost:8556")
    p.add_argument("--seconds", type=float, default=15.0)
    p.add_argument("--rate", type=int, default=48000)
    p.add_argument("--channels", default="stereo", choices=list(CHANNELS))
    p.add_argument("--label", default="")
    args = p.parse_args()

    nch = CHANNELS[args.channels]
    realtime_bps = args.rate * nch * 2

    channel = grpc.insecure_channel(
        args.target, options=[("grpc.max_receive_message_length", -1)])
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
    gap = elapsed - (last_pkt - started) if last_pkt else elapsed
    print(f"{tag}LAST_PKT_AT={last_pkt - started:.1f}s  "
          f"TAIL_SILENCE={gap:.1f}s  "
          f"{'封包中途停止' if gap > 2 else '交付持續到結束'}")
    line = "  ".join(
        f"{k}s:{buckets[k][0]/realtime_bps*100:.0f}%/pk{buckets[k][1]}"
        for k in sorted(buckets) if k < int(elapsed))
    print(f"{tag}TIMELINE {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
