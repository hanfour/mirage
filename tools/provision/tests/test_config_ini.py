import unittest

from lib.avdspec import SPECS, AvdSpec
from lib.config_base import BASE
from lib.config_ini import (
    expected_config,
    parse_config,
    render_config,
    render_pointer_ini,
)

POC = next(spec for spec in SPECS if spec.name == "mirage-poc")
GAME = next(spec for spec in SPECS if spec.name == "mirage-game")


class BaseTemplateTests(unittest.TestCase):
    def test_base_carries_the_unified_values(self):
        """兩台只差 system image，其餘一字不差——跨台的 fps 數字才可直接比較。"""
        self.assertEqual(BASE["hw.gpu.enabled"], "yes")
        self.assertEqual(BASE["hw.gpu.mode"], "host")
        self.assertEqual(BASE["hw.ramSize"], "4096")
        self.assertEqual(BASE["hw.keyboard"], "yes")
        self.assertEqual(BASE["hw.lcd.width"], "1080")
        self.assertEqual(BASE["hw.lcd.height"], "2400")
        self.assertEqual(BASE["disk.dataPartition.size"], "8589934592")

    def test_base_excludes_overlay_keys(self):
        for key in ("avd.id", "avd.name", "image.sysdir.1", "PlayStore.enabled",
                    "tag.id", "tag.ids", "tag.display", "tag.displaynames"):
            self.assertNotIn(key, BASE)

    def test_base_carries_no_template_placeholders(self):
        """mirage-poc 的 config.ini 有字面上的 <build>／<temp> 未被取代。
        範本若沾到它們，等於把手工的疤痕永久化到每一台新建的 AVD。"""
        for key, value in BASE.items():
            self.assertNotIn("<", value, key)


class ExpectedConfigTests(unittest.TestCase):
    def test_poc_uses_the_default_image(self):
        config = expected_config(POC)
        self.assertEqual(
            config["image.sysdir.1"], "system-images/android-35/default/arm64-v8a/"
        )
        self.assertEqual(config["PlayStore.enabled"], "no")
        self.assertEqual(config["tag.id"], "default")

    def test_game_uses_the_playstore_image(self):
        config = expected_config(GAME)
        self.assertEqual(
            config["image.sysdir.1"],
            "system-images/android-35/google_apis_playstore/arm64-v8a/",
        )
        self.assertEqual(config["PlayStore.enabled"], "yes")
        self.assertEqual(config["tag.id"], "google_apis_playstore")

    def test_name_fields_follow_the_spec(self):
        config = expected_config(POC)
        self.assertEqual(config["avd.id"], "mirage-poc")
        self.assertEqual(config["avd.name"], "mirage-poc")

    def test_the_two_differ_only_in_the_overlay(self):
        poc, game = expected_config(POC), expected_config(GAME)
        differing = {k for k in poc.keys() | game.keys() if poc.get(k) != game.get(k)}
        self.assertEqual(
            differing,
            {"avd.id", "avd.name", "image.sysdir.1", "PlayStore.enabled",
             "tag.id", "tag.ids", "tag.display", "tag.displaynames"},
        )


class RoundTripTests(unittest.TestCase):
    def test_render_then_parse_returns_the_same_mapping(self):
        for spec in SPECS:
            with self.subTest(spec.name):
                self.assertEqual(parse_config(render_config(spec)), expected_config(spec))

    def test_render_is_stable_across_calls(self):
        """輸出不穩定的話，每次跑都會報成漂移。"""
        self.assertEqual(render_config(POC), render_config(POC))

    def test_render_uses_spaces_around_equals(self):
        """emulator 寫出來的格式就是 `key = value`。改格式會讓每個欄位
        都在 diff 裡出現，把真正的差異埋掉。"""
        self.assertIn("hw.ramSize = 4096\n", render_config(POC))


class ParseTests(unittest.TestCase):
    def test_ignores_blank_lines_and_comments(self):
        self.assertEqual(parse_config("\n# 註解\nhw.ramSize = 4096\n"),
                         {"hw.ramSize": "4096"})

    def test_keeps_value_containing_equals(self):
        self.assertEqual(parse_config("a = b=c\n"), {"a": "b=c"})

    def test_reads_files_written_without_spaces(self):
        """手寫的 config.ini 未必有空格，parse 要容忍。"""
        self.assertEqual(parse_config("hw.ramSize=4096\n"), {"hw.ramSize": "4096"})


class PointerIniTests(unittest.TestCase):
    def test_pointer_ini_has_no_spaces_around_equals(self):
        """指標檔與 config.ini 的格式**不同**：這裡沒有空格。
        兩者實地確認過，不要統一。"""
        text = render_pointer_ini(POC, "/Users/tester/.android/avd")
        self.assertIn("avd.ini.encoding=UTF-8\n", text)
        self.assertNotIn(" = ", text)

    def test_path_is_absolute(self):
        """這就是 provisioning 天生得是腳本、不能「把目錄壓起來給別人」的原因。"""
        text = render_pointer_ini(POC, "/Users/tester/.android/avd")
        self.assertIn("path=/Users/tester/.android/avd/mirage-poc.avd\n", text)
        self.assertIn("path.rel=avd/mirage-poc.avd\n", text)
        self.assertIn("target=android-35\n", text)


if __name__ == "__main__":
    unittest.main()
