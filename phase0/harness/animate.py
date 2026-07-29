"""持續動畫來源：gRPC sendTouch ~120Hz 連續注入圓形拖曳。

`streamScreenshot` 是變化驅動（change-driven）的，靜止畫面完全不出幀，因此任何
fps/延遲量測都需要搭配持續的動畫來源（見 RESULTS.md「Change-driven stream
特性」）。本腳本開啟 `pointer_location` 疊層（保證每次 move 都觸發重繪），在
guest 螢幕中央持續畫圓，供 `stream_bench.py` 等量測腳本在另一終端使用。

用法：
  python animate.py                                    # 5554，執行到 Ctrl-C
  python animate.py --seconds 30                       # 執行 30 秒後自動停止
  python animate.py --serial emulator-5556 --port 8556 # 指定機台
"""
import argparse
import math
import os
import subprocess
import sys
import time

# 相對路徑只在「從 harness 目錄執行」時成立——換個 cwd 就 ModuleNotFoundError，
# 而錯誤訊息指向 pb2、完全看不出是 cwd 的問題（實測浪費了一輪量測）。
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen"))

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg

CENTER_X, CENTER_Y = 540, 1200
RADIUS = 300
ANGULAR_STEP = 0.15  # 弧度／步
STEP_SLEEP_S = 0.008  # 與 ANGULAR_STEP 搭配約得 ~120Hz
TOUCH_IDENTIFIER = 0
TOUCH_DOWN_PRESSURE = 1024
TOUCH_UP_PRESSURE = 0
RPC_TIMEOUT_S = 2


def resolve_adb() -> str:
    sdk_root = os.environ.get("ANDROID_SDK_ROOT") or os.path.expanduser(
        "~/Library/Android/sdk"
    )
    return os.path.join(sdk_root, "platform-tools", "adb")


def set_pointer_location(adb: str, serial: str, enabled: bool) -> None:
    """`-s serial` 不可省略。本機同時跑三台模擬器（見 phase1-game-recon），
    不指定裝置時 adb 直接以 "more than one device/emulator" 失敗——而這個
    失敗會讓整支腳本掛掉、量測端卻只看到「串流無幀」，往完全錯的方向查。"""
    subprocess.run(
        [adb, "-s", serial, "shell", "settings", "put", "system",
         "pointer_location", "1" if enabled else "0"],
        check=True,
    )


def circle_point(t: float) -> tuple[int, int]:
    x = int(CENTER_X + RADIUS * math.cos(t))
    y = int(CENTER_Y + RADIUS * math.sin(t))
    return x, y


def send_touch(stub: ecg.EmulatorControllerStub, x: int, y: int,
                pressure: int) -> None:
    touch = ec.Touch(x=x, y=y, identifier=TOUCH_IDENTIFIER, pressure=pressure)
    stub.sendTouch(ec.TouchEvent(touches=[touch]), timeout=RPC_TIMEOUT_S)


def run_animation(stub: ecg.EmulatorControllerStub, seconds: float) -> int:
    """持續注入圓形拖曳直到逾時或 Ctrl-C；回傳被丟棄（RPC 失敗）的次數。"""
    t = 0.0
    dropped = 0
    deadline = None if seconds <= 0 else time.monotonic() + seconds
    try:
        while deadline is None or time.monotonic() < deadline:
            x, y = circle_point(t)
            try:
                send_touch(stub, x, y, TOUCH_DOWN_PRESSURE)
            except grpc.RpcError:
                dropped += 1
            t += ANGULAR_STEP
            time.sleep(STEP_SLEEP_S)
    except KeyboardInterrupt:
        print("animate: 收到 Ctrl-C，停止注入")
    return dropped


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=0,
                         help="執行秒數；0（預設）= 執行到 Ctrl-C")
    parser.add_argument("--serial", default="emulator-5554",
                         help="adb 裝置序號（本機有三台，必須指定；預設 emulator-5554）")
    parser.add_argument("--port", type=int, default=8554,
                         help="emulator 的 gRPC 連接埠（預設 8554）")
    args = parser.parse_args()
    if args.seconds < 0:
        parser.error("--seconds 不可為負數")
    return args


def main() -> int:
    args = parse_args()
    adb = resolve_adb()
    channel = grpc.insecure_channel(f"localhost:{args.port}")
    stub = ecg.EmulatorControllerStub(channel)

    set_pointer_location(adb, args.serial, enabled=True)
    try:
        dropped = run_animation(stub, args.seconds)
        print(f"animate: 結束，丟棄 RPC 次數={dropped}")
    finally:
        try:
            send_touch(stub, CENTER_X, CENTER_Y, TOUCH_UP_PRESSURE)
        except grpc.RpcError as err:
            print(f"animate: 收尾 touch-up 失敗：{err.code().name}",
                  file=sys.stderr)
        set_pointer_location(adb, args.serial, enabled=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
