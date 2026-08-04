#!/usr/bin/env python3
"""D45 對照組：不經過 Mirage，直接消費 streamScreenshot 量 fps。

驗收線 7 的新判準 7a 要比「Mirage 的 fps」與「同條件下不經過 Mirage 的 fps」，
這支就是後者。

**為什麼不用 bench_mmap_vs_rgba.py**：那支會自己 Popen 啟動 animate.py 當動畫來源
（launcher 上的人造滑動），而 D45 的對照組必須量**跟 Mirage 側同一個遊戲畫面**——
`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §11.3 陷阱 3 記載過
「拿 launcher 當對照組」會量到靜止期。本檔刻意**不啟動任何動畫來源**，畫面由呼叫端
負責（D45 的量測腳本會讓 Pixel Flow 跑著）。

它也只跑 rgba 一種模式——D45 不關心 MMAP。

用法：
    python fps_baseline.py --seconds 20 --width 900 --height 2000
    python fps_baseline.py --seconds 20 --json
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen"))

import grpc
import emulator_controller_pb2 as pb
import emulator_controller_pb2_grpc as pbg


def measure(endpoint: str, seconds: int, width: int, height: int) -> dict:
    """跑 `seconds` 秒，回傳 fps 與原始計數。

    只計「真的收到的幀」——streamScreenshot 是變化驅動的，畫面靜止時本來就不出幀，
    所以呼叫端必須保證畫面在動，否則量到的是靜止期而不是效能。
    """
    channel = grpc.insecure_channel(endpoint, options=[
        ("grpc.max_receive_message_length", 64 * 1024 * 1024),
    ])
    stub = pbg.EmulatorControllerStub(channel)
    req = pb.ImageFormat(format=pb.ImageFormat.RGBA8888,
                         width=width, height=height)
    frames = 0
    t0 = time.perf_counter()
    deadline = t0 + seconds
    try:
        for _ in stub.streamScreenshot(req):
            frames += 1
            if time.perf_counter() >= deadline:
                break
    except grpc.RpcError as err:
        print(f"gRPC {err.code().name}: {err.details()}", file=sys.stderr)
    elapsed = time.perf_counter() - t0
    channel.close()
    return {
        "fps": frames / elapsed if elapsed else 0.0,
        "frames": frames,
        "elapsed": elapsed,
        "width": width,
        "height": height,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="localhost:8556")
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--width", type=int, default=900)
    ap.add_argument("--height", type=int, default=2000)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    r = measure(args.endpoint, args.seconds, args.width, args.height)
    if args.json:
        print(json.dumps(r))
    else:
        print(f"fps={r['fps']:.2f} frames={r['frames']} elapsed={r['elapsed']:.2f} "
              f"size={r['width']}x{r['height']}")
    # 一幀都沒收到 → 呼叫端該知道這次不可信。
    return 0 if r["frames"] > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
