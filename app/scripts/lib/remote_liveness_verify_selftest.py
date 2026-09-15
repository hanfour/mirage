#!/usr/bin/env python3
"""無網路的 R8 判定與連線期限回歸測試。"""
import asyncio
import contextlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import remote_liveness_verify as live
from remote_client import HEADER


FRAME = HEADER.pack(1, 1, 1) + b"\x00\x00\x01\x65"


def stats(**changes):
    return dict(type="stats", emulatorConnected=True, newFrames=30,
                heartbeatFrames=4, intervalMs=1000, secondsSinceNewFrame=0.1,
                **changes) if not changes else {**stats(), **changes}


class Clock:
    now = 0

    def __call__(self):
        return self.now


class Video:
    def __init__(self, clock, events):
        self.clock = clock
        self.events = iter(events)
        self.closed = False

    async def recv(self):
        offset, message = next(self.events)
        self.clock.now += offset
        return message


class Connection:
    def __init__(self, video=None, error=None):
        self.video = video
        self.error = error

    async def __aenter__(self):
        if self.error:
            raise self.error
        return self.video

    async def __aexit__(self, *_):
        self.video.closed = True


class Refused(Exception):
    def __init__(self, status):
        self.response = SimpleNamespace(status_code=status)


class PredicateTests(unittest.TestCase):
    def test_accepts_fresh_connected_full_window(self):
        self.assertTrue(live.fresh_connected_stats(stats(), 2))
        self.assertTrue(live.fresh_connected_stats(stats(), 10))

    def test_disconnected_and_missing_connection_fail(self):
        for connected in [False, None, 1, "true"]:
            with self.subTest(connected=connected):
                self.assertFalse(live.fresh_connected_stats(stats(emulatorConnected=connected), 2))

    def test_heartbeats_and_missing_frames_cannot_pass(self):
        for frames in [0, -1, None, True, "30", float("nan"), float("inf")]:
            with self.subTest(frames=frames):
                self.assertFalse(live.fresh_connected_stats(stats(newFrames=frames, heartbeatFrames=40), 2))

    def test_previous_window_and_stale_cached_frame_fail(self):
        self.assertFalse(live.fresh_connected_stats(stats(), 0.5))
        self.assertFalse(live.fresh_connected_stats(stats(secondsSinceNewFrame=960), 2))
        self.assertFalse(live.fresh_connected_stats(stats(secondsSinceNewFrame=2), 2))
        self.assertFalse(live.fresh_connected_stats(stats(), 10.001))

    def test_invalid_age_and_interval_fail(self):
        for field in ["secondsSinceNewFrame", "intervalMs"]:
            for value in [None, True, -1, float("nan"), float("inf"), "1"]:
                with self.subTest(field=field, value=value):
                    self.assertFalse(live.fresh_connected_stats(stats(**{field: value}), 2))
        self.assertFalse(live.fresh_connected_stats(stats(intervalMs=0), 2))

    def test_unknown_payloads_do_not_pass(self):
        for payload in [None, [], 1, {}, {"type": "other"}]:
            self.assertFalse(live.fresh_connected_stats(payload, 2))


class ObserveTests(unittest.IsolatedAsyncioTestCase):
    async def test_heartbeat_only_exhausts_fixed_deadline(self):
        clock = Clock()
        events = [(1, json.dumps(stats(newFrames=0))) for _ in range(10)]
        video = Video(clock, events)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(TimeoutError):
            await live.observe(video, 0, prime=False, clock=clock)
        self.assertEqual(clock.now, 10)

    async def test_stats_alone_cannot_replace_video(self):
        clock = Clock()
        video = Video(clock, [(1, json.dumps(stats())) for _ in range(10)])
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(TimeoutError):
            await live.observe(video, 0, prime=False, clock=clock)

    async def test_prints_stats_verbatim_and_waits_for_current_window(self):
        clock = Clock()
        raw = '{ "type": "stats", "emulatorConnected": true, "newFrames": 2, "intervalMs": 1000, "secondsSinceNewFrame": 0.2 }'
        video = Video(clock, [(0.1, FRAME), (0.2, raw), (0.8, raw)])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            await live.observe(video, 0, prime=False, clock=clock)
        self.assertIn("R8_MAC_STATS=" + raw, output.getvalue())
        self.assertIn("R8_SECONDS=1.100", output.getvalue())
        self.assertIn("R8_VIDEO_FRAMES=1", output.getvalue())

    async def test_bad_json_is_ignored_and_late_delivery_fails(self):
        clock = Clock()
        video = Video(clock, [(0.1, "{bad"), (10, json.dumps(stats()))])
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(TimeoutError):
            await live.observe(video, 0, prime=False, clock=clock)

    async def test_recv_that_never_completes_times_out(self):
        class SilentVideo:
            async def recv(self):
                await asyncio.Event().wait()
        # 最後 10ms 仍使用真 asyncio timeout，不能只靠 mock 時鐘迴圈。
        clock = Clock()
        clock.now = 9.99
        with self.assertRaises(TimeoutError):
            await live.observe(SilentVideo(), 0, prime=False, clock=clock)


class ConnectionTests(unittest.IsolatedAsyncioTestCase):
    async def run_verify(self, statuses):
        clock = Clock()
        prime = Video(clock, [(0.1, FRAME)])
        resumed = Video(clock, [(0.1, FRAME), (1, json.dumps(stats()))])
        calls, pauses = [], []
        connections = [Connection(prime)] + [Connection(error=Refused(s)) for s in statuses] + [Connection(resumed)]

        def connect(url, **options):
            if calls:
                self.assertTrue(prime.closed)
            calls.append((url, options))
            return connections.pop(0)

        async def pause(seconds):
            pauses.append(seconds)
            clock.now += seconds

        args = SimpleNamespace(host="127.0.0.1", port=8765, token="test")
        with patch.object(live, "connect_options", return_value={}), contextlib.redirect_stdout(io.StringIO()):
            await live.verify(args, connect=connect, clock=clock, pause=pause)
        self.assertTrue(resumed.closed)
        self.assertEqual(len(calls), 2 + len(statuses))
        self.assertEqual(pauses, [0.2] * len(statuses))
        self.assertEqual(calls[-1][1]["open_timeout"], 5)
        self.assertEqual(calls[-1][1]["close_timeout"], 1)

    async def test_disconnects_before_second_connection(self):
        await self.run_verify([])

    async def test_only_retries_conflicts_before_handshake(self):
        await self.run_verify([409, 409])
        with self.assertRaises(Refused):
            await self.run_verify([403])

    async def test_conflict_retries_are_bounded(self):
        with self.assertRaises(Refused):
            await self.run_verify([409] * 5)

    async def test_main_reports_failure_with_nonzero_exit(self):
        async def fail(_):
            raise TimeoutError("test deadline")
        output = io.StringIO()
        with patch.object(live, "verify", fail), contextlib.redirect_stderr(output):
            result = await live.main(SimpleNamespace())
        self.assertEqual(result, 1)
        self.assertIn("R8", output.getvalue())
        self.assertIn("test deadline", output.getvalue())


if __name__ == "__main__":
    unittest.main()
