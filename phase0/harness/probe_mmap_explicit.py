"""MMAP 串流：明確帶 width/height 的對照實驗（upstream b/537802959 回覆後）。

Google 於 2026-07-23 接受並定位此 bug，2026-07-25 標記 fixed，根因原文：

    At the beginning of streamScreenshot, the server attempted to pre-borrow the
    shared memory region using request->width() * request->height(), which can be
    0 when requesting the device width and height, poisoning the cache.

我們原本的 repro（`probe_mmap.py`）建構的 `ImageFormat` **不帶 width/height**，
即請求裝置原生尺寸 → 兩者為 0 → pre-borrow 用 0 大小 → 毒化 cache。這正是根因描述
的情境。

**本腳本的唯一差別**：在 `ImageFormat` 裡明確填入非 0 的 `width`/`height`。
若 host 寫入端因此恢復正常，代表在**現有 canary 上就有可用的繞道**，不必等新版
emulator——這對 Mirage 的意義是每幀省下 ~10 MiB 的 protobuf 序列化。

用法（需 emulator 執行中；另開終端跑 `python animate.py --seconds 30` 供應動畫）：
    cd phase0/harness && python probe_mmap_explicit.py

⚠️ 穩定版 emulator 36.6.11.0 上 MMAP 串流會使引擎崩潰（見 probe_mmap.py 的警告）。
本腳本僅應對 canary 37.2.1.0 以上執行。
"""
import hashlib
import sys
import tempfile

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.mmap_source import frame_array, make_handle, open_frame_buffer

TARGET = "localhost:8554"
GUEST_W, GUEST_H = 1080, 2400
N_PROBE_FRAMES = 5


def probe(explicit_size: bool) -> tuple[int, int, bool]:
    """回傳 (distinct_hash 數, 收到的幀數, 是否曾出現非零內容)。"""
    path = tempfile.mktemp(prefix="mirage_mmap_", suffix=".bin")
    buf = open_frame_buffer(path, GUEST_W, GUEST_H)
    channel = grpc.insecure_channel(
        TARGET, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)

    kwargs = {
        "format": ec.ImageFormat.RGBA8888,
        "transport": ec.ImageTransport(
            channel=ec.ImageTransport.MMAP, handle=make_handle(path)),
    }
    if explicit_size:
        kwargs["width"] = GUEST_W
        kwargs["height"] = GUEST_H
    fmt = ec.ImageFormat(**kwargs)

    label = "明確 width/height" if explicit_size else "不帶 width/height（原 repro）"
    print(f"\n--- {label} ---")
    hashes, any_nonzero, count = [], False, 0
    try:
        for i, frame in enumerate(stub.streamScreenshot(fmt)):
            arr = frame_array(buf, GUEST_W, GUEST_H)
            digest = hashlib.md5(arr.tobytes()).hexdigest()[:12]
            nonzero = bool(arr.any())
            del arr                      # 釋放對 mmap 的 export，否則 buf.close() 會 BufferError
            any_nonzero = any_nonzero or nonzero
            hashes.append(digest)
            count += 1
            print(f"  frame {i}: payload={len(frame.image)}B "
                  f"reported={frame.format.width}x{frame.format.height} "
                  f"md5={digest} nonzero={nonzero}")
            if i + 1 >= N_PROBE_FRAMES:
                break
    except grpc.RpcError as err:
        print(f"  gRPC {err.code().name}: {err.details()}", file=sys.stderr)
    finally:
        try:
            buf.close()
        except BufferError:
            pass                         # 迴圈提早 break 時仍可能有殘存 export，不影響判讀
        channel.close()
    return len(set(hashes)), count, any_nonzero


def main() -> int:
    print("對照實驗：upstream b/537802959 根因是 pre-borrow 用了 0x0 尺寸。")
    print("若『明確 width/height』寫入資料而『不帶』不寫，即證實可在現有版本繞道。")

    d_off, n_off, nz_off = probe(explicit_size=False)
    d_on, n_on, nz_on = probe(explicit_size=True)

    print("\n=== 判讀 ===")
    print(f"不帶尺寸    : 幀數={n_off} 相異雜湊={d_off} 曾非零={nz_off}")
    print(f"明確帶尺寸  : 幀數={n_on} 相異雜湊={d_on} 曾非零={nz_on}")
    if nz_on and d_on >= 2 and not nz_off:
        print("→ WORKAROUND_CONFIRMED：明確尺寸可用，現有版本即可走 MMAP 串流")
        return 0
    if nz_on and nz_off:
        print("→ BOTH_WORK：兩者皆正常，代表跑的 emulator 已含修正")
        return 0
    if not nz_on:
        print("→ STILL_BROKEN：明確尺寸仍未寫入，需要含修正的新版 emulator")
        return 2
    print("→ INCONCLUSIVE：結果不符任何預期樣態，需人工判讀上面的逐幀輸出")
    return 3


if __name__ == "__main__":
    sys.exit(main())
