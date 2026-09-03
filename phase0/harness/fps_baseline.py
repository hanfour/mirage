#!/usr/bin/env python3
"""D45 對照組：不經過 Mirage，直接消費 streamScreenshot 量 fps。

驗收線 7 的新判準 7a 要比「Mirage 的 fps」與「同條件下不經過 Mirage 的 fps」，
這支就是後者。

**為什麼不用 bench_mmap_vs_rgba.py**：那支會自己 Popen 啟動 animate.py 當動畫來源
（launcher 上的人造滑動），而 D45 的對照組必須量**跟 Mirage 側同一個遊戲畫面**——
`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §11.3 陷阱 1 記載過
「拿 launcher 當對照組」會量到靜止期。本檔刻意**不啟動任何動畫來源**，畫面由呼叫端
負責（D45 的量測腳本會讓 Pixel Flow 跑著）。

`--transport` 預設為 `rgba`，也可以選 `mmap`。兩種模式的狀態契約相同。

**四種結果狀態**（`status` 欄位，`--json` 與純文字輸出都看得到，退出碼也對應
分成四種，呼叫端不需要另外解析 stderr）：

| status     | 意義                                             | 退出碼 |
|------------|--------------------------------------------------|--------|
| `measured` | 量到至少 1 幀，`fps`/`frames`/`elapsed` 可信      | 0      |
| `static`   | 連線與 RPC 都正常，但畫面整個窗口沒變化、0 幀      | 2      |
| `stale`    | 收到幀但內容沒有變化，`frames > 0` 且 `distinct < 2` | 3      |
| `error`    | 連線或 RPC 本身失敗（非我們自己設的逾時）           | 1      |

`static` 是合法結果、不是失敗。`streamScreenshot` 是變化驅動的，畫面靜止時
本來就不會出幀。但它跟「量到 fps=0」不是同一件事，所以獨立成一個狀態，不能被
呼叫端誤當成一筆有效的 0 fps 樣本去算中位數。

`stale` 表示通知有來但內容沒有變化，必須與 `measured` 分開。

用法：
    python fps_baseline.py --seconds 20 --width 900 --height 2000
    python fps_baseline.py --seconds 20 --transport mmap --json
"""
import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
from typing import Any

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen"))

try:
    import grpc
except ImportError as err:
    grpc = None
    _GRPC_IMPORT_ERROR = err
else:
    _GRPC_IMPORT_ERROR = None

try:
    import emulator_controller_pb2 as pb
    import emulator_controller_pb2_grpc as pbg
except Exception as err:
    pb = None
    pbg = None
    _PROTO_IMPORT_ERROR = err
else:
    _PROTO_IMPORT_ERROR = None

from lib.mmap_source import frame_array, make_handle, open_frame_buffer

# RPC 層 timeout 比量測窗口（--seconds）多留的裕度。
#
# 為什麼需要裕度：streamScreenshot 是 server-streaming、變化驅動——client 端
# 自己的 deadline 判斷（下面迴圈裡的 time.perf_counter() >= deadline）只在
# 「收到一幀之後」才會被檢查。如果 RPC 的 timeout 跟量測窗口設成一樣長，兩個
# 計時器會在邊界上互搶：RPC 層可能在我們自己判斷「已經跑滿該收工」之前就先
# 炸 DeadlineExceeded，讓一次原本正常結束的量測被誤判成逾時路徑。
#
# 多留 2 秒裕度，讓「收到幀後自行判斷過期、乾淨 break」這條路徑在畫面持續有
# 變化時保證優先觸發；RPC 層的 timeout 只在畫面整個窗口都靜止、迴圈真的卡在
# 等下一幀時，才會是唯一能讓函式返回的機制。2 秒遠大於正常出幀間隔（幾十毫秒
# 等級），足夠當這個安全網、又不會讓「畫面靜止」的判定多等太久。
_TIMEOUT_MARGIN_SECONDS = 2.0

_EXIT_BY_STATUS = {"measured": 0, "error": 1, "static": 2, "stale": 3}
_FINGERPRINT_STRIDE = 4099


def status_for(frames: int, distinct: int, error: str | None) -> str:
    """將量測計數對映到狀態契約。"""
    if error is not None:
        return "error"
    if frames == 0:
        return "static"
    if distinct < 2:
        return "stale"
    return "measured"


def exit_code(status: str) -> int:
    """回傳狀態對應的程序退出碼。"""
    return _EXIT_BY_STATUS[status]


def count_distinct(sources: list[Any]) -> int:
    """以取樣指紋計算整個窗口內不重複的畫面內容數。"""
    return len({_frame_fingerprint(source) for source in sources})


def _temp_path() -> str:
    """在系統暫存目錄取得絕對路徑，交給 open_frame_buffer 建立檔案。"""
    fd, path = tempfile.mkstemp(
        prefix="mirage_fps_", suffix=".bin", dir=tempfile.gettempdir())
    os.close(fd)
    path = os.path.abspath(path)
    os.unlink(path)
    return path


def _frame_fingerprint(source) -> bytes:
    """每隔固定位元組取樣，避免為了 distinct 複製整張畫面。"""
    view = memoryview(source)
    if view.ndim != 1 or view.format != "B":
        view = view.cast("B")
    if not view.c_contiguous:
        raise ValueError("畫面內容必須是連續的位元組緩衝區")

    sampled = bytearray()
    for offset in range(0, len(view), _FINGERPRINT_STRIDE):
        sampled.append(view[offset])
    return hashlib.blake2b(sampled, digest_size=8).digest()


def _require_grpc():
    if grpc is None:
        raise RuntimeError(f"找不到 grpc：{_GRPC_IMPORT_ERROR}")
    return grpc


def _require_proto():
    if pb is None or pbg is None:
        raise RuntimeError(
            "找不到 phase0/harness/gen 的 protobuf 生成碼，請先依 phase0/harness/README-venv.md 準備 gen/"
        ) from _PROTO_IMPORT_ERROR
    return pb, pbg


def make_image_format(
    transport: str,
    width: int,
    height: int,
    *,
    handle: str | None = None,
    pb_module=None,
):
    """建立 rgba 或 mmap 的 ImageFormat 請求。"""
    proto = pb_module or _require_proto()[0]
    kwargs = {
        "format": proto.ImageFormat.RGBA8888,
        "width": width,
        "height": height,
    }
    if transport == "mmap":
        if handle is None:
            raise ValueError("mmap 模式缺少緩衝區路徑")
        kwargs["transport"] = proto.ImageTransport(
            channel=proto.ImageTransport.MMAP,
            handle=handle,
        )
    elif transport != "rgba":
        raise ValueError(f"不支援的 transport：{transport}")
    return proto.ImageFormat(**kwargs)


def _image_format(
    transport: str,
    width: int,
    height: int,
    mmap_path: str | None,
    pb_module=None,
):
    handle = make_handle(mmap_path) if mmap_path is not None else None
    return make_image_format(
        transport, width, height, handle=handle, pb_module=pb_module)


def measure(
    endpoint: str,
    seconds: int,
    width: int,
    height: int,
    transport: str = "rgba",
    *,
    stub=None,
    channel_factory=None,
    buffer_factory=None,
    frame_array_fn=None,
    frame_source_factory=None,
    temp_path_factory=None,
    pb_module=None,
) -> dict:
    """跑 `seconds` 秒，回傳 fps、原始計數、與狀態契約中的 `status`。

    只計「真的收到的幀」。streamScreenshot 是變化驅動的，畫面靜止時本來就不出幀，
    所以呼叫端必須保證畫面在動，否則量到的是靜止期而不是效能。

    `stub` 與 MMAP 的內容來源可注入，讓測試不需要 emulator。
    """
    if transport not in ("rgba", "mmap"):
        raise ValueError(f"不支援的 transport：{transport}")

    buffer_factory = buffer_factory or open_frame_buffer
    frame_source_factory = frame_source_factory or frame_array_fn or frame_array
    temp_path_factory = temp_path_factory or _temp_path

    mmap_path = None
    buffer = None
    channel = None
    frames = 0
    fingerprints = set()
    error_message = None
    frame_source = None
    try:
        if stub is None:
            grpc_module = _require_grpc()
            channel_factory = channel_factory or grpc_module.insecure_channel
            channel = channel_factory(endpoint, options=[
                ("grpc.max_receive_message_length", 64 * 1024 * 1024),
            ])
            active_stub = _require_proto()[1].EmulatorControllerStub(channel)
        else:
            active_stub = stub
        if transport == "mmap":
            mmap_path = temp_path_factory()
            buffer = buffer_factory(mmap_path, width, height)
        req = _image_format(transport, width, height, mmap_path, pb_module=pb_module)

        t0 = time.perf_counter()
        deadline = t0 + seconds
        rpc_timeout = seconds + _TIMEOUT_MARGIN_SECONDS
        try:
            for frame in active_stub.streamScreenshot(req, timeout=rpc_timeout):
                frames += 1
                if transport == "rgba":
                    frame_source = frame.image
                else:
                    frame_source = frame_source_factory(buffer, width, height)
                fingerprints.add(_frame_fingerprint(frame_source))
                frame_source = None
                if time.perf_counter() >= deadline:
                    break
        except Exception as err:
            is_rpc_error = grpc is not None and isinstance(err, grpc.RpcError)
            if is_rpc_error and err.code() == grpc.StatusCode.DEADLINE_EXCEEDED:
                # 預期路徑：畫面在量測窗口內沒有再變化，串流卡在等下一幀。
                pass
            elif is_rpc_error:
                error_message = f"{err.code().name}: {err.details()}"
                print(f"gRPC {error_message}", file=sys.stderr)
            else:
                error_message = f"{type(err).__name__}: {err}"
                print(f"量測失敗：{error_message}", file=sys.stderr)
    finally:
        frame_source = None
        if buffer is not None:
            close_buffer = getattr(buffer, "close", None)
            if close_buffer is not None:
                try:
                    close_buffer()
                except BufferError:
                    error_message = error_message or "BufferError: 緩衝區仍有未釋放的檢視"
        if mmap_path is not None:
            try:
                os.unlink(mmap_path)
            except FileNotFoundError:
                pass
        if channel is not None:
            channel.close()

    elapsed = time.perf_counter() - t0
    distinct = len(fingerprints)
    status = status_for(frames, distinct, error_message)

    return {
        "status": status,
        "error": error_message,
        "fps": frames / elapsed if elapsed else 0.0,
        "frames": frames,
        "elapsed": elapsed,
        "width": width,
        "height": height,
        "transport": transport,
        "distinct": distinct,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="localhost:8556")
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--width", type=int, default=900)
    ap.add_argument("--height", type=int, default=2000)
    ap.add_argument("--transport", choices=("rgba", "mmap"), default="rgba")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    try:
        r = measure(args.endpoint, args.seconds, args.width, args.height,
                    transport=args.transport)
    except RuntimeError as err:
        print(f"❌ {err}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(r))
    else:
        line = (f"fps={r['fps']:.2f} frames={r['frames']} elapsed={r['elapsed']:.2f} "
                f"size={r['width']}x{r['height']} status={r['status']}")
        if r["error"]:
            line += f" error={r['error'].replace(' ', '_')}"
        line += f" transport={r['transport']} distinct={r['distinct']}"
        print(line)
    return exit_code(r["status"])


if __name__ == "__main__":
    sys.exit(main())
