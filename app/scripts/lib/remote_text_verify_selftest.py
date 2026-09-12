"""R6 的欄位證據與提交流程自我測試，不連 adb 或 Swift。"""
import contextlib
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import remote_text_verify as rv


class RemoteTextEvidenceTests(unittest.TestCase):
    def sample(self, text=""):
        return dict(fresh=True, focused=True, package=rv.PACKAGE, field=rv.FIELD,
                    className="android.widget.EditText", text=text)

    def test_invalid_observations_are_never_treated_as_empty(self):
        for change in ({"fresh": False}, {"fresh": "true"}, {"focused": False}, {"text": None},
                       {"field": "other"}, {"package": "other"}, {"className": "TextView"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                rv.validate_sample(self.sample() | change)

    def test_driver_failure_reports_missing_field_reason(self):
        result = SimpleNamespace(returncode=2, stdout="", stderr="target field missing or ambiguous")
        with patch.object(rv.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(ValueError, "target field missing"):
                rv.observe(SimpleNamespace(serial="emulator-5554"))

    def run_verify(self, observations, expected="中文🙂"):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(serial="emulator-5554", text=expected, evidence=directory)
            launch = SimpleNamespace(returncode=0, stdout="Status: ok", stderr="")
            output = io.StringIO()
            with patch.object(rv.subprocess, "run", return_value=launch), \
                    patch.object(rv, "observe", side_effect=observations), \
                    patch.object(rv, "send_text") as send, patch.object(rv.time, "sleep"), \
                    contextlib.redirect_stdout(output):
                try:
                    rv.verify(args)
                    failure = None
                except ValueError as error:
                    failure = str(error)
            artifacts = [p.name for p in Path(directory).iterdir()]
            return failure, send.call_count, output.getvalue(), artifacts

    def test_exact_unicode_readback_passes_after_transient_empty_field(self):
        failure, sends, output, artifacts = self.run_verify([
            self.sample("old search"), self.sample(), self.sample(), self.sample("中文🙂")])
        self.assertIsNone(failure)
        self.assertEqual(sends, 1)
        self.assertIn("expected='中文🙂' actual='中文🙂'", output)
        self.assertIn("original.json", artifacts)
        self.assertIn("after-1.json", artifacts)

    def test_mismatch_does_not_resend_or_normalize_text(self):
        failure, sends, output, _ = self.run_verify(
            [self.sample(), self.sample()] + [self.sample("é")] * 10, expected="é")
        self.assertIn("欄位文字不相等", failure)
        self.assertEqual(sends, 1)
        self.assertNotIn("✅ R6", output)

    def test_missing_field_fails_before_any_text_is_sent(self):
        failure, sends, _, _ = self.run_verify([ValueError("target field missing")])
        self.assertIn("target field missing", failure)
        self.assertEqual(sends, 0)

    def test_client_transport_failure_is_not_replayed(self):
        args = SimpleNamespace(port=8765, token="test", wait_keyframe=1, text="hello")
        failed = SimpleNamespace(returncode=2, stdout="CONNECT_ERROR=lost after dispatch", stderr="")
        with patch.object(rv.subprocess, "run", return_value=failed) as run, \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ValueError):
            rv.send_text(args)
        self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
