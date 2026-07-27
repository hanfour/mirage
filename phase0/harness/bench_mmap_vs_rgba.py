"""streamScreenshot 對照基準：raw RGBA over gRPC vs MMAP 共享記憶體。

背景：upstream b/537802959 修正後（且實測明確帶 width/height 即可在現有 canary 繞過，
見 probe_mmap_explicit.py），MMAP 串流成為可用選項。本腳本量化它相對於現行 raw RGBA
路徑的收益，供「要不要在 MirageCore 實作 streaming MMAP transport」的決策使用。

量三件事：
  1. **幀率** —— 兩條路徑是否都能維持相同的出幀節奏
  2. **經 gRPC 的位元組/秒** —— 這是要消滅的序列化成本本身
  3. **兩端 CPU** —— client 端（反序列化）用 getrusage；emulator 端（序列化）用 ps 取
     qemu 行程的累計 CPU 時間差

用法（需 emulator 執行中）：
    python bench_mmap_vs_rgba.py --seconds 10 --width 900 --height 2000

腳本會自行啟動 animate.py 供應動畫（streamScreenshot 是變化驅動，靜止畫面不出幀）。
"""
import argparse
import hashlib
import os
import resource
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.mmap_source import frame_array, make_handle, open_frame_buffer

TARGET = "localhost:8554"


def qemu_cpu_seconds() -> float:
    """qemu 行程的累計 CPU 秒數；取不到回 -1（判讀時會標示不可用）。"""
    try:
        out = subprocess.run(
            ["ps", "-Ao", "pid,time,comm"], capture_output=True, text=True, check=True).stdout
    except Exception:
        return -1.0
    for line in out.splitlines():
        if "qemu-system-aarch64" in line:
            parts = line.split()
            hhmmss = parts[1]
            bits = [float(x) for x in hhmmss.replace("-", ":").split(":")]
            secs = 0.0
            for b in bits:
                secs = secs * 60 + b
            return secs
    return -1.0


def self_cpu_seconds() -> float:
    r = resource.getrusage(resource.RUSAGE_SELF)
    return r.ru_utime + r.ru_stime


def bench(mode: str, seconds: int, width: int, height: int) -> dict:
    """mode: 'rgba' | 'mmap'。回傳量測結果 dict。"""
    path = None
    buf = None
    kwargs = {"format": ec.ImageFormat.RGBA8888, "width": width, "height": height}
    if mode == "mmap":
        path = tempfile.mktemp(prefix="mirage_bench_", suffix=".bin")
        buf = open_frame_buffer(path, width, height)
        kwargs["transport"] = ec.ImageTransport(
            channel=ec.ImageTransport.MMAP, handle=make_handle(path))

    channel = grpc.insecure_channel(
        TARGET, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)
    fmt = ec.ImageFormat(**kwargs)

    frames = 0
    grpc_bytes = 0
    distinct = set()
    cpu0, qemu0 = self_cpu_seconds(), qemu_cpu_seconds()
    t0 = time.perf_counter()
    deadline = t0 + seconds
    try:
        for frame in stub.streamScreenshot(fmt):
            frames += 1
            grpc_bytes += len(frame.image)
            if mode == "mmap" and frames <= 5:
                arr = frame_array(buf, width, height)
                distinct.add(hashlib.md5(arr.tobytes()).hexdigest()[:8])
                del arr
            if time.perf_counter() >= deadline:
                break
    except grpc.RpcError as err:
        print(f"  gRPC {err.code().name}: {err.details()}", file=sys.stderr)
    elapsed = time.perf_counter() - t0
    cpu1, qemu1 = self_cpu_seconds(), qemu_cpu_seconds()
    if buf is not None:
        try:
            buf.close()
        except BufferError:
            pass
    channel.close()
    if path and os.path.exists(path):
        os.unlink(path)

    return {
        "mode": mode,
        "elapsed": elapsed,
        "frames": frames,
        "fps": frames / elapsed if elapsed else 0.0,
        "grpc_MiB_s": grpc_bytes / elapsed / 1024 / 1024 if elapsed else 0.0,
        "client_cpu_s": cpu1 - cpu0,
        "qemu_cpu_s": (qemu1 - qemu0) if (qemu0 >= 0 and qemu1 >= 0) else -1.0,
        "distinct_md5": len(distinct),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=10)
    ap.add_argument("--width", type=int, default=900)
    ap.add_argument("--height", type=int, default=2000)
    args = ap.parse_args()

    anim = subprocess.Popen(
        [sys.executable, "animate.py", "--seconds", str(args.seconds * 2 + 20)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3)
    try:
        print(f"解析度 {args.width}x{args.height}，各跑 {args.seconds} 秒\n")
        results = [bench("rgba", args.seconds, args.width, args.height),
                   bench("mmap", args.seconds, args.width, args.height)]
    finally:
        anim.terminate()

    hdr = f"{'模式':<6}{'fps':>8}{'gRPC MiB/s':>13}{'client CPU s':>14}{'qemu CPU s':>12}"
    print(hdr)
    print("-" * len(hdr))
    for r in results:
        q = f"{r['qemu_cpu_s']:.2f}" if r["qemu_cpu_s"] >= 0 else "n/a"
        print(f"{r['mode']:<6}{r['fps']:>8.1f}{r['grpc_MiB_s']:>13.1f}"
              f"{r['client_cpu_s']:>14.2f}{q:>12}")

    rgba, mmap_ = results
    print("\n=== 判讀 ===")
    if mmap_["frames"] == 0:
        print("MMAP 未出幀——量測無效")
        return 2
    if mmap_["distinct_md5"] < 2:
        print("⚠️ MMAP 緩衝區內容未變化：可能未真的寫入，數字不可信")
        return 2
    print(f"gRPC 傳輸量：{rgba['grpc_MiB_s']:.1f} → {mmap_['grpc_MiB_s']:.1f} MiB/s")
    if rgba["client_cpu_s"] > 0:
        print(f"client CPU：{rgba['client_cpu_s']:.2f}s → {mmap_['client_cpu_s']:.2f}s "
              f"（{(1 - mmap_['client_cpu_s'] / rgba['client_cpu_s']) * 100:.0f}% 降幅）")
    if rgba["qemu_cpu_s"] > 0 and mmap_["qemu_cpu_s"] >= 0:
        print(f"qemu CPU：{rgba['qemu_cpu_s']:.2f}s → {mmap_['qemu_cpu_s']:.2f}s")
    print(f"fps：{rgba['fps']:.1f} → {mmap_['fps']:.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
