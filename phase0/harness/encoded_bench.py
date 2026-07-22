# phase0/harness/encoded_bench.py
"""編碼串流路徑基準：guest H.264 編碼（screenrecord）→ adb 管線 → PyAV 解碼。

  python encoded_bench.py --mode fps --seconds 15   # 解碼幀率（配 animate.py）
  python encoded_bench.py --mode e2e --samples 30   # 端到端延遲（show_touches 需先開）
量測含 guest 編碼 + 傳輸 + 主機解碼——與 MMAP/gRPC 數字同一把尺（不含上屏）。
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, "gen")

import av
import grpc
import numpy as np
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.stats import percentile, summarize

ADB = os.path.expanduser(
    os.environ.get("ANDROID_SDK_ROOT", "~/Library/Android/sdk")
) + "/platform-tools/adb"
TARGET = "localhost:8554"
TAP_X, TAP_Y, RADIUS, THRESHOLD = 540, 1200, 60, 8.0


def open_decoder(seconds: int):
    # 診斷梯（task-5-brief 已知風險）：--output-format=h264 在此 guest 映像的
    # 原生解析度（1080x2400）下輸出恆為 0 bytes，av.open() 直接
    # InvalidDataError（見 task-5-report.md）。加 --size 720x1600 後才有非空
    # bytes 可解碼——這是梯子第 3 步「加 --size」的最小 flag 修正，非邏輯改動。
    proc = subprocess.Popen(
        [ADB, "exec-out", "screenrecord", "--output-format=h264",
         "--size", "720x1600",
         "--bit-rate", "8000000", "--time-limit", str(seconds), "-"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    container = av.open(proc.stdout, format="h264")
    return proc, container


def decoded_frames(container):
    for packet in container.demux(video=0):
        for frame in packet.decode():
            yield time.monotonic(), frame


def mode_fps(seconds: int) -> int:
    proc, container = open_decoder(seconds)
    timestamps = [t for t, _ in decoded_frames(container)]
    proc.wait()
    if len(timestamps) < 2:
        print("FAIL: 無解碼幀——確認 animate.py 供應動畫、guest 支援 screenrecord",
              file=sys.stderr)
        return 1
    s = summarize(timestamps[5:])  # 丟 5 幀 warm-up（Phase 0 慣例）
    print(f"mode=fps frames={s.frames} fps={s.fps:.1f} "
          f"p50={s.p50_ms:.1f}ms p95={s.p95_ms:.1f}ms transport=h264")
    return 0


def region_mean_rgb(frame: "av.VideoFrame") -> float:
    arr = frame.to_ndarray(format="rgb24")
    h, w = arr.shape[:2]
    sy, sx = h / 2400, w / 1080  # screenrecord 可能縮放輸出
    cy, cx = int(TAP_Y * sy), int(TAP_X * sx)
    r = max(int(RADIUS * sy), 8)
    return float(arr[max(cy - r, 0):cy + r, max(cx - r, 0):cx + r].mean())


def mode_e2e(samples_n: int) -> int:
    stub = ecg.EmulatorControllerStub(grpc.insecure_channel(TARGET))

    def tap(down: bool) -> None:
        touch = ec.Touch(x=TAP_X, y=TAP_Y, identifier=0,
                         pressure=1024 if down else 0)
        stub.sendTouch(ec.TouchEvent(touches=[touch]), timeout=2)

    proc, container = open_decoder(samples_n * 2 + 10)
    gen = decoded_frames(container)
    baseline_means = [region_mean_rgb(f) for _, f in
                      (next(gen) for _ in range(10))]
    baseline = percentile(baseline_means, 50)

    latencies, misses = [], 0
    for _ in range(samples_n):
        t0 = time.monotonic()
        tap(down=True)
        t1 = None
        for t, f in gen:
            if t - t0 > 2.0:
                break
            if abs(region_mean_rgb(f) - baseline) > THRESHOLD:
                t1 = t
                break
        tap(down=False)
        if t1 is None:
            misses += 1
        else:
            latencies.append((t1 - t0) * 1000)
        time.sleep(0.4)
    proc.kill()
    if not latencies:
        print("FAIL: 全 miss——確認 show_touches=1", file=sys.stderr)
        return 1
    print(f"mode=e2e n={len(latencies)} misses={misses} "
          f"p50={percentile(latencies, 50):.1f}ms "
          f"p95={percentile(latencies, 95):.1f}ms transport=h264")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("fps", "e2e"), required=True)
    parser.add_argument("--seconds", type=int, default=15)
    parser.add_argument("--samples", type=int, default=30)
    args = parser.parse_args()
    if args.seconds < 5 or args.samples < 5:
        parser.error("--seconds ≥5、--samples ≥5")
    return mode_fps(args.seconds) if args.mode == "fps" else mode_e2e(args.samples)


if __name__ == "__main__":
    sys.exit(main())
