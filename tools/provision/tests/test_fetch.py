import hashlib
import os
import pathlib
import tempfile
import unittest
import zipfile

from fetch import FetchError, ensure_space, extract_into, installed_revision, verify_sha1

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

    def test_failure_restores_the_previous_directory(self):
        """任何時刻都必須有一份可用的。中途失敗卻把舊的刪了，
        等於用一次失敗的升級換掉一個本來能跑的環境。"""
        with tempfile.TemporaryDirectory() as tmp:
            install = os.path.join(tmp, "emulator")
            os.makedirs(install)
            pathlib.Path(os.path.join(install, "old")).write_text("old")
            bad_zip = _make_zip(tmp, "", {"a.txt": "x", "b.txt": "y"})
            with self.assertRaises(FetchError):
                extract_into(bad_zip, install)
            self.assertTrue(os.path.exists(os.path.join(install, "old")))


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


if __name__ == "__main__":
    unittest.main()
