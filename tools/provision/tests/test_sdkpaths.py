import unittest

from lib.sdkpaths import avd_home, sdk_root

HOME = "/Users/tester"


class SdkRootTests(unittest.TestCase):
    def test_android_sdk_root_wins(self):
        env = {"ANDROID_SDK_ROOT": "/a", "ANDROID_HOME": "/b"}
        self.assertEqual(sdk_root(env, HOME), "/a")

    def test_android_home_is_the_fallback(self):
        self.assertEqual(sdk_root({"ANDROID_HOME": "/b"}, HOME), "/b")

    def test_default_matches_what_the_repo_scripts_assume(self):
        """app/scripts/lib/verify_common.sh 與 AdbClient.swift 都寫死這個預設。
        這裡不一致的話，腳本裝到 A、驗證腳本去 B 找，會以「adb 不存在」的形式現形。"""
        self.assertEqual(sdk_root({}, HOME), "/Users/tester/Library/Android/sdk")

    def test_empty_value_is_treated_as_unset(self):
        """`export ANDROID_SDK_ROOT=` 在 shell 裡很常見，值是空字串。
        照用會得到相對路徑，把 SDK 裝進當下的工作目錄。"""
        self.assertEqual(sdk_root({"ANDROID_SDK_ROOT": ""}, HOME), "/Users/tester/Library/Android/sdk")

    def test_whitespace_only_value_is_treated_as_unset(self):
        """`.strip()` 只有在純空白字串（例如被別的腳本設成 " "）時才起作用，
        沒有這條測試的話拿掉 .strip() 不會有任何東西變紅。"""
        self.assertEqual(sdk_root({"ANDROID_SDK_ROOT": "   "}, HOME),
                         "/Users/tester/Library/Android/sdk")

    def test_empty_first_var_falls_through_to_the_second(self):
        """外層的 `if explicit:` 會把 _first_non_empty 內部的缺陷蓋住，
        所以只有「空值 + 有備援」這個交叉情境才驗得到優先序真的有跳過空值
        繼續往下找。少了它，把 _first_non_empty 改成「回傳第一個存在的 key」
        也不會有任何測試變紅。"""
        env = {"ANDROID_SDK_ROOT": "", "ANDROID_HOME": "/b"}
        self.assertEqual(sdk_root(env, HOME), "/b")


class AvdHomeTests(unittest.TestCase):
    def test_android_avd_home_wins(self):
        self.assertEqual(avd_home({"ANDROID_AVD_HOME": "/avds"}, HOME), "/avds")

    def test_default_is_dot_android_avd(self):
        self.assertEqual(avd_home({}, HOME), "/Users/tester/.android/avd")

    def test_empty_value_is_treated_as_unset(self):
        self.assertEqual(avd_home({"ANDROID_AVD_HOME": ""}, HOME), "/Users/tester/.android/avd")


if __name__ == "__main__":
    unittest.main()
