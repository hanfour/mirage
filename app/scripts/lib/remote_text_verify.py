#!/usr/bin/env python3
"""R6：設定搜尋欄位 → /ws/input text → 新鮮 UI dump 精確回讀。

準備／觀察沿用 host_ime_acceptance.py 使用的 text_field_driver.py。
只有 remote_client.py 傳送受測文字，不用 adb input text 代替產品路徑。
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

PACKAGE = "com.google.android.settings.intelligence"
FIELD = PACKAGE + ":id/open_search_view_edit_text"
LIB = Path(__file__).resolve().parent


def validate_sample(sample):
    if sample.get("fresh") is not True or sample.get("focused") is not True:
        raise ValueError("欄位不是新鮮且已聚焦的觀察：" + repr(sample))
    if (sample.get("package"), sample.get("field"), sample.get("className")) != (
            PACKAGE, FIELD, "android.widget.EditText"):
        raise ValueError("目標欄位身分不符：" + repr(sample))
    if not isinstance(sample.get("text"), str):
        raise ValueError("欄位缺少文字，不能當成空字串")
    return sample["text"]


def observe(args, action="observe", expected_current=None):
    request = {"serial": args.serial, "package": PACKAGE, "field": FIELD,
               "emptyLabel": "Search settings", "action": action}
    if expected_current is not None:
        request["expectedCurrent"] = expected_current
    result = subprocess.run([sys.executable, str(LIB / "text_field_driver.py")],
                            input=json.dumps(request), capture_output=True, text=True, timeout=65)
    if result.returncode:
        raise ValueError("uiautomator 欄位讀取／準備失敗：" + result.stderr.strip())
    return json.loads(result.stdout)


def send_text(args):
    command = [sys.executable, str(LIB / "remote_client.py"), "--host", "127.0.0.1",
               "--port", str(args.port), "--token", args.token,
               "--wait-keyframe", str(args.wait_keyframe), "--seconds", "0", "--text", args.text]
    for _ in range(5):
        result = subprocess.run(command, capture_output=True, text=True, timeout=args.wait_keyframe + 15)
        output = result.stdout + result.stderr
        print(output, end="", flush=True)
        if result.returncode == 0:
            if "TEXT_SENT=1" not in output.splitlines() or "PING_ECHO_OK=1" not in output.splitlines():
                raise ValueError("用戶端缺少文字傳送／ping 證據")
            return
        # 僅重試尚未取得連線的 409；文字交易結果未知時不得自動重播。
        if result.returncode != 2 or "HTTP 409" not in output:
            raise ValueError("遠端文字傳送失敗")
        time.sleep(0.2)
    raise ValueError("前一組 viewer 在重試期限內仍未釋放")


def verify(args):
    adb = str(Path.home() / "Library/Android/sdk/platform-tools/adb")
    launch = subprocess.run([adb, "-s", args.serial, "shell", "am", "start", "-W", "-n",
                             PACKAGE + "/.modules.search.SearchActivity"],
                            capture_output=True, text=True, timeout=20)
    print("設定搜尋啟動證據：" + launch.stdout + launch.stderr, flush=True)
    if launch.returncode or "Error" in launch.stdout + launch.stderr:
        raise ValueError("無法開啟設定搜尋頁；確認 settings intelligence 已安裝並提供 SearchActivity")
    # 準備專用測試搜尋欄位；保存原值，以 expectedCurrent 防止查詢與清空之間誤改其他值。
    original = observe(args)
    Path(args.evidence, "original.json").write_text(json.dumps(original, ensure_ascii=False))
    if not isinstance(original.get("text"), str):
        raise ValueError("設定搜尋欄位沒有可讀文字，無法準備")
    before = observe(args, "clear", original["text"])
    if validate_sample(before) != "":
        raise ValueError("設定搜尋欄位清空失敗")
    Path(args.evidence, "before.json").write_text(json.dumps(before, ensure_ascii=False))
    send_text(args)
    for attempt in range(10):
        sample = observe(args)
        Path(args.evidence, f"after-{attempt}.json").write_text(json.dumps(sample, ensure_ascii=False))
        actual = validate_sample(sample)
        print(f"R6 欄位證據：{FIELD} expected={args.text!r} actual={actual!r}", flush=True)
        if actual == args.text:
            print("✅ R6 遠端文字與欄位回讀完全相等", flush=True)
            return
        time.sleep(0.25)
    raise ValueError("R6 欄位文字不相等；不以 clipboard／RPC 成功取代欄位證據")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", default="emulator-5554")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", required=True)
    parser.add_argument("--wait-keyframe", type=int, default=60)
    parser.add_argument("--text", default="Mirage remote 中文🙂 hello")
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args()
    try:
        verify(args)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("❌ R6：" + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
