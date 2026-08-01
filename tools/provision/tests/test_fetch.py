import hashlib
import os
import pathlib
import stat
import tempfile
import unittest
import unittest.mock
import zipfile

from fetch import (
    PROVENANCE_FILE,
    FetchError,
    ensure_space,
    extract_into,
    installed_revision,
    record_installed,
    verify_sha1,
)

LOCAL_PACKAGE_XML = """<?xml version='1.0' encoding='utf-8'?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02">
  <localPackage path="emulator"><revision><major>37</major><minor>2</minor>
  <micro>1</micro></revision></localPackage>
</ns2:repository>
"""


class EnsureSpaceTests(unittest.TestCase):
    def test_enough_space_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            ensure_space(tmp, 1024)

    def test_not_enough_space_is_fatal_before_downloading(self):
        """設計文件 §9：下載前先估算。空間不足時讓 curl 跑到一半才失敗，
        會留下 GB 級的半成品，而且訊息指向 I/O error 而不是真正的原因。"""
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(FetchError):
                ensure_space(tmp, 1 << 60)


class Sha1Tests(unittest.TestCase):
    def test_matching_sha1_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "f")
            pathlib.Path(path).write_bytes(b"hello")
            verify_sha1(path, hashlib.sha1(b"hello").hexdigest())

    def test_mismatch_deletes_the_file(self):
        """留下壞檔案的話，下一次跑會看到「檔案已存在」而跳過下載，
        於是壞檔案就永久留在那裡了。"""
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "f")
            pathlib.Path(path).write_bytes(b"hello")
            with self.assertRaises(FetchError):
                verify_sha1(path, "0" * 40)
            self.assertFalse(os.path.exists(path))


def _make_zip(tmp, root_name, files):
    zip_path = os.path.join(tmp, "a.zip")
    with zipfile.ZipFile(zip_path, "w") as zf:
        for name, content in files.items():
            zf.writestr(f"{root_name}/{name}" if root_name else name, content)
    return zip_path


def _make_zip_with_modes(tmp, root_name, files):
    """`files`：`{name: (content, mode)}`。用 `ZipInfo` 明確設 `external_attr`
    ——`writestr(str, ...)` 造出來的項目 `external_attr` 是 0，測不出「有沒有
    保留權限」的差異（這正是舊版 `_make_zip` 測不到執行權限 bug 的原因）。"""
    zip_path = os.path.join(tmp, "modes.zip")
    with zipfile.ZipFile(zip_path, "w") as zf:
        for name, (content, mode) in files.items():
            info = zipfile.ZipInfo(f"{root_name}/{name}" if root_name else name)
            info.external_attr = (mode & 0xFFFF) << 16
            zf.writestr(info, content)
    return zip_path


class ExtractTests(unittest.TestCase):
    def test_moves_the_single_top_level_dir_into_place(self):
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = _make_zip(tmp, "arm64-v8a", {"build.prop": "x"})
            install = os.path.join(tmp, "sdk", "system-images", "android-35", "default", "arm64-v8a")
            extract_into(zip_path, install)
            self.assertTrue(os.path.exists(os.path.join(install, "build.prop")))

    def test_zip_without_single_root_dir_is_fatal(self):
        """猜錯 zip 結構會把檔案裝歪，而歪掉的 SDK 只會在啟動模擬器時
        以看不懂的訊息現形。寧可當場炸掉。"""
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = _make_zip(tmp, "", {"a.txt": "x", "b.txt": "y"})
            with self.assertRaises(FetchError):
                extract_into(zip_path, os.path.join(tmp, "out"))

    def test_existing_dir_is_replaced_and_old_one_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            install = os.path.join(tmp, "emulator")
            os.makedirs(install)
            pathlib.Path(os.path.join(install, "old")).write_text("old")
            zip_path = _make_zip(tmp, "emulator", {"new": "new"})
            extract_into(zip_path, install)
            self.assertTrue(os.path.exists(os.path.join(install, "new")))
            self.assertFalse(os.path.exists(os.path.join(install, "old")))

    def test_failure_before_backup_leaves_previous_directory_untouched(self):
        """這裡的壞 zip 觸發的是「entries 數量檢查」，而那個檢查發生在
        backup 被賦值**之前**——所以這條測的是「根本還沒動舊目錄」，
        不是「動了之後救回來」。後面那條 test_failure_after_backup_
        restores_the_previous_directory 才是真正守著還原邏輯的測試。"""
        with tempfile.TemporaryDirectory() as tmp:
            install = os.path.join(tmp, "emulator")
            os.makedirs(install)
            pathlib.Path(os.path.join(install, "old")).write_text("old")
            bad_zip = _make_zip(tmp, "", {"a.txt": "x", "b.txt": "y"})
            with self.assertRaises(FetchError):
                extract_into(bad_zip, install)
            self.assertTrue(os.path.exists(os.path.join(install, "old")))

    def test_failure_after_backup_restores_the_previous_directory(self):
        """原本那條測試用壞 zip 觸發的是「entries 數量檢查」，而那發生在 backup
        被賦值**之前**——走的是「根本還沒動舊目錄」，不是「動了之後救回來」。
        把還原邏輯整段拿掉，原測試仍然全綠。要驗還原，失敗就必須發生在
        backup 建立之後。"""
        with tempfile.TemporaryDirectory() as tmp:
            install = os.path.join(tmp, "emulator")
            os.makedirs(install)
            pathlib.Path(os.path.join(install, "old")).write_text("old")
            zip_path = _make_zip(tmp, "emulator", {"new": "new"})

            real_rename = os.rename
            calls = []

            def failing_rename(src, dst):
                calls.append((src, dst))
                # 第一次 rename 是「舊目錄 → backup」，要讓它成功；
                # 第二次是「新內容 → install_dir」，讓它炸，才會走到還原路徑。
                if len(calls) == 2:
                    raise OSError("注入的失敗")
                return real_rename(src, dst)

            with unittest.mock.patch("os.rename", failing_rename):
                with self.assertRaises(OSError):
                    extract_into(zip_path, install)

            self.assertTrue(os.path.exists(os.path.join(install, "old")),
                            "還原後舊內容必須還在")
            self.assertFalse(os.path.exists(install + ".provision-old"),
                             "還原後不該留下 backup 目錄")


class ExtractModeTests(unittest.TestCase):
    """2026-08-02 真下載 platform-tools 驗到的 bug：`zipfile.extractall()`
    不還原 `external_attr` 裡的 Unix 權限，`adb` 解出來變成 `-rw-r--r--`，
    直接 `PermissionError`。這個類別釘住修復——拿掉 `_extract_preserving_modes`
    裡的 `os.chmod` 那行，`test_executable_bit_survives_extraction` 會紅。"""

    def test_executable_bit_survives_extraction(self):
        """真 zip（platform-tools）有 11 個 0o755 的項目，舊版 extract_into
        全部丟掉權限。這條測試是那個真實 bug 的回歸哨兵。"""
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = _make_zip_with_modes(
                tmp,
                "platform-tools",
                {"adb": ("#!/bin/sh\n", 0o755), "NOTICE.txt": ("x", 0o644)},
            )
            install = os.path.join(tmp, "out")
            extract_into(zip_path, install)
            self.assertTrue(
                os.access(os.path.join(install, "adb"), os.X_OK),
                "adb 解壓後必須可執行",
            )
            self.assertFalse(
                os.access(os.path.join(install, "NOTICE.txt"), os.X_OK),
                "非執行檔不該被誤加執行權限",
            )

    def test_symlink_entries_are_rejected(self):
        """platform-tools 的真 zip 沒有符號連結，但別的 package 可能有。
        與其猜著寫一條沒被驗證過的還原邏輯，不如當場說清楚——這條測試
        釘住「看到符號連結就拒絕、不要裝出一個看起來裝好但其實壞掉的
        SDK」這個決定，不讓它被悄悄拿掉。"""
        with tempfile.TemporaryDirectory() as tmp:
            link_mode = stat.S_IFLNK | 0o777
            zip_path = _make_zip_with_modes(tmp, "pkg", {"link": ("target", link_mode)})
            with self.assertRaises(FetchError):
                extract_into(zip_path, os.path.join(tmp, "out"))


class InstalledRevisionTests(unittest.TestCase):
    def test_reads_package_xml(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "emulator")
            os.makedirs(target)
            pathlib.Path(os.path.join(target, "package.xml")).write_text(LOCAL_PACKAGE_XML)
            self.assertEqual(installed_revision(tmp, "emulator"), "37.2.1")

    def test_absent_directory_returns_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(installed_revision(tmp, "emulator"))

    def test_directory_without_package_xml_returns_empty_string(self):
        """現裝的 google_apis_playstore 映像就是這種狀態：目錄在、版本無從追溯。
        它與「沒裝」是兩件不同的事，回傳值必須能區分。"""
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "emulator"))
            self.assertEqual(installed_revision(tmp, "emulator"), "")

    def test_corrupt_package_xml_returns_empty_string_not_raise(self):
        """package.xml 存在但內容壞掉（例如寫到一半就中斷），正是本檔案檔頭
        說的「看起來裝好了但其實壞掉」的典型狀態。installed_revision 的契約
        是「讀不出來就回空字串」，不能讓底層 ElementTree 的 ParseError
        漏出去變成呼叫端沒接住的例外。"""
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "emulator")
            os.makedirs(target)
            pathlib.Path(os.path.join(target, "package.xml")).write_text(
                "<ns2:repository><localPackage/></ns2:repository>"
            )
            self.assertEqual(installed_revision(tmp, "emulator"), "")


class RecordInstalledTests(unittest.TestCase):
    """2026-08-02 真下載驗到的 bug：provision.py 裝的 package 沒有
    `package.xml`（Google 的原始 zip 本來就不含它），`installed_revision`
    永遠回空字串，第二次跑會把剛裝好的東西判成漂移。這個類別釘住修復——
    拿掉 `installed_revision` 裡查 `_read_provenance` 那行，
    `test_recorded_revision_is_read_back_when_no_package_xml` 會紅。"""

    def test_recorded_revision_is_read_back_when_no_package_xml(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "platform-tools")
            os.makedirs(target)
            record_installed(tmp, "platform-tools", "37.0.1")
            self.assertEqual(installed_revision(tmp, "platform-tools"), "37.0.1")

    def test_package_xml_takes_priority_over_provenance(self):
        """package.xml 是別人（sdkmanager／Android Studio）寫的，代表這份
        比我們自己的紀錄更新——例如使用者事後用官方工具升級過，我們的
        provenance 紀錄還停在舊版本。"""
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "emulator")
            os.makedirs(target)
            record_installed(tmp, "emulator", "37.0.0")  # 我們紀錄的舊版本
            pathlib.Path(os.path.join(target, "package.xml")).write_text(LOCAL_PACKAGE_XML)  # 37.2.1
            self.assertEqual(installed_revision(tmp, "emulator"), "37.2.1")

    def test_multiple_install_paths_are_recorded_independently(self):
        """先前呼叫寫進去的紀錄不能被下一次呼叫蓋掉——record_installed 必須
        整份讀回來、疊上新的一筆再整份寫出去，而不是直接覆寫整個檔案。"""
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "emulator"))
            os.makedirs(os.path.join(tmp, "platform-tools"))
            record_installed(tmp, "emulator", "37.1.11")
            record_installed(tmp, "platform-tools", "37.0.1")
            self.assertEqual(installed_revision(tmp, "emulator"), "37.1.11")
            self.assertEqual(installed_revision(tmp, "platform-tools"), "37.0.1")

    def test_corrupt_provenance_file_is_treated_as_empty(self):
        """這份檔案只是加速用的紀錄，不是真相來源——壞掉的後果應該是回頭
        報告漂移，不是讓整支工具崩潰。"""
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "platform-tools")
            os.makedirs(target)
            pathlib.Path(os.path.join(tmp, PROVENANCE_FILE)).write_text("{not valid json")
            self.assertEqual(installed_revision(tmp, "platform-tools"), "")

    def test_missing_directory_still_returns_none_when_provenance_file_exists(self):
        """provenance 紀錄不能讓「目錄根本不存在」被誤判成「裝了」——
        `installed_revision` 的第一道判斷（`os.path.isdir`）必須仍然優先，
        即使 `PROVENANCE_FILE` 裡有別的 install_path 的紀錄。"""
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "emulator"))
            record_installed(tmp, "emulator", "37.1.11")
            self.assertIsNone(installed_revision(tmp, "platform-tools"))


if __name__ == "__main__":
    unittest.main()
