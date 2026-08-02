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
        """只斷言「兩個符號都出現」的話，把 ✓/✗ 整個對調也不會紅——
        而那是最惡劣的使用者面 bug：符合的被讀成漂移、漂移的被讀成符合。
        所以要驗符號**對應到哪一列**。"""
        text = format_report("SDK", [Row("好的", True, "", ""), Row("壞的", False, "x", "")])
        lines = [line for line in text.splitlines() if "好的" in line or "壞的" in line]
        self.assertEqual(len(lines), 2)
        ok_line = next(line for line in lines if "好的" in line)
        bad_line = next(line for line in lines if "壞的" in line)
        self.assertIn("✓", ok_line)
        self.assertNotIn("✗", ok_line)
        self.assertIn("✗", bad_line)
        self.assertNotIn("✓", bad_line)

    def test_title_appears_first(self):
        text = format_report("SDK: /path", [Row("a", True, "", "")])
        self.assertTrue(text.startswith("SDK: /path"))

    def test_empty_rows_still_renders_title(self):
        self.assertIn("SDK", format_report("SDK", []))


if __name__ == "__main__":
    unittest.main()
