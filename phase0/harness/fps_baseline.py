#!/usr/bin/env python3
"""D45 對照組：不經過 Mirage，直接消費 streamScreenshot 量 fps。

驗收線 7 的新判準 7a 要比「Mirage 的 fps」與「同條件下不經過 Mirage 的 fps」，
這支就是後者。

**為什麼不用 bench_mmap_vs_rgba.py**：那支會自己 Popen 啟動 animate.py 當動畫來源
（launcher 上的人造滑動），而 D45 的對照組必須量**跟 Mirage 側同一個遊戲畫面**——
`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §11.3 陷阱 1 記載過
「拿 launcher 當對照組」會量到靜止期。本檔刻意**不啟動任何動畫來源**，畫面由呼叫端
負責（D45 的量測腳本會讓 Pixel Flow 跑著）。

它也只跑 rgba 一種模式——D45 不關心 MMAP。

**三種結果狀態**（`status` 欄位，`--json` 與純文字輸出都看得到，退出碼也對應
分成三種，呼叫端不需要另外解析 stderr）：

| status     | 意義                                             | 退出碼 |
|------------|--------------------------------------------------|--------|
| `measured` | 量到至少 1 幀，`fps`/`frames`/`elapsed` 可信      | 0      |
| `static`   | 連線與 RPC 都正常，但畫面整個窗口沒變化、0 幀      | 2      |
| `error`    | 連線或 RPC 本身失敗（非我們自己設的逾時）           | 1      |

`static` 是合法結果、不是失敗——`streamScreenshot` 是變化驅動的，畫面靜止時
本來就不會出幀。但它跟「量到 fps=0」不是同一件事，所以獨立成一個狀態，不能被
呼叫端誤當成一筆有效的 0 fps 樣本去算中位數。

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

_EXIT_BY_STATUS = {"measured": 0, "error": 1, "static": 2}


def measure(endpoint: str, seconds: int, width: int, height: int) -> dict:
    """跑 `seconds` 秒，回傳 fps、原始計數、與三種狀態之一的 `status`。

    只計「真的收到的幀」——streamScreenshot 是變化驅動的，畫面靜止時本來就不出幀，
    所以呼叫端必須保證畫面在動，否則量到的是靜止期而不是效能。

    `status` 的三種值見本檔頂端 docstring 的表格：
    "measured"（正常量到）／"static"（合法但無樣本）／"error"（工具或連線失敗）。
    """
    channel = grpc.insecure_channel(endpoint, options=[
        ("grpc.max_receive_message_length", 64 * 1024 * 1024),
    ])
    stub = pbg.EmulatorControllerStub(channel)
    req = pb.ImageFormat(format=pb.ImageFormat.RGBA8888,
                         width=width, height=height)
    frames = 0
    error_message = None
    t0 = time.perf_counter()
    deadline = t0 + seconds
    rpc_timeout = seconds + _TIMEOUT_MARGIN_SECONDS
    try:
        for _ in stub.streamScreenshot(req, timeout=rpc_timeout):
            frames += 1
            if time.perf_counter() >= deadline:
                break
    except grpc.RpcError as err:
        if err.code() == grpc.StatusCode.DEADLINE_EXCEEDED:
            # 預期路徑：畫面在量測窗口內沒有（再）變化，streamScreenshot 卡在
            # 等下一幀，靠我們自己設的 RPC timeout 收工——不是錯誤，見上面
            # _TIMEOUT_MARGIN_SECONDS 的說明。frames 是 0 還是 >0 決定下面
            # status 判給 "static" 還是 "measured"。
            pass
        else:
            error_message = f"{err.code().name}: {err.details()}"
            print(f"gRPC {error_message}", file=sys.stderr)
    elapsed = time.perf_counter() - t0
    channel.close()

    if error_message is not None:
        status = "error"
    elif frames == 0:
        status = "static"
    else:
        status = "measured"

    return {
        "status": status,
        "error": error_message,
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
        line = (f"fps={r['fps']:.2f} frames={r['frames']} elapsed={r['elapsed']:.2f} "
                f"size={r['width']}x{r['height']} status={r['status']}")
        if r["error"]:
            line += f" error={r['error'].replace(' ', '_')}"
        print(line)
    return _EXIT_BY_STATUS[r["status"]]


if __name__ == "__main__":
    sys.exit(main())
