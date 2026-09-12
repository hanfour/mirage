#!/usr/bin/env python3
"""age 驗收的正常、邊界、缺樣本及壞格式測試；不連裝置。"""
import contextlib
import io
import json
import unittest

from remote_latency_verify import age_windows, verify


class RemoteLatencyEvidenceTests(unittest.TestCase):
    def line(self, p50, p95, count=30):
        return "MAC_STATS=" + json.dumps({"type": "stats", "newFrames": count,
                                          "age": {"p50": p50, "p95": p95, "count": count}})

    def test_medians_must_pass_both_strict_thresholds(self):
        cases = [(0, 0, 0), (10, 21, 0), (11.999, 24.999, 0),
                 (12, 21, 1), (10, 25, 1), (13, 26, 1)]
        for p50, p95, expected in cases:
            with self.subTest(p50=p50, p95=p95), contextlib.redirect_stdout(io.StringIO()) as output:
                result = verify([self.line(p50, p95)] * 3)
            self.assertEqual(result, expected)
            self.assertIn(f"各窗中位數={p50:.3f}/{p95:.3f} ms", output.getvalue())
            self.assertIn(", ".join([f"{p50:.3f}/{p95:.3f}"] * 3), output.getvalue())
            self.assertIn("有效窗口=3", output.getvalue())

    def test_spikes_remain_evidence_without_failing_entire_run(self):
        pairs = [(8, 20)] * 7 + [(10, 27.6)] * 3
        with contextlib.redirect_stdout(io.StringIO()) as output:
            result = verify([self.line(p50, p95) for p50, p95 in pairs])
        self.assertEqual(result, 0)
        self.assertIn("各窗中位數=8.000/20.000 ms", output.getvalue())
        self.assertEqual(output.getvalue().count("10.000/27.600"), 3)
        self.assertIn("有效窗口=10", output.getvalue())

    def test_even_window_median_averages_middle_values_without_count_weighting(self):
        for pairs, expected, medians in [
            ([(8, 20, 1), (14, 28, 60)], 0, "11.000/24.000"),
            ([(10, 20, 60), (14, 28, 1)], 1, "12.000/24.000"),
            ([(8, 22, 60), (14, 28, 1)], 1, "11.000/25.000"),
        ]:
            with self.subTest(pairs=pairs), contextlib.redirect_stdout(io.StringIO()) as output:
                result = verify([self.line(p50, p95, count) for p50, p95, count in pairs])
            self.assertEqual(result, expected)
            self.assertIn(f"各窗中位數={medians} ms", output.getvalue())

    def test_heartbeat_window_and_last_summary_are_not_samples(self):
        lines = ['MAC_STATS={"type":"stats","newFrames":0}', self.line(2, 3),
                 'MAC_STATS_LAST={"type":"stats","newFrames":30,"age":{"p50":50,"p95":99,"count":30}}']
        self.assertEqual(age_windows(lines), [(2, 3)])

    def test_missing_or_invalid_samples_fail(self):
        cases = [[], ['MAC_STATS={"type":"stats","newFrames":0}'],
                 ['MAC_STATS={"type":"stats","newFrames":30}'], ['MAC_STATS=null'],
                 ['MAC_STATS={bad'], [self.line(3, 2)],
                 ['MAC_STATS={"type":"stats","newFrames":2,"age":{"p50":1,"p95":2,"count":1}}'],
                 ['MAC_STATS={"type":"stats","newFrames":1,"age":{"p95":2,"count":1}}']]
        for value in [None, float("nan"), float("inf"), -1, True]:
            cases.extend([[self.line(value, 20)], [self.line(8, value)]])
        for lines in cases:
            with self.subTest(lines=lines), contextlib.redirect_stdout(io.StringIO()) as output:
                result = verify(lines)
            self.assertEqual(result, 1)
            self.assertIn("❌", output.getvalue())


if __name__ == "__main__":
    unittest.main()
