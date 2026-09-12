#!/usr/bin/env python3
"""remote_client.py 純函式的自我測試：不需要 websockets、不需要模擬器（ci.sh 閘門 8）。"""
import asyncio
import contextlib
import io
import json
import struct
import subprocess
import tempfile
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import remote_client as rc  # noqa: E402
from remote_text_verify_selftest import RemoteTextEvidenceTests  # noqa: E402,F401


class HeaderTests(unittest.TestCase):
    def test_parses_thirteen_byte_header(self):
        data = struct.pack(">QIB", 123456789, 7, 1) + b"\x00\x00\x00\x01\x65"
        sent, seq, key, unit = rc.parse_header(data)
        self.assertEqual((sent, seq, key, unit), (123456789, 7, True, b"\x00\x00\x00\x01\x65"))

    def test_rejects_short_or_bad_flag(self):
        with self.assertRaises(ValueError):
            rc.parse_header(struct.pack(">QIB", 1, 1, 0))          # 只有標頭沒有 payload
        with self.assertRaises(ValueError):
            rc.parse_header(struct.pack(">QIB", 1, 1, 2) + b"\x00")


class SequenceTests(unittest.TestCase):
    def test_counts_gaps_and_keyframes(self):
        tracker = rc.SequenceTracker()
        for seq, key in [(1, True), (2, False), (5, False), (6, True)]:
            tracker.observe(seq, key)
        self.assertEqual((tracker.frames, tracker.keyframes, tracker.gaps), (4, 2, 2))

    def test_wraparound_is_not_a_gap(self):
        tracker = rc.SequenceTracker()
        tracker.observe(0xFFFFFFFF, True)
        tracker.observe(0, False)
        self.assertEqual(tracker.gaps, 0)


class TouchMessageTests(unittest.TestCase):
    def test_down_move_up_have_viewer_shape(self):
        messages = [json.loads(m) for m in rc.touch_messages(0.98, 0.5, pointer_id=3, now_ms=100.0)]
        self.assertEqual([m["type"] for m in messages], ["down", "move", "up"])
        self.assertTrue(all(m["id"] == 3 for m in messages))
        self.assertTrue(all(0 <= m["x"] <= 1 and 0 <= m["y"] <= 1 for m in messages))   # 夾住
        self.assertEqual([m["t"] for m in messages], [100.0, 140.0, 180.0])

    def test_navigation_key_protocol_and_allowlist(self):
        for key in rc.NAVIGATION_KEYS:
            self.assertEqual(json.loads(rc.key_message(key, 12.5)),
                             {"type": "key", "key": key, "t": 12.5})
        for key in ("gohome", "Power", "", None):
            with self.assertRaises(ValueError):
                rc.key_message(key, 1)

    def test_text_protocol_preserves_unicode_and_rejects_invalid_lengths(self):
        for text in ("中文🙂é", " ", "a" * 4096, "🙂" * 2048):
            self.assertEqual(json.loads(rc.text_message(text, 42)),
                             {"type": "text", "text": text, "t": 42})
        for text in ("", "a" * 4097, "🙂" * 2049, None):
            with self.assertRaises(ValueError):
                rc.text_message(text, 42)

    def test_urls(self):
        self.assertEqual(rc.video_url("127.0.0.1", 8765, "ab"), "ws://127.0.0.1:8765/ws/video?t=ab")
        self.assertEqual(rc.input_url("10.0.0.2", 9000, "cd"), "ws://10.0.0.2:9000/ws/input?t=cd")


class DeadlineTests(unittest.TestCase):
    def test_non_keyframes_do_not_extend_deadline(self):
        self.assertEqual(rc.remaining_budget(59, None, 60, 10), 1)
        self.assertEqual(rc.remaining_budget(61, None, 60, 10), 0)

    def test_sampling_starts_at_keyframe(self):
        self.assertEqual(rc.remaining_budget(8, 5, 60, 10), 7)
        self.assertEqual(rc.remaining_budget(16, 5, 60, 10), 0)


class ExtraProtocolTests(unittest.TestCase):
    def test_short_messages(self):
        for size in range(14):
            with self.subTest(size=size), self.assertRaises(ValueError):
                rc.parse_header(bytes(size))

    def test_annex_b_and_non_keyframe(self):
        for prefix in (b"\x00\x00\x01", b"\x00\x00\x00\x01"):
            self.assertFalse(rc.parse_header(rc.HEADER.pack(0, 0, 0) + prefix + b"\x41")[2])
        with self.assertRaises(ValueError):
            rc.parse_header(rc.HEADER.pack(0, 0, 1) + b"invalid")

    def test_duplicate_and_backwards_frames_are_not_continuous(self):
        for sequence in (10, 9):
            tracker = rc.SequenceTracker()
            tracker.observe(10, True)
            tracker.observe(sequence, False)
            self.assertGreater(tracker.gaps, 0)

    def test_proxy_compatibility(self):
        for version, expected in (("13.1", {}), ("15.0.1", {"proxy": None})):
            with patch.dict(sys.modules, {"websockets": SimpleNamespace(__version__=version)}):
                self.assertEqual(rc.connect_options(), expected)


class TouchTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_fault_injection_counts_actual_sends_and_rejects_wrong_echo(self):
        class Socket:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                pass

            async def send(self, text):
                pass

            async def recv(self):
                return '{"type":"ping","t":-1}'

        modules = {"websockets.asyncio.client": SimpleNamespace(connect=lambda *a, **k: Socket())}
        args = SimpleNamespace(host="127.0.0.1", port=8765, token="a", touch=True, key=None, text=None)
        with patch.dict(sys.modules, modules), patch.object(rc, "connect_options", return_value={}), \
                patch.object(rc, "touch_messages", return_value=['{"type":"down"}']):
            results = {}
            await rc.send_touch(args, results)
        self.assertEqual(results["TOUCH_SENT"], 1)
        self.assertEqual(results["PING_ECHO_OK"], 0)


class LoopTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_loop_records_valid_frames_and_disconnect_without_touch(self):
        class Socket:
            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                pass

            def __aiter__(self):
                return self.messages()

            async def messages(self):
                yield "ignored text"
                yield rc.HEADER.pack(1, 1, 1) + b"\x00\x00\x01\x65"
                yield rc.HEADER.pack(2, 2, 0) + b"\x00\x00\x01\x41"

        modules = {"websockets.asyncio.client": SimpleNamespace(connect=lambda *a, **k: Socket())}
        args = SimpleNamespace(host="127.0.0.1", port=8765, token="a", touch=True, key=None, text=None)
        output = io.StringIO()
        with patch.dict(sys.modules, modules), patch.object(rc, "connect_options", return_value={}), \
                patch.object(rc.time, "time", side_effect=[100, 101, 102]), \
                patch.object(rc.asyncio, "sleep", side_effect=asyncio.CancelledError), \
                contextlib.redirect_stdout(output):
            with self.assertRaises(asyncio.CancelledError):
                await rc.loop_forever(args)
        self.assertEqual(output.getvalue().splitlines(),
                         ["LOOP_FRAME=100", "LOOP_FRAME=101", "LOOP_DISCONNECTED=102"])


class PairedConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def run_client(self, failure=None, key=None, text=None):
        events = []
        active = set()
        test = self
        expected_text = text

        class Socket:
            def __init__(self, kind):
                self.kind = kind
                self.frames = 0
                self.echo = None

            async def __aenter__(self):
                if self.kind == "input":
                    test.assertIn("video", active, "input 握手前必須保留 video")
                active.add(self.kind)
                events.append("open " + self.kind)
                return self

            async def __aexit__(self, *args):
                active.remove(self.kind)
                events.append("close " + self.kind)

            async def recv(self):
                if self.kind == "video":
                    if failure == "video":
                        raise ConnectionError("video disconnected")
                    if self.frames or failure == "timeout":
                        raise asyncio.TimeoutError()
                    self.frames += 1
                    return rc.HEADER.pack(1, 1, 1) + b"\x00\x00\x01\x65"
                test.assertIn("video", active, "ping echo 前不得關閉 video")
                events.append("echo")
                return self.echo

            async def send(self, text):
                test.assertIn("video", active, "觸控期間不得關閉 video")
                if failure == "touch":
                    raise ConnectionError("touch failed")
                self.echo = text
                message = json.loads(text)
                if message["type"] == "key":
                    test.assertEqual(message["key"], key)
                    test.assertIsInstance(message["t"], (float, int))
                if message["type"] == "text":
                    test.assertEqual(message["text"], expected_text)
                events.append(message["type"])

        def connect(url, **kwargs):
            return Socket("input" if "/ws/input?" in url else "video")

        args = SimpleNamespace(host="127.0.0.1", port=8765, token="a", loop=False,
                               touch=key is None and text is None, key=key, text=text, wait_keyframe=60, seconds=10)
        modules = {"websockets.asyncio.client": SimpleNamespace(connect=connect)}
        output = io.StringIO()
        with patch.dict(sys.modules, modules), patch.object(rc, "connect_options", return_value={}), \
                contextlib.redirect_stdout(output):
            code = await rc.main(args)
        self.assertEqual(active, set(), "所有路徑都必須關閉 WebSocket")
        return code, events, output.getvalue()

    async def test_input_and_ping_finish_before_video_closes(self):
        code, events, output = await self.run_client()
        self.assertEqual(code, 0)
        self.assertEqual(events, ["open video", "open input", "down", "move", "up", "ping", "echo",
                                  "close input", "close video"])
        self.assertIn("TOUCH_SENT=3", output)
        self.assertIn("PING_ECHO_OK=1", output)

    async def test_keys_and_echo_finish_before_video_closes(self):
        for key in rc.NAVIGATION_KEYS:
            with self.subTest(key=key):
                code, events, output = await self.run_client(key=key)
                self.assertEqual(code, 0)
                self.assertEqual(events, ["open video", "open input", "key", "ping", "echo",
                                          "close input", "close video"])
                self.assertIn(f"KEY_SENT={key}", output)
                self.assertIn("TOUCH_SENT=0", output)

    async def test_text_keeps_video_until_echo_without_sending_touch(self):
        code, events, output = await self.run_client(text="中文🙂 hello")
        self.assertEqual(code, 0)
        self.assertEqual(events, ["open video", "open input", "text", "ping", "echo",
                                  "close input", "close video"])
        self.assertIn("TEXT_SENT=1", output)

    async def test_touch_failure_closes_both_connections(self):
        code, events, _ = await self.run_client("touch")
        self.assertEqual(code, 2)
        self.assertEqual(events, ["open video", "open input", "close input", "close video"])

    async def test_keyframe_timeout_does_not_open_input(self):
        code, events, _ = await self.run_client("timeout")
        self.assertEqual(code, 3)
        self.assertEqual(events, ["open video", "close video"])

    async def test_video_failure_does_not_open_input(self):
        code, events, _ = await self.run_client("video")
        self.assertEqual(code, 2)
        self.assertEqual(events, ["open video", "close video"])


class NavigationEvidenceTests(unittest.TestCase):
    """執行活體腳本的 R4/R5 原碼，假 adb／client 不會啟動 Swift 或模擬器。"""

    def run_evidence(self, mode):
        lib = Path(__file__).resolve().parent
        script = (lib.parent / "verify_remote_mirror.sh").read_text()
        section = script[script.index("foreground_evidence()"):].split("# R6：")[0] + 'echo "全部通過"\n'
        cleanup = script[script.index("stop_key_capture()"):script.index("cleanup()")]
        prelude = r"""
set -uo pipefail
source "$1/verify_common.sh"
MODE="$2"
PHASE_FILE="$3"
ADB=fake_adb PY=fake_client SERIAL=emulator-5554
SCRIPT_DIR=/unused REMOTE_PORT=8765 TOKEN=test WAIT_KEYFRAME=1 CLIENT_LOG=/dev/null
KEY_CAPTURE_PID=''
sleep() { command sleep 0.05; }
trap 'stop_key_capture; rm -f "${KEY_EVENT_LOG:-}"' EXIT
fake_client() {
    local key="${!#}"
    if [ "$MODE" = send_failure ]; then echo CONNECT_ERROR=failed; return 2; fi
    echo "$key" > "$PHASE_FILE"
    echo "KEY_SENT=$key"
    echo PING_ECHO_OK=1
}
fake_adb() {
    if [[ "$*" == *resolve-activity* ]]; then
        echo com.android.launcher3/.Launcher
        return
    fi
    if [[ "$*" == *getevent* ]]; then
        while [ "$(cat "$PHASE_FILE")" != AppSwitch ]; do command sleep 0.01; done
        [ "$MODE" = missing_down ] || echo '/dev/input/event0: EV_KEY KEY_APPSELECT DOWN'
        [ "$MODE" = missing_up ] || echo '/dev/input/event0: EV_KEY KEY_APPSELECT UP'
        command sleep 2
        return
    fi
    [ "$MODE" != adb_failure ] || { echo adb_failed; return 1; }
    local component=com.android.launcher3/.Launcher
    if [ "$MODE" = home_noop ]; then component=com.example.game/.GameActivity; fi
    echo "topResumedActivity=ActivityRecord{abc u0 $component t42}"
    echo "Hist #0: ActivityRecord{old u0 com.android.systemui/.RecentsActivity t1}"
}
"""
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run(["bash", "-c", prelude + cleanup + section, "nav-test", str(lib),
                                   mode, str(Path(directory) / "phase")],
                                  capture_output=True, text=True, timeout=10)

    def test_accepts_appselect_down_up_while_launcher_remains_foreground(self):
        for mode in ("launcher",):
            with self.subTest(mode=mode):
                result = self.run_evidence(mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("HOME resolver 證據", result.stdout)
                self.assertIn("topResumedActivity 證據", result.stdout)
                self.assertIn("KEY_APPSELECT DOWN", result.stdout)
                self.assertIn("KEY_APPSELECT UP", result.stdout)
                self.assertIn("全部通過", result.stdout)

    def test_rejects_missing_key_edges_and_transport_failures(self):
        for mode in ("missing_down", "missing_up", "home_noop", "adb_failure", "send_failure"):
            with self.subTest(mode=mode):
                result = self.run_evidence(mode)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("全部通過", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
