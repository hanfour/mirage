import unittest

from lib.report import Row, exit_code, format_report


class ExitCodeTests(unittest.TestCase):
    def test_all_ok_is_zero(self):
        self.assertEqual(exit_code([Row("a", True, "", ""), Row("b", True, "", "")]), 0)

    def test_any_drift_is_one(self):
        self.assertEqual(exit_code([Row("a", True, "", ""), Row("b", False, "x", "y")]), 1)

    def test_empty_is_zero(self):
        self.assertEqual(exit_code([]), 0)


class FormatTests(unittest.TestCase):
    def test_shows_hint_only_for_failing_rows(self):
        """符合的項目印提示只會製造雜訊，讓真正該做的事更難被看到。"""
        text = format_report("SDK", [
            Row("emulator", False, "37.2.1 ≠ 37.1.11", "--upgrade 可更新"),
            Row("platform-tools", True, "37.0.1", "--upgrade 可更新"),
        ])
        self.assertIn("--upgrade 可更新", text)
        self.assertEqual(text.count("--upgrade 可更新"), 1)

    def test_marks_ok_and_drift_distinctly(self):
        text = format_report("SDK", [Row("a", True, "", ""), Row("b", False, "x", "")])
        self.assertIn("✓", text)
        self.assertIn("✗", text)

    def test_title_appears_first(self):
        text = format_report("SDK: /path", [Row("a", True, "", "")])
        self.assertTrue(text.startswith("SDK: /path"))

    def test_empty_rows_still_renders_title(self):
        self.assertIn("SDK", format_report("SDK", []))


if __name__ == "__main__":
    unittest.main()
