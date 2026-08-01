import pathlib
import unittest

from lib.manifest import (
    ManifestError,
    PackageRef,
    find_ref,
    parse_local_revision,
    parse_manifest,
)

FIXTURES = pathlib.Path(__file__).parent / "fixtures"
REPO_BASE = "https://dl.google.com/android/repository/"
SYSIMG_BASE = REPO_BASE + "sys-img/android/"


def _read(name):
    return (FIXTURES / name).read_text(encoding="utf-8")


class ParseManifestTests(unittest.TestCase):
    def setUp(self):
        self.refs = parse_manifest(
            _read("repo.xml"), REPO_BASE, host_os="macosx", host_arch="aarch64"
        )

    def test_relative_url_becomes_absolute(self):
        ref = find_ref(self.refs, "platform-tools", "stable")
        self.assertEqual(
            ref.url, REPO_BASE + "platform-tools_r37.0.1-darwin.zip"
        )

    def test_revision_joins_present_components_only(self):
        """sys-img 的 revision 只有 <major>，不可以補零成 2.0.0——
        pin 表裡記的就是 "2"，補零會讓每次比對都判成漂移。"""
        sysimg = parse_manifest(
            _read("sysimg.xml"), SYSIMG_BASE, host_os="macosx", host_arch="aarch64"
        )
        ref = find_ref(sysimg, "system-images;android-35;default;arm64-v8a", "stable")
        self.assertEqual(ref.revision, "2")

    def test_same_path_appears_once_per_channel(self):
        """repository2-3.xml 裡 `emulator` 出現兩次（stable 與 dev）。
        用 dict 以 path 為 key 會讓其中一個消失——這正是要回傳 list 的原因。"""
        emulators = [r for r in self.refs if r.path == "emulator"]
        self.assertEqual(
            sorted((r.channel, r.revision) for r in emulators),
            [("dev", "37.2.2"), ("stable", "37.1.11")],
        )

    def test_picks_archive_matching_host_arch(self):
        """emulator 的 macosx 有 x64 與 aarch64 兩個 archive，挑錯會裝到
        Rosetta 版——跑得起來但效能與我們量到的數字對不上。"""
        ref = find_ref(self.refs, "emulator", "stable")
        self.assertEqual(ref.sha1, "f22f44948a2b7f0a0103645b9a639290eef92426")
        self.assertEqual(ref.size, 394555844)

    def test_archive_without_host_fields_matches_anything(self):
        sysimg = parse_manifest(
            _read("sysimg.xml"), SYSIMG_BASE, host_os="macosx", host_arch="aarch64"
        )
        self.assertEqual(len(sysimg), 1)

    def test_package_with_no_matching_archive_is_skipped_not_fatal(self):
        """repository2-3.xml 裡有大量與本機無關的 package（fixture 用只有
        linux archive 的 ndk 代表）。為它們拋錯會讓整份 manifest 解析不了。"""
        self.assertIsNone(find_ref(self.refs, "ndk;99.0.0", "stable"))

    def test_find_ref_returns_none_for_unknown_path(self):
        self.assertIsNone(find_ref(self.refs, "no-such-package", "stable"))


class ChecksumValidationTests(unittest.TestCase):
    def test_non_sha1_checksum_is_fatal(self):
        """checksum 型別不是 sha1 時繼續下去，等於用錯的演算法驗檔案——
        會把壞檔案當成好的裝進去。寧可當場炸掉。"""
        bad = _read("repo.xml").replace('type="sha1"', 'type="md5"', 1)
        with self.assertRaises(ManifestError):
            parse_manifest(bad, REPO_BASE, host_os="macosx", host_arch="aarch64")


class AmbiguousArchiveTests(unittest.TestCase):
    def test_two_matching_archives_is_fatal(self):
        """挑錯 zip 的後果是一個「看起來裝好了但其實壞掉」的環境。
        規則有漏時要當場知道，不要隨便挑一個。"""
        doubled = _read("sysimg.xml").replace(
            "</archives>",
            """  <archive>
        <complete>
          <size>1</size>
          <checksum type="sha1">1111111111111111111111111111111111111111</checksum>
          <url>duplicate.zip</url>
        </complete>
      </archive>
    </archives>""",
            1,
        )
        with self.assertRaises(ManifestError):
            parse_manifest(doubled, SYSIMG_BASE, host_os="macosx", host_arch="aarch64")


class LocalPackageTests(unittest.TestCase):
    def test_reads_installed_revision(self):
        self.assertEqual(parse_local_revision(_read("local_package.xml")), "37.2.1")

    def test_missing_revision_is_fatal(self):
        with self.assertRaises(ManifestError):
            parse_local_revision("<ns2:repository xmlns:ns2='x'/>")


if __name__ == "__main__":
    unittest.main()
