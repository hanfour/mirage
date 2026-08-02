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
        """**key 要夠多**：`current.keys() | expected.keys()` 回傳的是 set，
        而 set 的疊代順序受行程的 hash randomization 影響、不保留插入順序。
        只用兩個 key 的話，拿掉 sorted() 之後仍有一半機率碰巧就是排序好的。
        10 個 key 讓碰巧命中的機率降到 1/10! ≈ 3×10⁻⁷。"""
        keys = ["k9", "k1", "k7", "k3", "k5", "k0", "k8", "k2", "k6", "k4"]
        current = {key: "1" for key in keys}
        expected = {key: "2" for key in keys}
        drifts = config_drift(current, expected)
        self.assertEqual([d.key for d in drifts], sorted(keys))

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
