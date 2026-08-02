import contextlib
import hashlib
import io
import os
import pathlib
import tempfile
import unittest
import unittest.mock
import zipfile

import fetch
import provision
from lib import config_ini, report, versions
from lib.avdspec import SPECS
from lib.manifest import PackageRef


class UnsupportedHostTests(unittest.TestCase):
    """`versions.PINS` 的 sha1 全部是 macOS ARM 的。不擋的話，在別的平台上
    跑會在 `resolve_pins` 裡以「上游重新打包過，請更新 PINS 並 commit」的
    訊息中止——照做就把 macOS 那台的 pin 改壞。守門必須發生在抓 manifest
    之前，所以這條測試不連網。"""

    def test_unsupported_host_is_exit_2_with_a_message_naming_both_platforms(self):
        with unittest.mock.patch("platform.system", return_value="Linux"), \
             unittest.mock.patch("platform.machine", return_value="x86_64"):
            with contextlib.redirect_stderr(io.StringIO()) as captured:
                code = provision.main([])
        self.assertEqual(code, 2)
        message = captured.getvalue()
        self.assertIn("macosx", message)
        self.assertIn("aarch64", message)


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
                    # main() 印的錯誤訊息（PermissionError）本身就是這條測試在
                    # 驗證的行為，但每次跑都往 stderr 噴一行對讀測試輸出的人是
                    # 雜訊——吞掉它，退出碼才是這條測試真正關心的斷言。
                    with contextlib.redirect_stderr(io.StringIO()):
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
            zip_path = os.path.join(cache, "fake-pkg.zip")
            with zipfile.ZipFile(zip_path, "w") as zf:
                zf.writestr("fake-pkg/file.txt", "x")
            # cache 命中現在會驗 sha1（D33 全分支審查修 3），所以這裡要填
            # zip 的真 sha1，不能再用佔位字串——否則第一次跑就會因為驗不過
            # 被刪檔，跟這條測試原本要驗的「第二次跑」完全無關。
            real_sha1 = hashlib.sha1(pathlib.Path(zip_path).read_bytes()).hexdigest()

            pin = versions.Pin(
                manifest_key="repo",
                path="fake-pkg",
                channel="stable",
                revision="1.0",
                sha1=real_sha1,
                size=0,
                install_path="fake-pkg",
            )
            ref = PackageRef(
                path="fake-pkg",
                revision="1.0",
                channel="stable",
                url="https://example.invalid/fake-pkg.zip",
                sha1=real_sha1,
                size=0,
            )

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


class SdkCacheIntegrityTests(unittest.TestCase):
    """全分支審查 Important：cache 命中時原本完全不驗 sha1。第一次跑會驗
    （`download` 內部呼叫 `verify_sha1`），但冪等工具的常態就是第二次之後，
    那正是完整性模型被繞過的地方——cache 在 `tempfile.gettempdir()`
    （Linux 上是 `/tmp`），任何本機使用者都能搶先放一個同名 zip 進去，
    不重新驗就會連同執行位一起被解進 SDK。"""

    def test_tampered_cache_zip_is_rejected_not_silently_extracted(self):
        with tempfile.TemporaryDirectory() as sdk_root, tempfile.TemporaryDirectory() as cache:
            zip_path = os.path.join(cache, "fake-pkg.zip")
            with zipfile.ZipFile(zip_path, "w") as zf:
                zf.writestr("fake-pkg/file.txt", "the real content")
            # pin／ref 記的是「應該」是什麼——刻意跟 cache 裡實際放的內容不符，
            # 模擬「檔名對、內容被換過」的 cache 汙染。
            wrong_sha1 = hashlib.sha1(b"not the real content").hexdigest()

            pin = versions.Pin(
                manifest_key="repo",
                path="fake-pkg",
                channel="stable",
                revision="1.0",
                sha1=wrong_sha1,
                size=0,
                install_path="fake-pkg",
            )
            ref = PackageRef(
                path="fake-pkg",
                revision="1.0",
                channel="stable",
                url="https://example.invalid/fake-pkg.zip",
                sha1=wrong_sha1,
                size=0,
            )

            with self.assertRaises(fetch.FetchError):
                provision._sdk_rows(sdk_root, [(pin, ref)], upgrade=False, cache=cache)

            self.assertFalse(
                os.path.isdir(os.path.join(sdk_root, "fake-pkg")),
                "sha1 驗不過就不該把內容解進 SDK",
            )
            self.assertFalse(
                os.path.exists(zip_path),
                "verify_sha1 驗不過會刪檔，不留壞檔案卡住下一次跑",
            )


class SdkExtractSpaceTests(unittest.TestCase):
    """`download()` 檢查的是 cache 所在的檔案系統，但解壓是在 sdk_root——
    可能是不同 volume。這條測試模擬「下載那邊空間夠、sdk_root 那邊不夠」，
    確認 `_sdk_rows` 在呼叫 `extract_into` 之前就擋下來，而不是解到一半
    留下半成品。用 mock `shutil.disk_usage`（依路徑回不同值），不用真的
    填滿磁碟。"""

    def test_insufficient_space_at_sdk_root_is_fatal_before_extracting(self):
        with tempfile.TemporaryDirectory() as sdk_root, tempfile.TemporaryDirectory() as cache:
            zip_path = os.path.join(cache, "fake-pkg.zip")
            with zipfile.ZipFile(zip_path, "w") as zf:
                zf.writestr("fake-pkg/file.txt", "x")
            content_sha1 = hashlib.sha1(pathlib.Path(zip_path).read_bytes()).hexdigest()

            pin = versions.Pin(
                manifest_key="repo",
                path="fake-pkg",
                channel="stable",
                revision="1.0",
                sha1=content_sha1,
                size=1_000_000_000,
                install_path="fake-pkg",
            )
            ref = PackageRef(
                path="fake-pkg",
                revision="1.0",
                channel="stable",
                url="https://example.invalid/fake-pkg.zip",
                sha1=content_sha1,
                size=1_000_000_000,
            )

            def fake_disk_usage(path):
                # sdk_root 幾乎沒空間；其他路徑（cache 那條檢查路徑）空間充足。
                free = 1 if os.path.abspath(path) == os.path.abspath(sdk_root) else 1 << 40
                return unittest.mock.MagicMock(free=free)

            with unittest.mock.patch("shutil.disk_usage", side_effect=fake_disk_usage):
                with self.assertRaises(fetch.FetchError):
                    provision._sdk_rows(sdk_root, [(pin, ref)], upgrade=False, cache=cache)

            self.assertFalse(
                os.path.isdir(os.path.join(sdk_root, "fake-pkg")),
                "空間不足要在 extract_into 之前擋下來，不該留下半解壓的目錄",
            )


class PointerIniDriftTests(unittest.TestCase):
    """全分支審查 Critical：`_avd_rows` 原本只拿 config.ini 算漂移，指標檔
    （`<name>.ini`）只在寫入分支順手寫、從不參與比對。後果：config.ini 正確
    但指標檔缺失、或 `path=` 指向別的帳號時，這裡回報「符合」且 exit 0，
    而 `emulator -list-avds` 是靠掃指標檔找 AVD，根本看不見那台。連
    `--apply` 都不會修它，因為漂移清單裡壓根沒有它。

    全部離線、用 tempdir 當 avd_home，不連網、不碰真的 ~/.android/avd。
    """

    @staticmethod
    def _write_correct_config(avd_home, spec):
        avd_dir = os.path.join(avd_home, spec.name + ".avd")
        os.makedirs(avd_dir, exist_ok=True)
        with open(os.path.join(avd_dir, "config.ini"), "w", encoding="utf-8") as handle:
            handle.write(config_ini.render_config(spec))

    @staticmethod
    def _write_pointer(avd_home, spec, *, path_avd_home):
        with open(os.path.join(avd_home, spec.name + ".ini"), "w", encoding="utf-8") as handle:
            handle.write(config_ini.render_pointer_ini(spec, path_avd_home))

    def test_missing_pointer_ini_is_reported_as_drift(self):
        spec = SPECS[0]
        with tempfile.TemporaryDirectory() as avd_home:
            self._write_correct_config(avd_home, spec)
            # 指標檔刻意不寫——config.ini 單獨正確，不代表這台 AVD 存在。
            rows = provision._avd_rows(avd_home, apply_changes=False)
            row = next(r for r in rows if r.label == spec.name)
            self.assertFalse(row.ok, f"config.ini 對、指標檔缺失，應回報漂移：{row}")
            self.assertEqual(report.exit_code(rows), 1)

    def test_pointer_ini_pointing_elsewhere_is_reported_as_drift(self):
        spec = SPECS[0]
        with tempfile.TemporaryDirectory() as avd_home:
            self._write_correct_config(avd_home, spec)
            self._write_pointer(avd_home, spec, path_avd_home="/tmp/some-other-account/.android/avd")
            rows = provision._avd_rows(avd_home, apply_changes=False)
            row = next(r for r in rows if r.label == spec.name)
            self.assertFalse(row.ok, f"path= 指向別的目錄，應回報漂移：{row}")
            self.assertIn(f"{spec.name}.ini:path", row.detail)

    def test_both_files_correct_is_ok(self):
        with tempfile.TemporaryDirectory() as avd_home:
            for spec in SPECS:
                self._write_correct_config(avd_home, spec)
                self._write_pointer(avd_home, spec, path_avd_home=avd_home)
            rows = provision._avd_rows(avd_home, apply_changes=False)
            self.assertTrue(all(r.ok for r in rows), rows)
            self.assertEqual(report.exit_code(rows), 0)

    def test_apply_corrects_the_pointer_ini_to_the_right_absolute_path(self):
        spec = SPECS[0]
        with tempfile.TemporaryDirectory() as avd_home:
            self._write_correct_config(avd_home, spec)
            self._write_pointer(avd_home, spec, path_avd_home="/tmp/some-other-account/.android/avd")

            provision._avd_rows(avd_home, apply_changes=True)

            pointer_path = os.path.join(avd_home, spec.name + ".ini")
            with open(pointer_path, encoding="utf-8") as handle:
                text = handle.read()
            self.assertIn(f"path={avd_home}/{spec.name}.avd\n", text)

            # 修正後重新掃一次，兩個檔都該符合。
            rows = provision._avd_rows(avd_home, apply_changes=False)
            row = next(r for r in rows if r.label == spec.name)
            self.assertTrue(row.ok, row)


if __name__ == "__main__":
    unittest.main()
