"""送已知座標的 sendTouch，用 adb getevent 讀回 guest 實際收到的座標。

回答一個問題：`Touch.x/y` 的座標系是「guest 實體螢幕解析度」還是「串流影像尺寸」？
proto 寫的是 "physical location on the screen"，本腳本實測驗證它。

用法：python probe_touch_coords.py [grpc_port] [serial]
"""
import re
import subprocess
import sys
import time

sys.path.insert(0, "gen")
import grpc
from gen import emulator_controller_pb2 as pb
from gen import emulator_controller_pb2_grpc as pbg

PORT = sys.argv[1] if len(sys.argv) > 1 else "8558"
SERIAL = sys.argv[2] if len(sys.argv) > 2 else "emulator-5558"
ADB = subprocess.run(["bash", "-lc", "echo $HOME/Library/Android/sdk/platform-tools/adb"],
                     capture_output=True, text=True).stdout.strip()

size = subprocess.run([ADB, "-s", SERIAL, "shell", "wm", "size"],
                      capture_output=True, text=True).stdout
gw, gh = map(int, re.search(r"(\d+)x(\d+)", size).groups())
print(f"guest 實體解析度 = {gw}x{gh}")

# 送到「串流座標系 540x1200 的正中央」。若座標系其實是實體螢幕，
# 這一點會落在畫面的左上 1/4 處，而不是正中央。
TX, TY = 270, 600
print(f"送出 Touch(x={TX}, y={TY})")
print(f"  若座標系=實體螢幕 → guest 收到 ({TX}, {TY})，即畫面的 ({TX/gw:.0%}, {TY/gh:.0%}) 位置")
print(f"  若座標系=串流影像 → guest 收到 ({TX*2}, {TY*2})，即畫面正中央")

proc = subprocess.Popen([ADB, "-s", SERIAL, "shell", "getevent", "-l"],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
time.sleep(3.0)

with grpc.insecure_channel(f"localhost:{PORT}") as ch:
    stub = pbg.EmulatorControllerStub(ch)
    stub.sendTouch(pb.TouchEvent(touches=[pb.Touch(x=TX, y=TY, identifier=0, pressure=1024)]))
    time.sleep(0.3)
    stub.sendTouch(pb.TouchEvent(touches=[pb.Touch(x=TX, y=TY, identifier=0, pressure=0)]))

time.sleep(3.0)
proc.terminate()
out = proc.stdout.read()

# getevent 印的是**觸控裝置的 raw 值**，不是螢幕像素——必須先用該裝置的 ABS 範圍
# 正規化才能比較。emulator 的 virtio_input_multi_touch ABS_MT_POSITION_X/Y max=32767。
# （第一版沒做這個換算，把 raw 8191 誤讀成「滿值」而得出相反的結論。）
RAW_MAX = 32767
xs = [int(m, 16) for m in re.findall(r"ABS_MT_POSITION_X\s+(\w+)", out)]
ys = [int(m, 16) for m in re.findall(r"ABS_MT_POSITION_Y\s+(\w+)", out)]
print(f"\nguest raw：X={xs} Y={ys}（該裝置 ABS max={RAW_MAX}）")
if xs and ys:
    px, py = xs[0] / RAW_MAX * gw, ys[0] / RAW_MAX * gh
    print(f"換算成螢幕像素：({px:.0f}, {py:.0f})")
    physical = abs(px - TX) < abs(px - TX * 2)
    print(f"→ 座標系是「{'實體螢幕（1080x2400）' if physical else '串流影像'}」")
    if physical:
        print("   ⇒ 觸控換算必須用 guest 實體解析度，不能用串流幀尺寸。")
else:
    print("(getevent 沒抓到 ABS_MT_POSITION，可能該裝置走不同的 input 路徑)")
