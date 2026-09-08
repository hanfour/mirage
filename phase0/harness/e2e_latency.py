"""Emulator 端診斷，對偵測門檻敏感，不作為驗收線 2 的結果。

需要可見的觸控回饋。操作後須關閉 show_touches 或 pointer_location，
本程式不修改 guest 設定。觸控座標採 guest 像素，偵測區域採實際串流尺寸。
"""
import argparse
import collections
from dataclasses import dataclass
from pathlib import Path
import sys
import threading
import time

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent / "gen"))
from lib.stats import percentile


@dataclass
class Sample:
    seq: int
    arrived: float
    generated: float
    region: np.ndarray


def region(image, width, height, x, y, radius):
    """RGBA 實際由上往下排列，與 proto 註解不同。"""
    pixels = np.frombuffer(image, dtype=np.uint8).reshape(height, width, 4)
    x0, x1 = max(0, x-radius), min(width, x+radius)
    y0, y1 = max(0, y-radius), min(height, y+radius)
    if x0 >= x1 or y0 >= y1:
        raise ValueError("detection region outside frame")
    return pixels[y0:y1, x0:x1, :3].astype(np.int16)


def difference_pixels(current, baseline):
    return int(np.count_nonzero(np.any(np.abs(current-baseline) > 30, axis=2)))


def scan(snapshot, cursor, baseline, ack, thresholds, hits):
    """即使有容量上限的 deque 已滿，序號游標仍持續前進。"""
    for sample in snapshot:
        if sample.seq <= cursor:
            continue
        cursor = sample.seq
        if sample.generated < ack:
            continue
        changed = difference_pixels(sample.region, baseline)
        for threshold in thresholds:
            if threshold not in hits and changed >= threshold:
                hits[threshold] = sample
    return cursor


def summarize(label, rows, total):
    print(f"{label} n={len(rows)} misses={total-len(rows)}; statistics exclude misses")
    for index, segment in enumerate(("send_to_ack", "ack_to_generated", "transit", "total")):
        values = [row[index] for row in rows]
        if values:
            print(f"  {segment} p50={percentile(values, 50):.1f}ms "
                  f"p95={percentile(values, 95):.1f}ms")
        else:
            print(f"  {segment} p50=NA p95=NA")


def sensitivity(low, high):
    if not low or not high:
        return "這個數字由門檻決定，不可引用（缺少可比較樣本）"
    a, b = percentile(low, 50), percentile(high, 50)
    if abs(b-a) > abs(a)*0.20:
        return "這個數字由門檻決定，不可引用"
    return "threshold p50 difference <=20%; diagnostic only"


def latency_row(sent, ack, hit):
    """負值整筆排除，由呼叫端計數，避免污染任一段統計。"""
    row = ((ack-sent)*1000, (hit.generated-ack)*1000,
           (hit.arrived-hit.generated)*1000, (hit.arrived-sent)*1000)
    return None if any(value < 0 for value in row) else row


def matched_sensitivity(results, thresholds):
    """只比較三門檻皆命中的同一批觸控。"""
    common = set.intersection(*(set(results[t]) for t in thresholds))
    print(f"三門檻皆命中的樣本數={len(common)}")
    return sensitivity([results[thresholds[0]][i][3] for i in common],
                       [results[thresholds[2]][i][3] for i in common])


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", default="localhost:8556")
    for name, default in (("width", 540), ("height", 1200), ("guest-width", 1080),
                          ("guest-height", 2400), ("x", 540), ("y", 480),
                          ("samples", 40), ("radius", 30)):
        parser.add_argument("--"+name, type=int, default=default)
    parser.add_argument("--threshold", type=float, default=200)
    parser.add_argument("--timeout", type=float, default=2)
    args = parser.parse_args(argv)
    for key in ("width", "height", "guest_width", "guest_height", "samples", "threshold", "radius", "timeout"):
        if not np.isfinite(getattr(args, key)) or getattr(args, key) <= 0:
            parser.error(f"{key} must be positive and finite")
    if not (0 <= args.x < args.guest_width and 0 <= args.y < args.guest_height):
        parser.error("touch coordinates outside guest")
    return args


def main(argv=None):
    args = arguments(argv)
    import grpc
    import emulator_controller_pb2 as ec
    import emulator_controller_pb2_grpc as ecg

    samples = collections.deque(maxlen=600)
    lock = threading.Lock()
    errors = []
    stop = threading.Event()
    thresholds = (args.threshold*0.25, args.threshold, args.threshold*4)
    results = {threshold: {} for threshold in thresholds}
    negative = {threshold: 0 for threshold in thresholds}
    channel = grpc.insecure_channel(args.target, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)
    call = stub.streamScreenshot(ec.ImageFormat(format=ec.ImageFormat.RGBA8888,
                                                width=args.width, height=args.height))

    def worker():
        try:
            previous = None
            for frame in call:
                arrived = time.time()
                if stop.is_set():
                    break
                if previous is not None and frame.seq <= previous:
                    raise ValueError("stream sequence is not increasing")
                previous = frame.seq
                w, h = frame.format.width, frame.format.height
                crop = region(frame.image, w, h, args.x*w//args.guest_width,
                              args.y*h//args.guest_height, args.radius)
                with lock:
                    samples.append(Sample(frame.seq, arrived, frame.timestampUs/1e6, crop))
        except Exception as error:
            if not stop.is_set():
                errors.append(str(error))

    def tap(down):
        stub.sendTouch(ec.TouchEvent(touches=[ec.Touch(x=args.x, y=args.y,
                       identifier=0, pressure=1024 if down else 0)]), timeout=2)

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic()+5
        while not samples and not errors and time.monotonic() < deadline:
            time.sleep(0.01)
        if not samples:
            raise RuntimeError(f"no stream frames: {errors}")
        for touch in range(args.samples):
            if errors:
                raise RuntimeError(errors[0])
            with lock:
                baseline = samples[-1]
            cursor = baseline.seq
            hits = {}
            sent = time.time()
            try:
                tap(True)
                ack = time.time()
                deadline = time.monotonic()+args.timeout
                while time.monotonic() < deadline and len(hits) < len(thresholds):
                    if errors:
                        raise RuntimeError(errors[0])
                    with lock:
                        snapshot = list(samples)
                    cursor = scan(snapshot, cursor, baseline.region, ack, thresholds, hits)
                    time.sleep(0.001)
            finally:
                tap(False)
            for threshold, hit in hits.items():
                row = latency_row(sent, ack, hit)
                if row is None:
                    negative[threshold] += 1
                else:
                    results[threshold][touch] = row
            time.sleep(0.5)
    finally:
        stop.set()
        call.cancel()
        channel.close()
        thread.join(timeout=3)
    for threshold in thresholds:
        print(f"threshold={threshold:g} negative={negative[threshold]}")
        summarize(f"threshold={threshold:g}", list(results[threshold].values()), args.samples)
    print(matched_sensitivity(results, thresholds))
    print("Guest reaction and detection animation included; not acceptance 2.")
    return 0 if results[args.threshold] else 1


if __name__ == "__main__":
    sys.exit(main())
