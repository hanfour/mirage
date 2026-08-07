"""D44：用 Python client 拉 `streamAudio`，量它每秒實際收到多少音訊。

**要回答的問題**：Mirage（grpc-swift）在同一台 emulator 上只收到即時速率的約 6.5%，
而 guest 端的 AudioFlinger 實測以 93.6% 的即時速率在輸出。缺口是在 emulator 那一側，
還是在 client 這一側？

D39 追 MMAP（D16）時量到的關鍵對照是同一個形狀：`streamScreenshot` 上 Python 拿到
400/400、grpc-swift 只拿到約 15/400（≈4%）。若這裡 Python 也拿到接近 100%，那 D44 與
D16 就是同一個根因——不是 MMAP 特有，而是 grpc-swift 對這台 emulator 的所有
server-streaming RPC 都只收到一小部分——而那條路徑不需要 MMAP、不需要共享記憶體，
是遠比 D16 更簡單的重現。

**必須用 `.venv` 的 python，不能用系統的**：`gen/` 下的產生碼是 protobuf 7.x 產的，
系統 python 裝的是 4.x，一 import 就炸（D49）。

用法：
    phase0/harness/.venv/bin/python phase0/harness/audio_client_parity.py --seconds 20
"""

import argparse
import sys
import time

sys.path.insert(0, "gen")

import grpc
from google.protobuf import empty_pb2
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg


# 48kHz × 2ch × 2 bytes/sample = 每秒的即時位元組數。供應率就是實收除以它。
REALTIME_BYTES_PER_SEC = 48_000 * 2 * 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", default="localhost:8556")
    parser.add_argument("--seconds", type=float, default=20.0)
    args = parser.parse_args()

    channel = grpc.insecure_channel(
        args.target, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)

    # 對齊 Swift 那一側的請求：GrpcAudioTransport.packets() 送的就是這四個欄位。
    fmt = ec.AudioFormat()
    fmt.samplingRate = 48_000
    fmt.channels = ec.AudioFormat.Channels.Value("Stereo")
    fmt.format = ec.AudioFormat.SampleFormat.Value("AUD_FMT_S16")
    fmt.mode = ec.AudioFormat.DeliveryMode.Value("MODE_REAL_TIME")

    try:
        # Swift 也先打 getStatus 過版本閘，順序一併對齊。
        stub.getStatus(empty_pb2.Empty(), timeout=5)
    except grpc.RpcError as error:
        print(f"getStatus 失敗：{error}", file=sys.stderr)
        return 2

    packets = 0
    total_bytes = 0
    sizes: list[int] = []
    first_format = None
    started = time.monotonic()
    deadline = started + args.seconds

    try:
        for packet in stub.streamAudio(fmt, timeout=args.seconds + 5):
            if first_format is None and packet.HasField("format"):
                first_format = packet.format
            packets += 1
            total_bytes += len(packet.audio)
            sizes.append(len(packet.audio))
            if time.monotonic() >= deadline:
                break
    except grpc.RpcError as error:
        # 逾時是正常收工路徑（我們靠時間停，不靠伺服器結束串流）。
        if error.code() is not grpc.StatusCode.DEADLINE_EXCEEDED:
            print(f"streamAudio 失敗：{error}", file=sys.stderr)
            return 1

    elapsed = time.monotonic() - started
    if elapsed <= 0 or packets == 0:
        print(f"沒有收到任何封包（elapsed={elapsed:.2f}s）", file=sys.stderr)
        return 1

    bps = total_bytes / elapsed
    print(f"PY_PACKETS={packets}")
    print(f"PY_BYTES={total_bytes}")
    print(f"PY_ELAPSED={elapsed:.2f}")
    print(f"PY_PKT_PER_SEC={packets / elapsed:.1f}")
    print(f"PY_MEAN_PACKET_BYTES={total_bytes / packets:.1f}")
    print(f"PY_SUPPLY_PCT={bps / REALTIME_BYTES_PER_SEC * 100:.1f}")
    if first_format is not None:
        print(f"PY_FORMAT=sr={first_format.samplingRate} "
              f"ch={first_format.channels} fmt={first_format.format}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
