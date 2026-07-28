"""adb 操作封裝。所有需要 guest 端狀態或系統設定的動作走這裡。"""
import os
import subprocess

# 相對 import：`phase0/harness` 底下有一個同名的 `lib` package（見 _bootstrap.py
# 的踩坑記錄）。用 `from lib import framebuffer` 的話，只要哪天有人把那個目錄
# 放回 sys.path，這行就可能解析到錯的 package；相對 import 對此免疫。
from . import framebuffer


class AdbError(RuntimeError):
    pass


def adb_path() -> str:
    """與 AdbClient.standard() 相同的推導順序。"""
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME") \
        or os.path.expanduser("~/Library/Android/sdk")
    path = os.path.join(sdk, "platform-tools", "adb")
    if not os.access(path, os.X_OK):
        raise AdbError(f"找不到可執行的 adb：{path}")
    return path


def _exec(serial: str, args: list[str], timeout: float,
          text: bool = True) -> subprocess.CompletedProcess:
    """所有 adb 子行程的唯一出口。

    **逾時與 OSError 一律包成 AdbError。** 裸的 `subprocess.TimeoutExpired`
    會穿過 `main()` 的 `except (AdbError, EmulatorError, ValueError)` 變成
    traceback——這支工具的輸出是給 Claude session 讀的，噴 traceback 等於把
    唯一的溝通管道砸掉。而且最容易逾時的正是 `foreground_activity` 的
    `dumpsys`（逾時 25 秒），它在 `launch` 的輪詢迴圈裡每秒被呼叫一次。
    訊息要含逾時秒數與實際執行的指令，才知道是哪一條卡住、卡多久。
    """
    try:
        return subprocess.run([adb_path(), "-s", serial, *args],
                              capture_output=True, text=text, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise AdbError(f"adb -s {serial} {' '.join(args)} 逾時（{timeout:g}s 未回應）") from None
    except OSError as e:
        raise AdbError(f"adb -s {serial} {' '.join(args)} 無法執行：{e}") from None


def run(serial: str, args: list[str], timeout: float = 20.0) -> str:
    proc = _exec(serial, args, timeout)
    if proc.returncode != 0:
        raise AdbError(f"adb {' '.join(args)} 失敗：{proc.stderr.strip()}")
    return proc.stdout


def ensure_online(serial: str) -> None:
    proc = _exec(serial, ["get-state"], timeout=10)
    if proc.returncode != 0 or proc.stdout.strip() != "device":
        raise AdbError(f"device {serial} offline (adb devices 看看)")


def foreground_activity(serial: str) -> str | None:
    out = run(serial, ["shell", "dumpsys", "activity", "activities"], timeout=25)
    for line in out.splitlines():
        if "topResumedActivity" in line:
            parts = line.strip().split()
            for p in parts:
                if "/" in p:
                    return p
    return None


def screencap_rgba(serial: str) -> tuple[int, int, bytes]:
    """guest 畫面，raw framebuffer（**不帶 `-p`**）→ (width, height, rgba)。

    ⚠️ 2026-07-28 實測更正：先前這裡的註解寫「**不含** pointer_location 這類
    系統 overlay」——**那是錯的**。在 bench 上做對照（`overlay off` → 抓圖 →
    `overlay on` → 抓圖），差異正好落在 row 136–167，那條 HUD 在 adb 抓的圖裡
    清清楚楚。adb 與 gRPC 兩條路徑的差異不在疊層，見 `lib/imgdiff.py`。

    回 raw 而不是 adb 自己編的 PNG，理由見 `lib/framebuffer.py`：兩條路徑一律
    得到 RGBA、一律用同一支 encoder 寫檔，`compare` 才能真的比對像素。

    ⏱ 代價（實測 bench，1080x2400）：raw 要搬 10.4 MB，`exec-out` 約 3–5 秒；
    裝置自己編的 PNG 只有約 160 KB，約 1 秒。**刻意接受**——`shot` 預設走 gRPC
    （約 0.6 秒），adb 這條是 gRPC 出問題時的備援與 `compare` 的對照組，不是
    熱路徑；換來的是「兩條路徑的差異可被量測」而不是被宣稱。
    """
    proc = _exec(serial, ["exec-out", "screencap"], timeout=30, text=False)
    if proc.returncode != 0 or not proc.stdout:
        raise AdbError(f"screencap 失敗：{proc.stderr.decode(errors='replace').strip()}")
    return framebuffer.parse_screencap_raw(proc.stdout)


def get_setting(serial: str, key: str) -> str:
    return run(serial, ["shell", "settings", "get", "system", key]).strip()


def put_setting(serial: str, key: str, value: str) -> None:
    run(serial, ["shell", "settings", "put", "system", key, value])


def start_package(serial: str, package: str) -> None:
    run(serial, ["shell", "monkey", "-p", package,
                 "-c", "android.intent.category.LAUNCHER", "1"], timeout=30)
