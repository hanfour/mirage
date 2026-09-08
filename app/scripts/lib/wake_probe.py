"""External 20 ms log polling; no timing hooks in the application."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time


class InvalidRound(RuntimeError):
    pass


def require_alive(alive):
    if not alive:
        raise InvalidRound("關視窗退出了，A 沒修好")


def fps_count(log):
    return len(re.findall(r"^\[app\] fps=", log, re.M))


def first_frames(log):
    return len(re.findall(r"^\[conn\] 幀 #1\s", log, re.M))


def wait_for(read, predicate, timeout, message, alive=None,
             clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    while True:
        if alive is not None:
            require_alive(alive())
        now = clock()
        if now >= deadline:
            raise InvalidRound(message)
        if predicate(read()):
            return now
        sleep(0.020)


def wait_for_wake(read, offset, alive=None, clock=time.monotonic, sleep=time.sleep):
    """Observe only appended logs, preserving transition-before-frame ordering."""
    transition = re.compile(r"^\[conn\] power suspended-->waking\s*$", re.M)
    frame = re.compile(r"^\[conn\] 幀 #1\s", re.M)
    observed = {}

    def ready(log):
        new = log[offset:]
        match = transition.search(new)
        if match is None:
            return False
        now = clock()
        observed.setdefault("start", now)
        if frame.search(new, match.end()) is None:
            return False
        observed["end"] = now
        return True

    wait_for(read, ready, 10, "10 秒內沒有新的喚醒轉移及其後 [conn] 幀 #1",
             alive, clock=clock, sleep=sleep)
    return observed["start"], observed["end"]


def quiet_window(read, alive, duration=3.0, clock=time.monotonic, sleep=time.sleep):
    baseline = fps_count(read())
    if baseline == 0:
        raise InvalidRound("休眠前沒有 fps 紀錄，無法驗證 suspend")
    start = clock()
    while True:
        require_alive(alive())
        if fps_count(read()) != baseline:
            raise InvalidRound("休眠後 fps 仍增加，suspend 沒生效")
        if clock() - start >= duration:
            return
        sleep(0.020)


def summary(rows, required):
    if len(rows) < required:
        raise InvalidRound(f"有效輪數不足：{len(rows)}/{required}")
    for row in rows:
        if any(not isinstance(row[k], (int, float)) or not math.isfinite(row[k]) or row[k] < 0
               for k in ("wake", "wake_applescript", "startup", "foreign10", "foreign0")):
            raise InvalidRound("量測欄位無效")
        if row["foreign10"] >= 50:
            raise InvalidRound("外來 CPU floor 10 必須低於 50%")
    result = {key: {"median": statistics.median(r[key] for r in rows),
                    "min": min(r[key] for r in rows), "max": max(r[key] for r in rows)}
              for key in ("wake", "wake_applescript", "startup")}
    if result["wake"]["median"] >= 5:
        raise InvalidRound("喚醒中位數必須低於 5 秒：" + json.dumps(result))
    return result


def script(body):
    return ["osascript", "-e", 'tell application "System Events"\n'
            'tell process "MirageApp"\n' + body + '\nend tell\nend tell']


# 送任何按鍵之前都要先確定 MirageApp 在前景。CGEvent 送到的是系統焦點、不像
# System Events 能指名行程，所以這個前置對 ⌘Q 那條路徑是必要而非保險。
FOCUS_BODY = ('set frontmost to true\n'
              'if frontmost is not true then error "MirageApp 未在前景"')


def command_focus():
    return script(FOCUS_BODY)


def command_key(key):
    return script(FOCUS_BODY + f'\nkeystroke "{key}" using command down')


QUIT_VIRTUAL_KEY = 12          # Carbon 虛擬鍵碼的 Q
COMMAND_FLAG = 1 << 20         # kCGEventFlagMaskCommand


def quit_command_q():
    """使用者實際會走的退出路徑：⌘Q。

    D69 更正（2026-09-08）：先前這裡走狀態列選單，理由記載為「休眠再喚醒後只有 ⌘Q
    失效」。那是量測假象不是產品缺陷——失效的是 System Events 的 `keystroke`，
    在視窗被 `orderOut` 後又顯示回來的狀態下送不到應用選單的鍵等價（⌘Q 與 ⌘H 皆然，
    而同一時刻 ⌘W 正常、滑鼠點「Quit Mirage」也正常）。改用 CGEvent 之後 ⌘Q 一秒內退出。
    因此驗收改回量真正的使用者路徑，選單只留給 finally 的清理。
    """
    return ["osascript", "-l", "JavaScript", str(Path(__file__).with_name("cgkey.js")),
            str(QUIT_VIRTUAL_KEY), str(COMMAND_FLAG)]


def quit_menu():
    # 只在 finally 的清理路徑用：⌘Q 送不出去或沒生效時還能把行程收乾淨。
    return script('click menu bar item 1 of menu bar 2\n'
                  'click menu item "退出 Mirage" of menu 1 of menu bar item 1 of menu bar 2')


def run_round(bundle, log_path, port):
    log_path.touch()
    read = lambda: log_path.read_text(errors="replace")
    existing = subprocess.run(["pgrep", "-x", "MirageApp"], stdout=subprocess.DEVNULL)
    if existing.returncode != 1:
        raise InvalidRound("MirageApp 已在執行或無法確認行程狀態，請先正常退出")
    pid = None

    def alive():
        if pid is None:
            return False
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def timed_action(command, baseline, wake_offset=None):
        start = time.monotonic()
        with subprocess.Popen(command, stdout=sys.stderr, stderr=sys.stderr) as action:
            try:
                if wake_offset is None:
                    end = wait_for(read, lambda s: first_frames(s) > baseline, 10,
                                   "10 秒內沒有新的 [conn] 幀 #1", alive if pid else None)
                else:
                    power_seen, end = wait_for_wake(read, wake_offset, alive)
                action.wait(timeout=max(0.1, 10 - (time.monotonic() - start)))
                if action.returncode:
                    raise InvalidRound("GUI 操作失敗")
                if wake_offset is not None:
                    return end - power_seen, end - start, end == power_seen
                return end - start
            finally:
                if action.poll() is None:
                    action.kill()

    try:
        startup = timed_action(["open", "-a", str(bundle), "--stdout", str(log_path),
                                "--stderr", str(log_path), "--env", f"MIRAGE_PORT={port}",
                                "--env", "MIRAGE_CONN_LOG=1", "--env", "MIRAGE_FPS_LOG=1",
                                "--env", "NSUnbufferedIO=YES"], 0)
        pids = subprocess.check_output(["pgrep", "-x", "MirageApp"], text=True).split()
        if len(pids) != 1:
            raise InvalidRound("無法確認唯一 MirageApp PID")
        pid = int(pids[0])
        wait_for(read, lambda s: fps_count(s) > 0 and
                 "event=assign-selected-after " in s, 10, "視窗或 fps 尚未就緒", alive)
        subprocess.run(command_key("w"), check=True, timeout=10, stdout=sys.stderr)
        require_alive(alive())
        wait_for(read, lambda s: "[conn] power suspending-->suspended" in s,
                 10, "未完成休眠", alive)
        quiet_window(read, alive)
        before_wake = read()
        baseline = first_frames(before_wake)
        wake, wake_applescript, wake_same_poll = timed_action(script('click menu bar item 1 of menu bar 2\n'
                            'click menu item "顯示視窗" of menu 1 of menu bar item 1 of menu bar 2'), baseline, len(before_wake))
        subprocess.run(command_focus(), check=True, timeout=10, stdout=sys.stderr)
        subprocess.run(quit_command_q(), check=True, timeout=10, stdout=sys.stderr)
        wait_for(read, lambda s: not alive(), 10, "⌘Q 後行程未退出")
        if "event=applicationWillTerminate " not in read() or "stopRequested" not in read():
            raise InvalidRound("⌘Q 缺少退出清理紀錄")
        return {"startup": startup, "wake": wake, "wake_applescript": wake_applescript,
                "wake_same_poll": wake_same_poll, "pid": pid, "quit": "clean"}
    finally:
        # Normal quit first, including failed rounds. The shell owns final cleanup.
        if alive():
            try:
                subprocess.run(quit_menu(), check=True, timeout=10, stdout=sys.stderr)
                wait_for(read, lambda s: not alive(), 10, "清理退出逾時")
            except (InvalidRound, subprocess.SubprocessError):
                pass


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    run = sub.add_parser("round")
    run.add_argument("bundle", type=Path)
    run.add_argument("log", type=Path)
    run.add_argument("port", type=int)
    report = sub.add_parser("summary")
    report.add_argument("rows", type=Path)
    report.add_argument("required", type=int)
    args = parser.parse_args()
    try:
        if args.mode == "round":
            print(json.dumps(run_round(args.bundle, args.log, args.port)))
        else:
            rows = [json.loads(line) for line in args.rows.read_text().splitlines()]
            print(json.dumps(summary(rows, args.required)))
    except (InvalidRound, subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
