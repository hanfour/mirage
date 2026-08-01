import unittest

from lib.drift import Diff, config_drift, package_drift


class ConfigDriftTests(unittest.TestCase):
    def test_identical_yields_nothing(self):
        config = {"a": "1", "b": "2"}
        self.assertEqual(config_drift(config, dict(config)), [])

    def test_reports_only_the_differing_key(self):
        self.assertEqual(
            config_drift({"a": "1", "b": "2"}, {"a": "1", "b": "9"}),
            [Diff(key="b", current="2", expected="9")],
        )

    def test_missing_key_reports_current_none(self):
        self.assertEqual(
            config_drift({}, {"a": "1"}), [Diff(key="a", current=None, expected="1")]
        )

    def test_extra_key_reports_expected_none(self):
        """mirage-poc 有多出來的 disk.dataPartition.path = <temp>。
        多出來的欄位也是漂移——--apply 會整份重寫，不報就會靜默消失。"""
        self.assertEqual(
            config_drift({"a": "1"}, {}), [Diff(key="a", current="1", expected=None)]
        )

    def test_result_is_sorted_by_key(self):
        """輸出順序不穩定的話，同一種漂移每次印出來長得不一樣，
        看的人會以為情況變了。"""
        drifts = config_drift({"z": "1", "a": "1"}, {"z": "2", "a": "2"})
        self.assertEqual([d.key for d in drifts], ["a", "z"])

    def test_placeholder_value_is_drift(self):
        """mirage-poc 的 avd.name 字面上是 <build>。"""
        self.assertEqual(
            config_drift({"avd.name": "<build>"}, {"avd.name": "mirage-poc"}),
            [Diff(key="avd.name", current="<build>", expected="mirage-poc")],
        )


class PackageDriftTests(unittest.TestCase):
    def test_matching_revision_yields_none(self):
        self.assertIsNone(package_drift("emulator", "37.1.11", "37.1.11"))

    def test_different_revision_is_drift(self):
        self.assertEqual(
            package_drift("emulator", "37.2.1", "37.1.11"),
            Diff(key="emulator", current="37.2.1", expected="37.1.11"),
        )

    def test_not_installed_is_drift_with_current_none(self):
        self.assertEqual(
            package_drift("emulator", None, "37.1.11"),
            Diff(key="emulator", current=None, expected="37.1.11"),
        )

    def test_unknown_installed_revision_is_drift(self):
        """現裝的 google_apis_playstore 映像沒有 package.xml，版本無從追溯。
        「不知道」不可以當成「符合」——那正是 D33 記載的手工環境問題本體。"""
        self.assertEqual(
            package_drift("sysimg", "", "9"),
            Diff(key="sysimg", current="", expected="9"),
        )


if __name__ == "__main__":
    unittest.main()
