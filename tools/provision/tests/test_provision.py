import os
import tempfile
import unittest
import unittest.mock
import zipfile

import fetch
import provision
from lib import versions
from lib.manifest import PackageRef


class ExitCodeContractTests(unittest.TestCase):
    def test_unwritable_avd_home_is_exit_2_not_1(self):
        """退出碼 1 的意思是「有漂移」。權限炸掉卻回 1，會讓只看退出碼的
        自動化把「環境壞了」讀成「環境需要修」——而且那時一份報表都還沒印。

        _resolve 被 mock 成空 list，所以這條測試不連網、不下載任何東西。"""
        with tempfile.TemporaryDirectory() as tmp:
            avd_home = os.path.join(tmp, "avd")
            os.makedirs(avd_home)
            os.chmod(avd_home, 0o500)  # r-x：進得去但寫不了
            try:
                with unittest.mock.patch("provision._resolve", return_value=[]):
                    code = provision.main(
                        ["--apply", "--sdk-root", tmp, "--avd-home", avd_home]
                    )
                self.assertEqual(code, 2)
            finally:
                # 不還原權限的話 TemporaryDirectory 清不掉。
                os.chmod(avd_home, 0o700)


class SdkRowIdempotencyTests(unittest.TestCase):
    """2026-08-02 真下載 platform-tools 驗到的 bug：`_sdk_rows` 裝完一個
    package 後，再跑一次會把它判成漂移——因為 Google 的原始 zip 不含
    `package.xml`，而 provision.py 自己也沒有留下任何紀錄。這直接違反設計
    文件 §8：「`--apply --upgrade` 跑完後，再跑一次不帶旗標應該全 ✓ 且
    `exit 0`」。這條測試把整條路徑串起來（下載被跳過、真的 extract_into、
    真的 record_installed、真的 installed_revision），不只測個別函式——
    拿掉 `_sdk_rows` 裡呼叫 `fetch.record_installed` 那行，第二次跑會紅。

    不連網：把 zip 直接放進 cache，`_sdk_rows` 見到檔案已存在就不會呼叫
    `fetch.download`。
    """

    def test_second_run_reports_ok_without_package_xml(self):
        with tempfile.TemporaryDirectory() as sdk_root, tempfile.TemporaryDirectory() as cache:
            pin = versions.Pin(
                manifest_key="repo",
                path="fake-pkg",
                channel="stable",
                revision="1.0",
                sha1="unused-because-cache-hit-skips-download",
                size=0,
                install_path="fake-pkg",
            )
            ref = PackageRef(
                path="fake-pkg",
                revision="1.0",
                channel="stable",
                url="https://example.invalid/fake-pkg.zip",
                sha1="unused-because-cache-hit-skips-download",
                size=0,
            )
            zip_path = os.path.join(cache, "fake-pkg.zip")
            with zipfile.ZipFile(zip_path, "w") as zf:
                zf.writestr("fake-pkg/file.txt", "x")

            first = provision._sdk_rows(sdk_root, [(pin, ref)], upgrade=False, cache=cache)
            self.assertEqual(len(first), 1)
            self.assertTrue(first[0].ok, f"第一次安裝應該成功：{first[0]}")
            self.assertIn("已安裝", first[0].detail)
            self.assertTrue(
                os.path.isfile(os.path.join(sdk_root, fetch.PROVENANCE_FILE)),
                "extract_into 成功後必須留下 provenance 紀錄",
            )

            second = provision._sdk_rows(sdk_root, [(pin, ref)], upgrade=False, cache=cache)
            self.assertEqual(len(second), 1)
            self.assertTrue(
                second[0].ok,
                f"第二次跑應該全部符合（設計文件 §8 的冪等驗收條件），卻是：{second[0]}",
            )
            self.assertEqual(second[0].detail, "1.0")


if __name__ == "__main__":
    unittest.main()
