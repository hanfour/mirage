"""端到端 input-to-photon 量測（不含 Mac 上屏，判讀時另加 8–17ms）。

前置：emulator 執行中，且已執行
  adb shell settings put system show_touches 1
"""
import collections
import sys
import threading
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.detector import changed, region_mean
from lib.stats import percentile

TARGET = "localhost:8554"
N_SAMPLES = 50
TAP_X, TAP_Y = 540, 1200
RADIUS = 60          # show_touches 圓點半徑內
THRESHOLD = 8.0      # 亮度偏離基線的判定門檻
STIR_X, STIR_Y = 150, 300  # 遠離偵測區的攪動點，喚醒 change-driven 串流
Sample = collections.namedtuple("Sample", ["t", "mean"])


def send_tap(stub, x: int, y: int, down: bool) -> None:
    touch = ec.Touch(x=x, y=y, identifier=0, pressure=1024 if down else 0)
    stub.sendTouch(ec.TouchEvent(touches=[touch]), timeout=2)


def stream_worker(stub, samples: collections.deque, stop: threading.Event) -> None:
    req = ec.ImageFormat(format=ec.ImageFormat.RGBA8888)
    for frame in stub.streamScreenshot(req):
        if stop.is_set():
            return
        mean = region_mean(bytes(frame.image),
                           frame.format.width, frame.format.height,
                           TAP_X, TAP_Y, RADIUS)
        samples.append(Sample(time.monotonic(), mean))


def wait_first_change(samples, t0: float, baseline: float, timeout_s: float = 2.0):
    deadline = time.monotonic() + timeout_s
    seen = 0
    while time.monotonic() < deadline:
        snapshot = list(samples)
        for s in snapshot[seen:]:
            if s.t > t0 and changed(s.mean, baseline, THRESHOLD):
                return s.t
        seen = len(snapshot)
        time.sleep(0.001)
    return None


def main() -> int:
    # 原生解析度的 RGBA8888 單幀 > 10MiB，超過 grpc-python 預設 4MiB
    # 接收上限（RESOURCE_EXHAUSTED）。Task 4 已確認此為必要調整，非欄位錯誤。
    channel = grpc.insecure_channel(
        TARGET, options=[("grpc.max_receive_message_length", -1)]
    )
    stub = ecg.EmulatorControllerStub(channel)
    samples: collections.deque = collections.deque(maxlen=600)
    stop = threading.Event()
    threading.Thread(target=stream_worker, args=(stub, samples, stop),
                     daemon=True).start()

    # streamScreenshot 是 change-driven：靜止畫面下 2 秒內只會收到「連線當下」
    # 那 1 幀（實測 3 次皆為 1），< 10 的原始門檻永遠不可能達成。輕輕攪動偵測區
    # 外的畫面（3 次快速點擊 STIR_X/STIR_Y，遠離 TAP_X/TAP_Y 的偵測半徑，不污染
    # 基線）喚醒串流；實測攪動後 2 秒內可收到 38 幀，遠超原門檻，因此門檻本身
    # 不必調整。
    for _ in range(3):
        send_tap(stub, STIR_X, STIR_Y, down=True)
        time.sleep(0.05)
        send_tap(stub, STIR_X, STIR_Y, down=False)
        time.sleep(0.15)
    time.sleep(1.4)  # 加上攪動耗時，湊足約 2 秒基線蒐集窗口
    if len(samples) < 10:
        print("FAIL: 串流無幀，確認 emulator 與動畫來源", file=sys.stderr)
        return 1

    latencies_ms: list[float] = []
    misses = 0
    for _ in range(N_SAMPLES):
        baseline = percentile([s.mean for s in list(samples)[-30:]], 50)
        t0 = time.monotonic()
        send_tap(stub, TAP_X, TAP_Y, down=True)
        t1 = wait_first_change(samples, t0, baseline)
        send_tap(stub, TAP_X, TAP_Y, down=False)
        if t1 is None:
            misses += 1
        else:
            latencies_ms.append((t1 - t0) * 1000)
        time.sleep(0.5)  # 等圓點淡出、畫面回穩

    stop.set()
    if not latencies_ms:
        print("FAIL: 全部樣本未偵測到變化——確認 show_touches 已開", file=sys.stderr)
        return 1
    print(f"n={len(latencies_ms)} misses={misses} "
          f"p50={percentile(latencies_ms, 50):.1f}ms "
          f"p95={percentile(latencies_ms, 95):.1f}ms")
    print("註：此值不含 Mac 上屏與螢幕反應，對照 80ms 上限時請加 8–17ms。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
