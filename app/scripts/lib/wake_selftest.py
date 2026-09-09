"""Fault injection through the same polling and gates used by verify_wake.sh."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from wake_probe import (InvalidRound, first_frames, fps_count, quiet_window,
                        require_alive, summary, wait_for, wait_for_wake)


class Clock:
    def __init__(self):
        self.now = 0.0

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def row(wake=1.0, cpu=0.0):
    return dict(wake=wake, wake_applescript=12.0, startup=4.0, foreign10=cpu, foreign0=cpu)


def inject(case):
    clock = Clock()
    if case == "exit":
        # A real process exits before the first check, matching PM's failure.
        process = subprocess.Popen([sys.executable, "-c", "pass"])
        process.wait()
        quiet_window(lambda: "[app] fps=60\n", lambda: process.poll() is None,
                     clock=clock.time, sleep=clock.sleep)
    elif case == "fps":
        quiet_window(lambda: "[app] fps=60\n" * (1 + int(clock.now >= 1)), lambda: True,
                     clock=clock.time, sleep=clock.sleep)
    elif case == "frame":
        wait_for(lambda: "[conn] 幀 #1 540x1200\n[conn] 幀 #10 540x1200\n",
                 lambda s: first_frames(s) > 1, 10, "10 秒內沒有新的 [conn] 幀 #1",
                 clock=clock.time, sleep=clock.sleep)
    elif case == "median":
        summary([row(4), row(5), row(6)], 3)
    elif case == "cpu":
        summary([row(cpu=50)] * 3, 3)


class WakeTests(unittest.TestCase):
    def test_five_injections_exit_nonzero(self):
        for case, message in [("exit", "關視窗退出了，A 沒修好"), ("fps", "suspend 沒生效"),
                              ("frame", "沒有新的"), ("median", "中位數"), ("cpu", "CPU")]:
            with self.subTest(case=case):
                result = subprocess.run([sys.executable, __file__, "--inject", case],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(message, result.stderr)
                print(f"PASS injection={case} exit={result.returncode} reason={result.stderr.strip()}")

    def test_screen_lock_states_in_verifier(self):
        # 執行正式 shell 流程，只有外部相依項替換成 stub，不啟動 GUI。
        scripts = Path(__file__).resolve().parent.parent
        for state, plist in [
            ("locked", "<key>CGSSessionScreenIsLocked</key>\n<true/>"),
            ("unlocked", "<key>CGSSessionScreenIsLocked</key>\n<false/>"),
            ("unknown", "<dict></dict>"),
        ]:
            with self.subTest(state=state), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                lib = root / "lib"
                lib.mkdir()
                shutil.copy(scripts / "verify_wake.sh", root)
                for name in ("gui_session.sh", "wake_probe.py", "input_latency.sh"):
                    shutil.copy(scripts / "lib" / name, lib)
                # 這是 load_sentinel.sh 的影子副本：真檔案新增呼叫端用到的函式時，這裡也要補上。
                (lib / "load_sentinel.sh").write_text(
                    'disk_preflight() { :; }\n'
                    'cpu_snapshot() { echo stub; }\n'
                    'cpu_delta_total() { echo 0; }\n')
                (lib / "verify_common.sh").write_text(
                    'source "$HERE/lib/gui_session.sh"\n'
                    'require_grpc() { :; }\nbuild_warm() { :; }\n'
                    'pgrep() { return 1; }\npkill() { return 1; }\n'
                    'caffeinate() { :; }\n'
                    'ioreg() { printf "%s\\n" "$TEST_LOCK_PLIST"; }\n'
                    'python3() {\n'
                    '  if [ "${2:-}" = round ]; then\n'
                    '    echo probe >> "$TEST_PROBE_LOG"\n'
                    "    echo '{\"startup\":1,\"wake\":1,\"wake_applescript\":3,\"wake_same_poll\":false,\"quit\":true}'\n"
                    '  else command python3 "$@"; fi\n'
                    '}\n')
                package = root / "package_app.sh"
                package.write_text('#!/bin/bash\nexit 0\n')
                package.chmod(0o755)
                probe_log = root / "probes"
                result = subprocess.run(
                    ["/bin/bash", str(root / "verify_wake.sh")],
                    env=dict(os.environ, TEST_LOCK_PLIST=plist, TEST_PROBE_LOG=str(probe_log)),
                    capture_output=True, text=True)
                try:
                    if state == "locked":
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertEqual(result.stdout.count("INVALID screen=locked"), 3)
                        self.assertFalse(probe_log.exists(), "locked 不可進入量測")
                        self.assertIn("有效輪數不足", result.stderr)
                    else:
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertEqual(probe_log.read_text().splitlines(), ["probe"] * 3)
                        self.assertEqual(result.stdout.count(" VALID "), 3)
                    print(f"PASS screen={state} exit={result.returncode} probes={0 if state == 'locked' else 3}")
                finally:
                    for line in result.stdout.splitlines():
                        if line.startswith("Logs: "):
                            shutil.rmtree(line.removeprefix("Logs: "))

    def test_wake_excludes_dispatch_and_old_logs(self):
        clock = Clock()
        old = "[conn] power suspended-->waking\n[conn] 幀 #1 old\n"
        def read():
            return (old + ("[conn] 幀 #1 before-transition\n" if clock.now >= 1 else "")
                    + ("[conn] power suspended-->waking\n" if clock.now >= 2.1 else "")
                    + ("[conn] 幀 #10 ignored\n" if clock.now >= 2.2 else "")
                    + ("[conn] 幀 #1 new\n" if clock.now >= 2.3 else ""))
        start, end = wait_for_wake(read, len(old), clock=clock.time, sleep=clock.sleep)
        self.assertAlmostEqual(end - start, 0.2)
        self.assertGreaterEqual(end, 2.3)

    def test_wake_same_poll_and_missing_transition(self):
        clock = Clock()
        start, end = wait_for_wake(
            lambda: "[conn] power suspended-->waking\n[conn] 幀 #1 new\n", 0,
            clock=clock.time, sleep=clock.sleep)
        self.assertEqual(start, end)
        with self.assertRaisesRegex(InvalidRound, "喚醒轉移"):
            wait_for_wake(lambda: "[conn] 幀 #1 new\n", 0,
                          clock=clock.time, sleep=clock.sleep)

    def test_quiet_window_observes_three_seconds(self):
        clock = Clock()
        quiet_window(lambda: "[app] fps=60\n", lambda: True,
                     clock=clock.time, sleep=clock.sleep)
        self.assertGreaterEqual(clock.now, 3)
        self.assertLess(clock.now, 3.021)

    def test_delayed_exit_is_detected(self):
        clock = Clock()
        with self.assertRaisesRegex(InvalidRound, "A 沒修好"):
            quiet_window(lambda: "[app] fps=60\n", lambda: clock.now < 2,
                         clock=clock.time, sleep=clock.sleep)

    def test_missing_fps_is_invalid(self):
        with self.assertRaisesRegex(InvalidRound, "沒有 fps"):
            quiet_window(lambda: "", lambda: True)

    def test_frame_boundary_and_fps_format(self):
        self.assertEqual(first_frames("[conn] 幀 #10 x\n[conn] 幀 #100 x\n[conn] 幀 #1 x\n"), 1)
        self.assertEqual(fps_count("[app] fps=60\n[other] fps=60\n"), 1)

    def test_poll_observes_new_frame(self):
        clock = Clock()
        end = wait_for(lambda: "[conn] 幀 #1 x\n" * (1 + int(clock.now >= 0.1)),
                       lambda s: first_frames(s) > 1, 10, "timeout",
                       clock=clock.time, sleep=clock.sleep)
        self.assertGreaterEqual(end, 0.1)
        self.assertLess(end, 0.121)

    def test_summary_boundaries_and_insufficient_rounds(self):
        self.assertEqual(summary([row(4.99, 49)] * 3, 3)["wake"]["median"], 4.99)
        self.assertEqual(summary([row(1), row(3), row(4), row(6)], 3)["wake"]["median"], 3.5)
        with self.assertRaises(InvalidRound):
            summary([row()] * 2, 3)
        with self.assertRaises(InvalidRound):
            summary([row(float("nan"))] * 3, 3)

    def test_summary_cli_rejects_missing_valid_round(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rounds.jsonl"
            path.write_text(json.dumps(row()) + "\n")
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("wake_probe.py")),
                                     "summary", str(path), "3"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("有效輪數不足", result.stderr)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--inject":
        try:
            inject(sys.argv[2])
        except InvalidRound as error:
            print(f"FAIL: {error}", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)
    unittest.main()
