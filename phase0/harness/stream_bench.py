"""streamScreenshot 基準：量幀率、幀間隔分佈、每幀位元組數。

用法：
  python stream_bench.py --format rgba --seconds 10
  python stream_bench.py --format png  --seconds 10
  python stream_bench.py --format rgba --seconds 10 --width 540 --height 1200
量測時請在另一終端跑動畫產生器：`python animate.py --seconds 30`
（streamScreenshot 是變化驅動，靜止畫面不出幀）。
"""
import argparse
import sys
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.stats import summarize

TARGET = "localhost:8554"
FORMATS = {
    "rgba": ec.ImageFormat.RGBA8888,
    "png": ec.ImageFormat.PNG,
}


def bench(fmt_name: str, seconds: int, width: int, height: int) -> None:
    # 原生解析度的 RGBA8888 單幀 > 10MiB，超過 grpc-python 預設 4MiB
    # 接收上限（RESOURCE_EXHAUSTED）。基準腳本僅供本機量測，放寬上限。
    channel = grpc.insecure_channel(
        TARGET, options=[("grpc.max_receive_message_length", -1)]
    )
    stub = ecg.EmulatorControllerStub(channel)
    scaled = bool(width and height)
    if scaled:
        req = ec.ImageFormat(format=FORMATS[fmt_name], width=width, height=height)
    else:
        req = ec.ImageFormat(format=FORMATS[fmt_name])  # width/height 不給 = 原生解析度

    timestamps: list[float] = []
    total_bytes = 0
    deadline = time.monotonic() + seconds
    for frame in stub.streamScreenshot(req):
        now = time.monotonic()
        timestamps.append(now)
        total_bytes += len(frame.image)
        if now >= deadline:
            break

    stats = summarize(timestamps)
    avg_mb = total_bytes / stats.frames / 1_048_576
    line = (f"format={fmt_name} frames={stats.frames} fps={stats.fps:.1f} "
            f"p50={stats.p50_ms:.1f}ms p95={stats.p95_ms:.1f}ms "
            f"avg_frame={avg_mb:.2f}MiB throughput={avg_mb * stats.fps:.0f}MiB/s")
    if scaled:
        line += f" size={width}x{height}"
    print(line)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=FORMATS, required=True)
    parser.add_argument("--seconds", type=int, default=10)
    parser.add_argument("--width", type=int, default=0,
                         help="縮放寬度；0（預設）= 原生解析度")
    parser.add_argument("--height", type=int, default=0,
                         help="縮放高度；0（預設）= 原生解析度")
    args = parser.parse_args()
    if args.seconds < 3:
        parser.error("--seconds 至少 3 秒才有統計意義")
    if args.width < 0 or args.height < 0:
        parser.error("--width/--height 不可為負數")
    if bool(args.width) != bool(args.height):
        parser.error("--width 與 --height 必須同時提供或同時省略")
    bench(args.format, args.seconds, args.width, args.height)
    return 0


if __name__ == "__main__":
    sys.exit(main())
