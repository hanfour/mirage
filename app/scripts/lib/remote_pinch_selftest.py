#!/usr/bin/env python3
"""R7 離線驗證：真判定器的成功／失敗證據與非同步來源，不需要模擬器。"""
import asyncio
import contextlib
import io
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import remote_client as rp
import remote_client as rc


def client_evidence(rate=62, transit=10):
    sample = json.dumps({"type": "stats", "intervalMs": 1000,
                         "inputRPCsPerSecond": rate, "inputCoalesced": 60, "transitMs": transit})
    return (f"PINCH_STATS={sample}\nPINCH_STATS={sample}\nPINCH_SECONDS=3.001\n"
            "PINCH_BATCHES=376\nPOST_PINCH_TAP_SENT_MS=80\n")


def event_evidence(gap_ms=100):
    # 全部邊緣來自 guest 核心時鐘；最後一指於 13.001 秒放開。
    tap_at = 13.001 + gap_ms / 1000
    return "\n".join([
        "[ 10.000] EV_ABS ABS_MT_TRACKING_ID 00000040",
        "[ 10.000] EV_ABS ABS_MT_SLOT 00000001",
        "[ 10.001] EV_ABS ABS_MT_TRACKING_ID 00000041",
        "[ 13.000] EV_ABS ABS_MT_TRACKING_ID ffffffff",
        "[ 13.000] EV_ABS ABS_MT_SLOT 00000000",
        "[ 13.001] EV_ABS ABS_MT_TRACKING_ID ffffffff",
        f"[ {tap_at:.3f}] EV_ABS ABS_MT_TRACKING_ID 00000040",
        f"[ {tap_at + .05:.3f}] EV_ABS ABS_MT_TRACKING_ID ffffffff",
    ])


class PinchEvidenceTests(unittest.TestCase):
    def verify(self, client=None, events=None):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            rp.verify(client if client is not None else client_evidence(),
                      events if events is not None else event_evidence())
        return output.getvalue()

    def test_normal_100ms_guest_gap_passes_and_prints_evidence(self):
        text = self.verify()
        for evidence in ("[62, 62]", "10.00 ms", "TRACKING_ID", "最後一指放開 → tap down=100.00ms", "3.001s"):
            self.assertIn(evidence, text)

    def test_missing_null_invalid_and_over_limit_stats_fail(self):
        for rate, transit in [(None, 10), (0, 10), (71, 10), (62, None), (62, 50),
                              (True, 10), (62, -1), (float('nan'), 10), (62, float('inf'))]:
            with self.subTest(rate=rate, transit=transit), self.assertRaises(ValueError):
                self.verify(client_evidence(rate, transit))

    def test_fast_window_cannot_hide_a_slow_window(self):
        client = client_evidence(transit=10).replace('"transitMs": 10', '"transitMs": 60', 1)
        with self.assertRaises(ValueError):
            self.verify(client)

    def test_empty_or_single_window_fails(self):
        for client in ("", client_evidence().split("\n", 1)[1]):
            with self.subTest(client=client), self.assertRaises(ValueError):
                self.verify(client)

    def test_source_rate_and_post_pinch_send_deadline_are_checked(self):
        for old, new in [("PINCH_BATCHES=376", "PINCH_BATCHES=100"),
                         ("PINCH_SECONDS=3.001", "PINCH_SECONDS=2"),
                         ("TAP_SENT_MS=80", "TAP_SENT_MS=501")]:
            with self.subTest(new=new), self.assertRaises(ValueError):
                self.verify(client_evidence().replace(old, new))

    def test_missing_up_second_slot_or_followup_tap_fails(self):
        events = event_evidence()
        cases = ["\n".join(events.splitlines()[:-1]),
                 events.replace("ABS_MT_SLOT 00000001", "ABS_MT_SLOT 00000000"),
                 "\n".join(events.splitlines()[:-2]),
                 events.replace("13.001] EV_ABS ABS_MT_TRACKING_ID ffffffff",
                                "13.001] EV_ABS ABS_MT_TRACKING_ID 00000042")]
        for case in cases:
            with self.subTest(events=case), self.assertRaises(ValueError):
                self.verify(events=case)

    def test_missing_guest_timestamp_cannot_pass(self):
        with self.assertRaisesRegex(ValueError, "guest monotonic"):
            self.verify(events=event_evidence().replace("[ 10.000]", ""))

    def test_queued_800ms_guest_gap_fails_and_prints_evidence(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaisesRegex(ValueError, "排隊超過 500ms"):
            rp.verify(client_evidence(), event_evidence(gap_ms=800))
        self.assertIn("最後一指放開 → tap down=800.00ms", output.getvalue())

    def test_host_timestamps_do_not_affect_guest_gap_verdict(self):
        events = "\n".join("HOST_RECEIVED=999999.000 " + line for line in event_evidence().splitlines())
        text = self.verify(client_evidence() + "POST_PINCH_TAP_AT=1.000\n", events)
        self.assertIn("最後一指放開 → tap down=100.00ms", text)
        self.assertNotIn("tap send → host", text)

    def test_guest_burst_or_long_gap_fails(self):
        for events in (event_evidence().replace("10.000", "12.500").replace("10.001", "12.501"),
                       event_evidence(gap_ms=800)):
            with self.subTest(events=events), self.assertRaises(ValueError):
                self.verify(events=events)

    def test_only_contained_windows_are_selected(self):
        results = {"_pinch_started": 10, "_pinch_end": 13}
        sample = {"intervalMs": 1000}
        self.assertFalse(rp.contained_stats(sample, results, 10.99))
        self.assertTrue(rp.contained_stats(sample, results, 11))
        self.assertTrue(rp.contained_stats(sample, results, 13))
        self.assertFalse(rp.contained_stats(sample, results, 13.01))
        self.assertFalse(rp.contained_stats({}, results, 12))
        self.assertFalse(rp.contained_stats(sample, {}, 12))

    def test_cli_rejects_invalid_seconds_and_conflicting_modes(self):
        for value in ("0", "-1", "nan", "inf"):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                rc.parse_args(["--token", "a", "--pinch", value])
        for extra in (["--touch"], ["--loop"], ["--key", "GoHome"], ["--text", "hi"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                rc.parse_args(["--token", "a", "--pinch", "3"] + extra)
        self.assertEqual(rc.parse_args(["--token", "a", "--pinch", "3"]).pinch, 3)


class PinchTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_three_second_source_batches_at_8ms_and_then_taps(self):
        now = 100.0
        sent = []

        async def sleep(seconds):
            nonlocal now
            now += seconds

        class Socket:
            async def send(self, message):
                sent.append((now, json.loads(message)))

        results = {}
        await rp.send_pinch(Socket(), 3, results, clock=lambda: now, sleep=sleep)
        batches = [(t, m) for t, m in sent if m["type"] == "touches"]
        self.assertGreaterEqual(len(batches), 375)
        self.assertLessEqual(len(batches), 377)
        self.assertEqual(batches[0][1]["points"][0]["phase"], "down")
        self.assertEqual(batches[-1][1]["points"][0]["phase"], "up")
        for (previous, _), (current, _) in zip(batches[:-2], batches[1:-1]):
            self.assertAlmostEqual(current - previous, .008)
        for _, message in batches:
            self.assertEqual([p["id"] for p in message["points"]], [-101, -102])
            self.assertTrue(all(0 <= p["x"] <= 1 for p in message["points"]))
        self.assertEqual([m["type"] for _, m in sent[-2:]], ["down", "up"])
        self.assertAlmostEqual(results["POST_PINCH_TAP_SENT_MS"], 80)
        self.assertGreater(now - sent[-1][0], .5)

    async def test_send_failure_propagates_without_fabricating_tap_evidence(self):
        class Socket:
            async def send(self, message):
                raise ConnectionError("closed")

        results = {}
        with self.assertRaises(ConnectionError):
            await rp.send_pinch(Socket(), 3, results)
        self.assertNotIn("POST_PINCH_TAP_AT", results)
        self.assertNotIn("PINCH_BATCHES", results)

    async def test_cancellation_propagates(self):
        class Socket:
            async def send(self, message):
                raise asyncio.CancelledError

        with self.assertRaises(asyncio.CancelledError):
            await rp.send_pinch(Socket(), 3, {})

    async def test_receiver_reads_stats_while_pinch_sender_is_active(self):
        started, observed = asyncio.Event(), asyncio.Event()
        events = []

        class Video:
            def __init__(self):
                self.count = 0

            async def __aenter__(self):
                events.append("video open")
                return self

            async def __aexit__(self, *args):
                events.append("video close")

            async def recv(self):
                self.count += 1
                if self.count == 1:
                    return rc.HEADER.pack(1, 1, 1) + b"\x00\x00\x01\x65"
                if self.count == 2:
                    await started.wait()
                    return '{"type":"stats","intervalMs":1000}'
                raise asyncio.TimeoutError

        async def pinch(args, results):
            events.append("pinch start")
            started.set()
            await observed.wait()
            events.append("pinch end")

        def report(message, results):
            events.append("stats received")
            observed.set()

        modules = {"websockets.asyncio.client": SimpleNamespace(connect=lambda *a, **k: Video())}
        args = rc.parse_args(["--token", "a", "--seconds", "0", "--pinch", "3"])
        with patch.dict(sys.modules, modules), patch.object(rc, "connect_options", return_value={}), \
                patch.object(rc, "run_pinch", side_effect=pinch), patch.object(rc, "report_stats", side_effect=report):
            self.assertTrue(await asyncio.wait_for(rc.receive_video(args, {}), 1))
        self.assertEqual(events, ["video open", "pinch start", "stats received", "pinch end", "video close"])


if __name__ == "__main__":
    unittest.main()
