#!/usr/bin/env python3
"""remote_client.py 純函式的自我測試：不需要 websockets、不需要模擬器（ci.sh 閘門 8）。"""
import asyncio
import contextlib
import io
import json
import struct
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import remote_client as rc  # noqa: E402


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
        args = SimpleNamespace(host="127.0.0.1", port=8765, token="a")
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
        args = SimpleNamespace(host="127.0.0.1", port=8765, token="a")
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
    async def run_client(self, failure=None):
        events = []
        active = set()
        test = self

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
                events.append(json.loads(text)["type"])

        def connect(url, **kwargs):
            return Socket("input" if "/ws/input?" in url else "video")

        args = SimpleNamespace(host="127.0.0.1", port=8765, token="a", loop=False,
                               touch=True, wait_keyframe=60, seconds=10)
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


if __name__ == "__main__":
    unittest.main(verbosity=1)
