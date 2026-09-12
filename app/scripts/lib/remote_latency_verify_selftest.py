#!/usr/bin/env python3
"""age 驗收的正常、邊界、缺樣本及壞格式測試；不連裝置。"""
import contextlib
import io
import json
import unittest

from remote_latency_verify import age_windows, verify


class RemoteLatencyEvidenceTests(unittest.TestCase):
    def line(self, p95, count=30):
        return "MAC_STATS=" + json.dumps({"type": "stats", "newFrames": count,
                                          "age": {"p95": p95, "count": count}})

    def test_each_window_must_pass_strict_threshold(self):
        for value, expected in [(0, 0), (4.9, 0), (9.999, 0), (10, 1), (20, 1)]:
            with self.subTest(value=value), contextlib.redirect_stdout(io.StringIO()) as output:
                result = verify([self.line(2), self.line(value), self.line(1)])
            self.assertEqual(result, expected)
            self.assertIn(f"最大值={max(2, value):.3f} ms", output.getvalue())
            self.assertIn("有效窗口=3", output.getvalue())

    def test_heartbeat_window_and_last_summary_are_not_samples(self):
        lines = ['MAC_STATS={"type":"stats","newFrames":0}', self.line(3),
                 'MAC_STATS_LAST={"type":"stats","newFrames":30,"age":{"p95":99,"count":30}}']
        self.assertEqual(age_windows(lines), [3])

    def test_missing_or_invalid_samples_fail(self):
        cases = [[], ['MAC_STATS={"type":"stats","newFrames":0}'],
                 ['MAC_STATS={"type":"stats","newFrames":30}'], ['MAC_STATS=null'],
                 ['MAC_STATS={bad'], [self.line(None)], [self.line(float("nan"))],
                 [self.line(float("inf"))], [self.line(-1)], [self.line(True)],
                 ['MAC_STATS={"type":"stats","newFrames":2,"age":{"p95":1,"count":1}}']]
        for lines in cases:
            with self.subTest(lines=lines), contextlib.redirect_stdout(io.StringIO()) as output:
                result = verify(lines)
            self.assertEqual(result, 1)
            self.assertIn("❌", output.getvalue())


if __name__ == "__main__":
    unittest.main()
