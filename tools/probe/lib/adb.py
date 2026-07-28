"""adb 操作封裝。所有需要 guest 端狀態或系統設定的動作走這裡。"""
import os
import subprocess


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


def run(serial: str, args: list[str], timeout: float = 20.0) -> str:
    proc = subprocess.run([adb_path(), "-s", serial, *args],
                          capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise AdbError(f"adb {' '.join(args)} 失敗：{proc.stderr.strip()}")
    return proc.stdout


def ensure_online(serial: str) -> None:
    proc = subprocess.run([adb_path(), "-s", serial, "get-state"],
                          capture_output=True, text=True, timeout=10)
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


def screencap_png(serial: str) -> bytes:
    """guest 畫面。注意：**不含** pointer_location 這類系統 overlay。"""
    proc = subprocess.run([adb_path(), "-s", serial, "exec-out", "screencap", "-p"],
                          capture_output=True, timeout=30)
    if proc.returncode != 0 or not proc.stdout:
        raise AdbError(f"screencap 失敗：{proc.stderr.decode(errors='replace').strip()}")
    return proc.stdout


def get_setting(serial: str, key: str) -> str:
    return run(serial, ["shell", "settings", "get", "system", key]).strip()


def put_setting(serial: str, key: str, value: str) -> None:
    run(serial, ["shell", "settings", "put", "system", key, value])


def start_package(serial: str, package: str) -> None:
    run(serial, ["shell", "monkey", "-p", package,
                 "-c", "android.intent.category.LAUNCHER", "1"], timeout=30)
