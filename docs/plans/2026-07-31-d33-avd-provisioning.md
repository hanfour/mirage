# D33 AVD Provisioning 腳本 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一支冪等的 Python CLI，能在一台只有 Xcode CommandLineTools 的 Mac 上，把 Android SDK 與兩台 Mirage AVD 建到與 git 裡宣告的規格一致。

**Architecture:** `lib/` 底下全是純函式（XML 文字進、資料出；不碰網路、磁碟、環境變數），`fetch.py` 是唯一有副作用的模組，`provision.py` 只做接線與輸出。這條邊界就是「不下載 GB 也能測」的機制。

**Tech Stack:** Python 3.11（`/usr/bin/env python3`，本機 pyenv 3.11.4）、標準函式庫 only（`xml.etree`、`urllib`、`hashlib`、`zipfile`、`unittest`）。**不得引入任何第三方套件。**

## Global Constraints

以下每一條都逐字來自設計文件 `docs/specs/2026-07-31-d33-avd-provisioning-design.md`，**每個 task 的要求都隱含包含這一節**：

- **零第三方依賴。** 不得 `pip install`，不得 import 標準函式庫以外的東西。理由：D33 要消除的就是「新機器到不了那個狀態」，多一個依賴就多一個卡點。
- **不得使用 pytest，測試一律 `unittest`。** 本機沒有 pytest（`python3 -m pytest` → `No module named pytest`），而 `tools/probe/tests/` 的 13 個 pytest 測試檔從未被任何東西跑過。
- **測試指令固定為**：`cd tools/provision && python3 -m unittest discover -s tests -t . -v`。`tests/__init__.py` **必須存在**，否則 `ImportError: Start directory is not importable`（已實測）。失敗時退出碼 1、全過 0（已實測）。
- **不得引入 JDK 依賴。** `avdmanager`／`sdkmanager` 在本機不可用（無 Java runtime），這是本專案改走 curl 路線的原因。
- **`lib/` 底下不得有副作用**：不 import `os` 以外的 I/O、不讀 `os.environ`（環境以參數傳入）、不開檔、不連網。違反這條就等於毀掉離線測試的能力。
- **pin 的版本（2026-07-31 由 manifest 取得，逐字使用）**：
  | path | channel | revision | sha1 | size |
  |---|---|---|---|---|
  | `emulator` | stable | `37.1.11` | `f22f44948a2b7f0a0103645b9a639290eef92426` | 394555844 |
  | `platform-tools` | stable | `37.0.1` | `6ae73f4de6452dc57e62ec02b68eed92a4c21661` | 16110554 |
  | `system-images;android-35;default;arm64-v8a` | stable | `2` | `2026a06409db630b56711afdbffb457c1dbaed49` | 769099654 |
  | `system-images;android-35;google_apis_playstore;arm64-v8a` | stable | `9` | `b01416bc0bca12a85295dad179f9b8a1cae3d1e6` | 1789211399 |
- **三份 manifest URL（逐字使用）**：
  - `https://dl.google.com/android/repository/repository2-3.xml`
  - `https://dl.google.com/android/repository/sys-img/android/sys-img2-3.xml`
  - `https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-3.xml`
  - zip 的 `<url>` 是**相對於該 manifest 所在目錄**的（三條皆已實測 HTTP 200）。
- **§4.3 是本計畫最重要的規則**：manifest 上的 revision／sha1 與 pin 不同時，**明確報錯中止**，絕不默默用新版。理由：manifest 對每個 path 只提供當下最新的一個 revision，Google 一 bump，pin 的版本就從清單上消失（canary 37.2.1 就是這樣沒的）。默默採用新版會讓同一份 commit 在不同日子跑出不同環境——正是 D33 要消滅的病。
- **預設唯讀**：不帶旗標時一行都不寫。`--apply` 只寫 AVD 檔案，`--upgrade` 只覆蓋 SDK package。缺失的東西一律直接裝（無破壞風險）。
- **退出碼**：`0` = 跑完後沒有任何未解決的漂移（與給了哪些旗標無關）；`1` = 仍有漂移；`2` = 錯誤（網路、checksum、manifest 漂移）。
- **`mirage-bench` 不在腳本的認知範圍內**：不產出、不報告、不動它。
- 註解寫**為什麼**不寫**做什麼**；commit message 用繁體中文 conventional commits。

---

## 檔案結構

| 檔案 | 職責 | 純函式？ |
|---|---|---|
| `tools/provision/lib/manifest.py` | manifest XML → `PackageRef`；本機 `package.xml` → 已裝版本 | ✅ |
| `tools/provision/lib/versions.py` | pin 表與三份 manifest URL；`resolve_pins` 實作 §4.3 | ✅ |
| `tools/provision/lib/sdkpaths.py` | SDK root 與 AVD home 的解析優先序 | ✅ |
| `tools/provision/lib/avdspec.py` | 兩台 AVD 的規格（純資料） | ✅ |
| `tools/provision/lib/config_base.py` | 共用的 `config.ini` 欄位（產生一次後進 git） | ✅ |
| `tools/provision/lib/config_ini.py` | `AvdSpec` → `config.ini` 文字；parse 既有的；`.ini` 指標檔 | ✅ |
| `tools/provision/lib/drift.py` | 現況 vs 期望 → 差異清單 | ✅ |
| `tools/provision/fetch.py` | 唯一碰網路與磁碟的模組 | ❌ |
| `tools/provision/provision.py` | CLI 接線、輸出格式、退出碼 | ❌ |
| `tools/provision/tests/` | unittest，離線，fixture XML | — |
| `app/scripts/ci.sh` | 新增閘門 6 | — |

---

### Task 1：manifest 解析

**Files:**
- Create: `tools/provision/__init__.py`（空檔）
- Create: `tools/provision/lib/__init__.py`（空檔）
- Create: `tools/provision/lib/manifest.py`
- Create: `tools/provision/tests/__init__.py`（空檔，**沒有它 unittest discover 會 ImportError**）
- Create: `tools/provision/tests/fixtures/repo.xml`
- Create: `tools/provision/tests/fixtures/sysimg.xml`
- Create: `tools/provision/tests/fixtures/local_package.xml`
- Test: `tools/provision/tests/test_manifest.py`

**Interfaces:**
- Consumes: 無（第一個 task）
- Produces：
  - `class ManifestError(Exception)`
  - `@dataclass(frozen=True) class PackageRef: path: str; revision: str; channel: str; url: str; sha1: str; size: int`
  - `parse_manifest(xml_text: str, base_url: str, *, host_os: str, host_arch: str) -> list[PackageRef]`
  - `find_ref(refs: list[PackageRef], path: str, channel: str) -> PackageRef | None`
  - `parse_local_revision(xml_text: str) -> str`

**背景（實地確認的 XML 形狀，不要憑印象寫）：** 根元素有 namespace 前綴（`sdk:sdk-repository`），但 `remotePackage`／`localPackage` 及其子元素**沒有 namespace**，所以直接用元素名比對即可。`<channel id="channel-0">stable</channel>` 宣告在根層。archive 有三種形狀：sys-img 的**沒有** `host-os`／`host-arch`；`platform-tools` 有 `host-os` 但沒有 `host-arch`；`emulator` 兩者都有。

- [ ] **Step 1: 建立 fixture**

`tools/provision/tests/fixtures/repo.xml`（真 manifest 的截短樣本，保留 `emulator` 同一 path 出現兩次這個關鍵特性）：

```xml
<?xml version='1.0' encoding='utf-8'?>
<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03">
  <channel id="channel-0">stable</channel>
  <channel id="channel-2">dev</channel>
  <remotePackage path="platform-tools">
    <revision><major>37</major><minor>0</minor><micro>1</micro></revision>
    <channelRef ref="channel-0"/>
    <archives>
      <archive>
        <complete>
          <size>9054187</size>
          <checksum type="sha1">477254aa5f903c15cf51001717bdf347fb6b53e0</checksum>
          <url>platform-tools_r37.0.1-linux.zip</url>
        </complete>
        <host-os>linux</host-os>
      </archive>
      <archive>
        <complete>
          <size>16110554</size>
          <checksum type="sha1">6ae73f4de6452dc57e62ec02b68eed92a4c21661</checksum>
          <url>platform-tools_r37.0.1-darwin.zip</url>
        </complete>
        <host-os>macosx</host-os>
      </archive>
    </archives>
  </remotePackage>
  <remotePackage path="emulator">
    <revision><major>37</major><minor>2</minor><micro>2</micro></revision>
    <channelRef ref="channel-2"/>
    <archives>
      <archive>
        <complete>
          <size>405827177</size>
          <checksum type="sha1">bae68e1a8c89731b18a7d0c91a98a6faccb9121c</checksum>
          <url>emulator-darwin_aarch64-15937705.zip</url>
        </complete>
        <host-os>macosx</host-os>
        <host-arch>aarch64</host-arch>
      </archive>
    </archives>
  </remotePackage>
  <remotePackage path="emulator">
    <revision><major>37</major><minor>1</minor><micro>11</micro></revision>
    <channelRef ref="channel-0"/>
    <archives>
      <archive>
        <complete>
          <size>465773989</size>
          <checksum type="sha1">7df8b0acbe915217dcbb576222bddfcc23e81230</checksum>
          <url>emulator-darwin_x64-15917651.zip</url>
        </complete>
        <host-os>macosx</host-os>
        <host-arch>x64</host-arch>
      </archive>
      <archive>
        <complete>
          <size>394555844</size>
          <checksum type="sha1">f22f44948a2b7f0a0103645b9a639290eef92426</checksum>
          <url>emulator-darwin_aarch64-15917651.zip</url>
        </complete>
        <host-os>macosx</host-os>
        <host-arch>aarch64</host-arch>
      </archive>
    </archives>
  </remotePackage>
  <remotePackage path="ndk;99.0.0">
    <revision><major>99</major></revision>
    <channelRef ref="channel-0"/>
    <archives>
      <archive>
        <complete>
          <size>1</size>
          <checksum type="sha1">0000000000000000000000000000000000000000</checksum>
          <url>ndk-linux-only.zip</url>
        </complete>
        <host-os>linux</host-os>
      </archive>
    </archives>
  </remotePackage>
</sdk:sdk-repository>
```

`tools/provision/tests/fixtures/sysimg.xml`（archive 沒有 host-os／host-arch，revision 只有 major）：

```xml
<?xml version='1.0' encoding='utf-8'?>
<sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/03">
  <channel id="channel-0">stable</channel>
  <remotePackage path="system-images;android-35;default;arm64-v8a">
    <revision><major>2</major></revision>
    <channelRef ref="channel-0"/>
    <archives>
      <archive>
        <complete>
          <size>769099654</size>
          <checksum type="sha1">2026a06409db630b56711afdbffb457c1dbaed49</checksum>
          <url>arm64-v8a-35_r02.zip</url>
        </complete>
      </archive>
    </archives>
  </remotePackage>
</sys-img:sdk-sys-img>
```

`tools/provision/tests/fixtures/local_package.xml`：

```xml
<?xml version='1.0' encoding='utf-8'?>
<ns2:repository xmlns:ns2="http://schemas.android.com/repository/android/common/02">
  <localPackage path="emulator" obsolete="false">
    <revision><major>37</major><minor>2</minor><micro>1</micro></revision>
    <display-name>Android Emulator</display-name>
  </localPackage>
</ns2:repository>
```

- [ ] **Step 2: 寫失敗的測試**

`tools/provision/tests/test_manifest.py`：

```python
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
```

- [ ] **Step 3: 跑測試，確認它失敗**

Run: `cd tools/provision && python3 -m unittest discover -s tests -t . -v`
Expected: `ModuleNotFoundError: No module named 'lib.manifest'`

- [ ] **Step 4: 實作 `lib/manifest.py`**

```python
"""解析 Google SDK repository 的 manifest XML。

**純函式**：不碰網路、不碰磁碟、不讀環境變數。XML 文字進、資料出。
這是「不下載 GB 也能測」的基礎（設計文件 §6）。

XML 形狀是 2026-07-31 對真 manifest 實地確認的，不是憑印象：根元素有
namespace 前綴（`sdk:sdk-repository`），但 `remotePackage`／`localPackage`
及其子元素**沒有 namespace**，所以直接用元素名比對即可。
"""
from __future__ import annotations

from dataclasses import dataclass
from urllib.parse import urljoin
from xml.etree import ElementTree


class ManifestError(Exception):
    """manifest 的形狀不符預期。中止優於猜測——猜錯會裝出一個壞環境。"""


@dataclass(frozen=True)
class PackageRef:
    path: str
    revision: str
    channel: str
    url: str
    sha1: str
    size: int


def _revision(node) -> str:
    """`<revision><major>37</major><minor>1</minor><micro>11</micro></revision>` → `"37.1.11"`

    **缺的部分不補零。** sys-img 的 revision 只有 `<major>`，它就是 `"2"`
    而不是 `"2.0.0"`——pin 表裡記的是前者，補零會讓每次比對都判成漂移。
    """
    parts = []
    for key in ("major", "minor", "micro"):
        text = node.findtext(key)
        if text is None:
            break
        parts.append(text)
    if not parts:
        raise ManifestError("revision 缺少 major")
    return ".".join(parts)


def _pick_archive(archives, host_os: str, host_arch: str):
    """挑出符合本機的 archive；沒有符合的回 None。

    三種實際存在的形狀：sys-img 的 archive **沒有** host-os／host-arch（通用）；
    platform-tools 有 host-os 沒有 host-arch；emulator 兩者都有
    （macosx/x64 與 macosx/aarch64）。所以規則是「有寫的欄位才比」。

    **零個符合回 None 而不是拋錯**：repository2-3.xml 裡有大量與本機無關的
    package，為它們拋錯會讓整份 manifest 解析不了。真正需要的 package 找不到
    時，會在 versions.resolve_pins 那裡以「pin 的 path 不存在」明確炸掉。

    **兩個以上符合則拋錯**：代表比對規則有漏，而挑錯 zip 的後果是一個看起來
    裝好了但其實壞掉的環境。寧可當場知道。
    """
    matched = []
    for archive in archives:
        os_text = archive.findtext("host-os")
        arch_text = archive.findtext("host-arch")
        if os_text is not None and os_text != host_os:
            continue
        if arch_text is not None and arch_text != host_arch:
            continue
        matched.append(archive)
    if len(matched) > 1:
        raise ManifestError(
            f"符合 {host_os}/{host_arch} 的 archive 有 {len(matched)} 個，預期至多 1 個"
        )
    return matched[0] if matched else None


def parse_manifest(
    xml_text: str, base_url: str, *, host_os: str, host_arch: str
) -> list[PackageRef]:
    """回傳 list 而非以 path 為 key 的 dict。

    理由：`repository2-3.xml` 裡 `emulator` 這個 path 出現兩次（stable 與
    dev 各一）。用 dict 會讓其中一個靜默消失，而消失的那個很可能正是 pin 的。
    """
    root = ElementTree.fromstring(xml_text)
    channels = {node.get("id"): (node.text or "") for node in root if node.tag == "channel"}

    refs: list[PackageRef] = []
    for package in root:
        if package.tag != "remotePackage":
            continue
        archives = package.find("archives")
        if archives is None:
            continue
        archive = _pick_archive(list(archives), host_os, host_arch)
        if archive is None:
            continue

        complete = archive.find("complete")
        if complete is None:
            raise ManifestError(f"{package.get('path')} 的 archive 沒有 <complete>")
        checksum = complete.find("checksum")
        if checksum is None or checksum.get("type") != "sha1":
            got = None if checksum is None else checksum.get("type")
            raise ManifestError(
                f"{package.get('path')} 的 checksum 型別是 {got!r}，只接受 sha1"
            )
        url_text = complete.findtext("url")
        size_text = complete.findtext("size")
        if url_text is None or size_text is None:
            raise ManifestError(f"{package.get('path')} 的 <complete> 缺 url 或 size")

        revision_node = package.find("revision")
        if revision_node is None:
            raise ManifestError(f"{package.get('path')} 沒有 <revision>")
        channel_node = package.find("channelRef")
        channel_id = None if channel_node is None else channel_node.get("ref")

        refs.append(
            PackageRef(
                path=package.get("path") or "",
                revision=_revision(revision_node),
                channel=channels.get(channel_id, ""),
                url=urljoin(base_url, url_text),
                sha1=(checksum.text or "").strip(),
                size=int(size_text),
            )
        )
    return refs


def find_ref(refs: list[PackageRef], path: str, channel: str) -> PackageRef | None:
    for ref in refs:
        if ref.path == path and ref.channel == channel:
            return ref
    return None


def parse_local_revision(xml_text: str) -> str:
    """讀 SDK 裡已安裝 package 的 `package.xml`，取出版本。

    `<localPackage>` 與 `<remotePackage>` 的 `<revision>` 同形，共用 `_revision`。
    """
    root = ElementTree.fromstring(xml_text)
    for node in root.iter():
        if node.tag == "localPackage":
            revision_node = node.find("revision")
            if revision_node is None:
                raise ManifestError("localPackage 沒有 <revision>")
            return _revision(revision_node)
    raise ManifestError("找不到 <localPackage>")
```

- [ ] **Step 5: 跑測試，確認全過**

Run: `cd tools/provision && python3 -m unittest discover -s tests -t . -v`
Expected: `Ran 11 tests` / `OK`

- [ ] **Step 6: Commit**

```bash
git add tools/provision/
git commit -m "feat(provision): manifest 解析

回傳 list 而非以 path 為 key 的 dict——repository2-3.xml 裡 emulator 這個
path 出現兩次（stable 與 dev），用 dict 會讓其中一個靜默消失。

archive 比對規則「有寫的欄位才比」涵蓋三種實際形狀：sys-img 沒有 host-os／
host-arch、platform-tools 只有 host-os、emulator 兩者都有。零個符合回 None
（manifest 裡大量 package 與本機無關），兩個以上拋錯（規則有漏時要當場知道，
挑錯 zip 會裝出一個看起來好了但其實壞掉的環境）。"
```

---

### Task 2：pin 表與 §4.3「漂移即中止」

**Files:**
- Create: `tools/provision/lib/versions.py`
- Test: `tools/provision/tests/test_versions.py`

**Interfaces:**
- Consumes: `lib.manifest` 的 `PackageRef`、`find_ref`
- Produces:
  - `MANIFESTS: dict[str, str]`（key: `"repo"` / `"sysimg_default"` / `"sysimg_playstore"` → URL）
  - `@dataclass(frozen=True) class Pin: manifest_key: str; path: str; channel: str; revision: str; sha1: str; size: int; install_path: str`
  - `PINS: tuple[Pin, ...]`
  - `class PinDriftError(Exception)`
  - `resolve_pins(refs_by_manifest: dict[str, list[PackageRef]]) -> list[tuple[Pin, PackageRef]]`

**這個 task 就是設計文件 §4.3。** 它是整個計畫最重要的一段：manifest 對每個 path 只提供
當下最新的一個 revision，Google 一 bump，pin 的版本就從清單上消失。默默採用新版會讓同一份
commit 在不同日子跑出不同環境——**正是 D33 要消滅的病**。

- [ ] **Step 1: 寫失敗的測試**

`tools/provision/tests/test_versions.py`：

```python
import unittest

from lib.manifest import PackageRef
from lib.versions import MANIFESTS, PINS, PinDriftError, resolve_pins


def _ref(pin, **overrides):
    """由 pin 造一個「完全相符」的 PackageRef，再讓各測試改壞其中一欄。"""
    fields = dict(
        path=pin.path,
        revision=pin.revision,
        channel=pin.channel,
        url="https://example.invalid/" + pin.path + ".zip",
        sha1=pin.sha1,
        size=pin.size,
    )
    fields.update(overrides)
    return PackageRef(**fields)


def _all_matching(**overrides_by_path):
    refs = {key: [] for key in MANIFESTS}
    for pin in PINS:
        refs[pin.manifest_key].append(_ref(pin, **overrides_by_path.get(pin.path, {})))
    return refs


class PinTableTests(unittest.TestCase):
    def test_every_pin_names_a_known_manifest(self):
        for pin in PINS:
            self.assertIn(pin.manifest_key, MANIFESTS)

    def test_pins_cover_the_four_packages(self):
        self.assertEqual(
            sorted(pin.path for pin in PINS),
            [
                "emulator",
                "platform-tools",
                "system-images;android-35;default;arm64-v8a",
                "system-images;android-35;google_apis_playstore;arm64-v8a",
            ],
        )

    def test_every_pin_has_a_forty_char_sha1(self):
        for pin in PINS:
            self.assertEqual(len(pin.sha1), 40, pin.path)


class ResolveTests(unittest.TestCase):
    def test_all_matching_resolves(self):
        resolved = resolve_pins(_all_matching())
        self.assertEqual(len(resolved), len(PINS))

    def test_newer_revision_on_manifest_is_fatal(self):
        """Google bump 之後 manifest 只剩新版。默默採用它會讓同一份 commit
        在不同日子跑出不同環境——D33 要消滅的正是這件事。"""
        refs = _all_matching(emulator={"revision": "37.1.12"})
        with self.assertRaises(PinDriftError) as caught:
            resolve_pins(refs)
        message = str(caught.exception)
        self.assertIn("37.1.11", message)
        self.assertIn("37.1.12", message)

    def test_same_revision_different_sha1_is_fatal(self):
        """版本號相同但 sha1 變了，代表上游重新打包過。這比 revision 改變
        更危險，因為它不會反映在任何版本號上。"""
        refs = _all_matching(**{"platform-tools": {"sha1": "0" * 40}})
        with self.assertRaises(PinDriftError):
            resolve_pins(refs)

    def test_missing_package_is_fatal(self):
        refs = _all_matching()
        refs["repo"] = [r for r in refs["repo"] if r.path != "emulator"]
        with self.assertRaises(PinDriftError) as caught:
            resolve_pins(refs)
        self.assertIn("emulator", str(caught.exception))

    def test_error_message_says_it_needs_a_commit(self):
        """訊息要讓讀的人知道這不是「重跑一次就會好」的錯誤，
        而是一個需要有人做決定並留下 commit 的事件。"""
        refs = _all_matching(emulator={"revision": "37.1.12"})
        with self.assertRaises(PinDriftError) as caught:
            resolve_pins(refs)
        self.assertIn("versions.py", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑測試，確認它失敗**

Run: `cd tools/provision && python3 -m unittest tests.test_versions -v`
Expected: `ModuleNotFoundError: No module named 'lib.versions'`

- [ ] **Step 3: 實作 `lib/versions.py`**

```python
"""pin 住的版本。**改這個檔案＝改測試環境**，所以它必然留下 commit。

為什麼要 pin：manifest 對每個 package path 只提供**當下最新的一個 revision**。
Google 一 bump，先前的版本就從清單上消失——我們原本在跑的 canary 37.2.1
就是這樣沒的（直連網址仍回 200，但已不在清單上、沒有官方 checksum）。

所以這裡記下期望的 (path, revision, sha1)，解析 manifest 後逐項比對，
不同就中止。**絕不默默採用新版**：那會讓同一份 commit 在不同日子跑出不同
環境，正是 D33 要消滅的病。

副作用是刻意的：Google 每次 bump 之後這支腳本會主動壞掉一次，逼一個人來看
一眼並決定要不要升。那是特性，不是 bug。
"""
from __future__ import annotations

from dataclasses import dataclass

from lib.manifest import PackageRef, find_ref

_REPO_BASE = "https://dl.google.com/android/repository/"

# zip 的 <url> 是相對於**該 manifest 所在目錄**的，所以 base 要跟著 manifest 走。
MANIFEST_BASES = {
    "repo": _REPO_BASE,
    "sysimg_default": _REPO_BASE + "sys-img/android/",
    "sysimg_playstore": _REPO_BASE + "sys-img/google_apis_playstore/",
}

MANIFESTS = {key: base + name for key, base, name in (
    ("repo", MANIFEST_BASES["repo"], "repository2-3.xml"),
    ("sysimg_default", MANIFEST_BASES["sysimg_default"], "sys-img2-3.xml"),
    ("sysimg_playstore", MANIFEST_BASES["sysimg_playstore"], "sys-img2-3.xml"),
)}


@dataclass(frozen=True)
class Pin:
    manifest_key: str
    path: str
    channel: str
    revision: str
    sha1: str
    size: int
    install_path: str  # 相對 SDK root 的最終目錄


PINS = (
    Pin(
        manifest_key="repo",
        path="emulator",
        channel="stable",
        revision="37.1.11",
        sha1="f22f44948a2b7f0a0103645b9a639290eef92426",
        size=394555844,
        install_path="emulator",
    ),
    Pin(
        manifest_key="repo",
        path="platform-tools",
        channel="stable",
        revision="37.0.1",
        sha1="6ae73f4de6452dc57e62ec02b68eed92a4c21661",
        size=16110554,
        install_path="platform-tools",
    ),
    Pin(
        manifest_key="sysimg_default",
        path="system-images;android-35;default;arm64-v8a",
        channel="stable",
        revision="2",
        sha1="2026a06409db630b56711afdbffb457c1dbaed49",
        size=769099654,
        install_path="system-images/android-35/default/arm64-v8a",
    ),
    Pin(
        manifest_key="sysimg_playstore",
        path="system-images;android-35;google_apis_playstore;arm64-v8a",
        channel="stable",
        revision="9",
        sha1="b01416bc0bca12a85295dad179f9b8a1cae3d1e6",
        size=1789211399,
        install_path="system-images/android-35/google_apis_playstore/arm64-v8a",
    ),
)


class PinDriftError(Exception):
    """manifest 上的版本與 pin 的不同。

    這**不是**「重跑一次就會好」的錯誤，而是一個需要有人做決定並留下 commit
    的事件。訊息裡必須說清楚這一點，否則下一個人會直覺去改 pin 讓它過。
    """


def _drift(pin: Pin, detail: str) -> PinDriftError:
    return PinDriftError(
        f"{pin.path}：{detail}。\n"
        f"manifest 對每個 package 只提供當下最新的一個 revision，所以上游一 bump，"
        f"pin 的版本就會從清單上消失。\n"
        f"這需要一個決定：確認新版可用之後更新 tools/provision/lib/versions.py 的 "
        f"PINS 並送出 commit——換環境必須留下紀錄。"
    )


def resolve_pins(
    refs_by_manifest: dict[str, list[PackageRef]]
) -> list[tuple[Pin, PackageRef]]:
    """逐項比對 pin 與 manifest；任一項不符即中止。"""
    resolved: list[tuple[Pin, PackageRef]] = []
    for pin in PINS:
        refs = refs_by_manifest.get(pin.manifest_key, [])
        ref = find_ref(refs, pin.path, pin.channel)
        if ref is None:
            raise _drift(pin, f"在 {pin.channel} channel 上找不到（pin 的是 {pin.revision}）")
        if ref.revision != pin.revision:
            raise _drift(pin, f"pin 的是 {pin.revision}，manifest 現在是 {ref.revision}")
        if ref.sha1 != pin.sha1:
            # 版本號相同但 sha1 變了＝上游重新打包過。比 revision 改變更危險，
            # 因為它不會反映在任何版本號上。
            raise _drift(
                pin, f"revision {ref.revision} 相同但 sha1 不同（pin {pin.sha1}，manifest {ref.sha1}）"
            )
        resolved.append((pin, ref))
    return resolved
```

- [ ] **Step 4: 跑測試，確認全過**

Run: `cd tools/provision && python3 -m unittest discover -s tests -t . -v`
Expected: `Ran 19 tests` / `OK`

- [ ] **Step 5: Commit**

```bash
git add tools/provision/
git commit -m "feat(provision): pin 表與「manifest 漂移即中止」

設計文件 §4.3。manifest 對每個 path 只提供當下最新的一個 revision，上游一
bump，pin 的版本就從清單上消失——canary 37.2.1 就是這樣沒的。所以比對不符
一律中止，絕不默默採用新版：那會讓同一份 commit 在不同日子跑出不同環境。

同時擋「revision 相同但 sha1 變了」（上游重新打包），那比版本號改變更危險，
因為它不反映在任何版本號上。

錯誤訊息明講這是需要 commit 的決定，否則下一個人會直覺改 pin 讓它過。"
```

---

### Task 3：SDK 與 AVD 路徑解析

**Files:**
- Create: `tools/provision/lib/sdkpaths.py`
- Test: `tools/provision/tests/test_sdkpaths.py`

**Interfaces:**
- Consumes: 無
- Produces:
  - `sdk_root(env: dict[str, str], home: str) -> str`
  - `avd_home(env: dict[str, str], home: str) -> str`

**為什麼環境變數用參數傳入而不是讀 `os.environ`：** `lib/` 底下不得有副作用（全域約束）。
讀 `os.environ` 會讓測試必須 monkey-patch 全域狀態，而那正是測試互相污染的來源。

- [ ] **Step 1: 寫失敗的測試**

`tools/provision/tests/test_sdkpaths.py`：

```python
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


class AvdHomeTests(unittest.TestCase):
    def test_android_avd_home_wins(self):
        self.assertEqual(avd_home({"ANDROID_AVD_HOME": "/avds"}, HOME), "/avds")

    def test_default_is_dot_android_avd(self):
        self.assertEqual(avd_home({}, HOME), "/Users/tester/.android/avd")

    def test_empty_value_is_treated_as_unset(self):
        self.assertEqual(avd_home({"ANDROID_AVD_HOME": ""}, HOME), "/Users/tester/.android/avd")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑測試，確認它失敗**

Run: `cd tools/provision && python3 -m unittest tests.test_sdkpaths -v`
Expected: `ModuleNotFoundError: No module named 'lib.sdkpaths'`

- [ ] **Step 3: 實作 `lib/sdkpaths.py`**

```python
"""SDK 與 AVD 目錄的解析優先序。

**環境以參數傳入，不讀 os.environ**：`lib/` 底下不得有副作用，否則測試得去
monkey-patch 全域狀態，而那正是測試互相污染的來源。
"""
from __future__ import annotations

import posixpath


def _first_non_empty(env: dict[str, str], *names: str) -> str | None:
    """空字串視同未設定。

    `export ANDROID_SDK_ROOT=` 在 shell 裡很常見（例如被別的腳本清掉），
    照用會得到相對路徑，把整個 SDK 裝進當下的工作目錄。
    """
    for name in names:
        value = env.get(name, "").strip()
        if value:
            return value
    return None


def sdk_root(env: dict[str, str], home: str) -> str:
    """優先序：ANDROID_SDK_ROOT → ANDROID_HOME → ~/Library/Android/sdk。

    預設值必須與 `app/scripts/lib/verify_common.sh` 及
    `app/Sources/MirageShell/Detect/AdbClient.swift` 一致——不一致的話，
    這支腳本裝到 A、驗證腳本去 B 找，會以「adb 不存在」的形式現形。
    """
    explicit = _first_non_empty(env, "ANDROID_SDK_ROOT", "ANDROID_HOME")
    if explicit:
        return explicit
    return posixpath.join(home, "Library", "Android", "sdk")


def avd_home(env: dict[str, str], home: str) -> str:
    """優先序：ANDROID_AVD_HOME → ~/.android/avd。"""
    explicit = _first_non_empty(env, "ANDROID_AVD_HOME")
    if explicit:
        return explicit
    return posixpath.join(home, ".android", "avd")
```

- [ ] **Step 4: 跑測試，確認全過**

Run: `cd tools/provision && python3 -m unittest discover -s tests -t . -v`
Expected: `Ran 26 tests` / `OK`

- [ ] **Step 5: Commit**

```bash
git add tools/provision/
git commit -m "feat(provision): SDK 與 AVD 路徑解析

環境變數以參數傳入而不讀 os.environ——lib/ 底下不得有副作用，否則測試得
monkey-patch 全域狀態。

空字串視同未設定：export ANDROID_SDK_ROOT= 在 shell 裡很常見，照用會得到
相對路徑，把整個 SDK 裝進當下的工作目錄。

預設值與 verify_common.sh、AdbClient.swift 對齊；不一致會以「adb 不存在」
的形式現形。"
```

---

### Task 4：AVD 規格與 `config.ini` 產生

**Files:**
- Create: `tools/provision/lib/avdspec.py`
- Create: `tools/provision/lib/config_base.py`（由指令產生一次後進 git）
- Create: `tools/provision/lib/config_ini.py`
- Test: `tools/provision/tests/test_config_ini.py`

**Interfaces:**
- Consumes: 無
- Produces:
  - `@dataclass(frozen=True) class AvdSpec: name: str; sysdir: str; playstore: bool; tag_id: str; tag_display: str`
  - `SPECS: tuple[AvdSpec, ...]`（`mirage-poc`、`mirage-game`）
  - `BASE: dict[str, str]`（`config_base.py`）
  - `expected_config(spec: AvdSpec) -> dict[str, str]`
  - `render_config(spec: AvdSpec) -> str`
  - `parse_config(text: str) -> dict[str, str]`
  - `render_pointer_ini(spec: AvdSpec, avd_home: str) -> str`

**格式細節（實地確認，兩者不同，不要統一）：** `config.ini` 用 `key = value`（等號兩側有
空格）；頂層的 `<name>.ini` 指標檔用 `key=value`（**沒有空格**）。

**overlay 只有 8 個欄位**：`avd.id`、`avd.name`、`image.sysdir.1`、`PlayStore.enabled`、
`tag.id`、`tag.ids`、`tag.display`、`tag.displaynames`。其餘 131 欄兩台共用。

- [ ] **Step 1: 產生 `lib/config_base.py`**

以現有 `mirage-game.avd/config.ini` 為底（三台裡最乾淨的一份——`mirage-poc` 帶著字面上
未取代的 `<build>`／`<temp>` 佔位符，是手工來源的疤痕，不可作為範本）。

```bash
mkdir -p tools/provision/lib
python3 - > tools/provision/lib/config_base.py <<'PY'
import os

OVERLAY = {
    "avd.id", "avd.name", "image.sysdir.1", "PlayStore.enabled",
    "tag.id", "tag.ids", "tag.display", "tag.displaynames",
}
src = os.path.expanduser("~/.android/avd/mirage-game.avd/config.ini")
pairs = []
with open(src, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if key in OVERLAY:
            continue
        pairs.append((key, value))

print('"""兩台 AVD 共用的 `config.ini` 欄位。')
print()
print("由 `mirage-game.avd/config.ini` 產生一次後進 git（產生指令記在")
print("`docs/plans/2026-07-31-d33-avd-provisioning.md` Task 4 Step 1）。")
print()
print("**為什麼以 mirage-game 為底**：三台裡只有它是乾淨的。`mirage-poc` 帶著字面上")
print("未取代的 `<build>`／`<temp>` 佔位符——那是手工建立留下的疤痕，拿它當範本等於")
print("把疤痕永久化。")
print()
print("**不含 overlay 的 8 個欄位**（avd.id/avd.name/image.sysdir.1/PlayStore.enabled/")
print("tag.id/tag.ids/tag.display/tag.displaynames），那些由 `config_ini.expected_config`")
print('依 `AvdSpec` 補上。"""')
print()
print("BASE = {")
for key, value in sorted(pairs):
    print(f"    {key!r}: {value!r},")
print("}")
PY
```

產生後檢查：`grep -c ':' tools/provision/lib/config_base.py` 應為 131 左右，且
`grep -E '<build>|<temp>' tools/provision/lib/config_base.py` 必須無輸出。

- [ ] **Step 2: 寫失敗的測試**

`tools/provision/tests/test_config_ini.py`：

```python
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
```

- [ ] **Step 3: 跑測試，確認它失敗**

Run: `cd tools/provision && python3 -m unittest tests.test_config_ini -v`
Expected: `ModuleNotFoundError: No module named 'lib.avdspec'`

- [ ] **Step 4: 實作 `lib/avdspec.py`**

```python
"""兩台 AVD 的規格。**純資料，沒有行為。**

只有兩台：`mirage-poc`（default image）與 `mirage-game`（playstore image），
非映像設定完全一致——兩台只差 system image，跨台的 fps 數字才可直接比較。

原本的第三台 `mirage-bench` 統一設定後會與 `mirage-poc` 完全重複，所以不再
產出。**腳本不認識它**：不產出、不報告、不動既有的那一台（量測記錄
`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §13.2 引用了它）。
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AvdSpec:
    name: str
    sysdir: str
    playstore: bool
    tag_id: str
    tag_display: str


SPECS = (
    AvdSpec(
        name="mirage-poc",
        sysdir="system-images/android-35/default/arm64-v8a/",
        playstore=False,
        tag_id="default",
        tag_display="Default Android System Image",
    ),
    AvdSpec(
        name="mirage-game",
        sysdir="system-images/android-35/google_apis_playstore/arm64-v8a/",
        playstore=True,
        tag_id="google_apis_playstore",
        tag_display="Google Play",
    ),
)
```

- [ ] **Step 5: 實作 `lib/config_ini.py`**

```python
"""`AvdSpec` 與 `config.ini` 文字之間的轉換。純函式，不碰磁碟。

**兩種格式，刻意不統一**（皆為實地確認）：
- `config.ini` 是 `key = value`（等號兩側有空格）——emulator 自己寫出來就長這樣
- 頂層的 `<name>.ini` 指標檔是 `key=value`（**沒有空格**）

改格式不會讓 emulator 讀不懂，但會讓每個欄位都出現在 diff 裡，把真正的差異埋掉。
"""
from __future__ import annotations

from lib.avdspec import AvdSpec
from lib.config_base import BASE


def expected_config(spec: AvdSpec) -> dict[str, str]:
    """共用的 BASE 疊上這台的 8 個 overlay 欄位。"""
    config = dict(BASE)
    config.update(
        {
            "avd.id": spec.name,
            "avd.name": spec.name,
            "image.sysdir.1": spec.sysdir,
            "PlayStore.enabled": "yes" if spec.playstore else "no",
            "tag.id": spec.tag_id,
            "tag.ids": spec.tag_id,
            "tag.display": spec.tag_display,
            "tag.displaynames": spec.tag_display,
        }
    )
    return config


def render_config(spec: AvdSpec) -> str:
    """key 排序後輸出。**排序是為了輸出穩定**——不穩定的話每次跑都會報成漂移。"""
    config = expected_config(spec)
    return "".join(f"{key} = {config[key]}\n" for key in sorted(config))


def parse_config(text: str) -> dict[str, str]:
    """容忍有無空格兩種寫法：手寫的 config.ini 未必照 emulator 的格式。"""
    result: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        result[key.strip()] = value.strip()
    return result


def render_pointer_ini(spec: AvdSpec, avd_home: str) -> str:
    """頂層的 `<name>.ini`。

    `path` 是**絕對路徑**，所以這個檔一定要產生、不能複製——這也是為什麼
    provisioning 天生就得是腳本，而不是「把目錄壓起來給別人」。
    """
    return (
        "avd.ini.encoding=UTF-8\n"
        f"path={avd_home}/{spec.name}.avd\n"
        f"path.rel=avd/{spec.name}.avd\n"
        "target=android-35\n"
    )
```

- [ ] **Step 6: 跑測試，確認全過**

Run: `cd tools/provision && python3 -m unittest discover -s tests -t . -v`
Expected: `Ran 41 tests` / `OK`

- [ ] **Step 7: Commit**

```bash
git add tools/provision/
git commit -m "feat(provision): 兩台 AVD 的規格與 config.ini 產生

以 mirage-game 的 config.ini 為範本（三台裡唯一乾淨的一份）——mirage-poc 帶著
字面上未取代的 <build>／<temp> 佔位符，拿它當範本等於把手工的疤痕永久化。
測試明確擋掉範本裡出現任何 '<'。

兩台只差 8 個 overlay 欄位，其餘 131 欄共用；有一條測試直接斷言「差異集合恰好
等於那 8 個 key」，因為兩台設定一致正是跨台 fps 數字可比較的前提。

config.ini 用 'key = value'、指標檔用 'key=value'，兩者實地確認過，刻意不統一：
改格式會讓每個欄位都出現在 diff 裡，把真正的差異埋掉。"
```

---

### Task 5：漂移比對

**Files:**
- Create: `tools/provision/lib/drift.py`
- Test: `tools/provision/tests/test_drift.py`

**Interfaces:**
- Consumes: 無（只吃 `dict[str, str]` 與字串）
- Produces:
  - `@dataclass(frozen=True) class Diff: key: str; current: str | None; expected: str | None`
  - `config_drift(current: dict[str, str], expected: dict[str, str]) -> list[Diff]`
  - `package_drift(path: str, installed: str | None, pinned: str) -> Diff | None`

- [ ] **Step 1: 寫失敗的測試**

`tools/provision/tests/test_drift.py`：

```python
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
```

- [ ] **Step 2: 跑測試，確認它失敗**

Run: `cd tools/provision && python3 -m unittest tests.test_drift -v`
Expected: `ModuleNotFoundError: No module named 'lib.drift'`

- [ ] **Step 3: 實作 `lib/drift.py`**

```python
"""現況與規格的差異。純函式：兩個 mapping 進、差異清單出。"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Diff:
    key: str
    current: str | None   # None ＝ 現況沒有這一項
    expected: str | None  # None ＝ 規格沒有這一項（多出來的）


def config_drift(current: dict[str, str], expected: dict[str, str]) -> list[Diff]:
    """**多出來的欄位也算漂移。**

    `mirage-poc` 有多出來的 `disk.dataPartition.path = <temp>`；`--apply` 會
    整份重寫，不報的話那個欄位會靜默消失，看的人不知道發生過什麼。

    排序輸出：順序不穩定的話，同一種漂移每次印出來長得不一樣，看的人會以為
    情況變了。
    """
    diffs = []
    for key in sorted(current.keys() | expected.keys()):
        before, after = current.get(key), expected.get(key)
        if before != after:
            diffs.append(Diff(key=key, current=before, expected=after))
    return diffs


def package_drift(path: str, installed: str | None, pinned: str) -> Diff | None:
    """`installed` 為 None 代表沒裝；為空字串代表裝了但版本讀不出來。

    **「讀不出來」不可以當成「符合」**：現裝的 google_apis_playstore 映像就
    沒有 `package.xml`，版本無從追溯——那正是 D33 記載的手工環境問題本體。
    """
    if installed == pinned:
        return None
    return Diff(key=path, current=installed, expected=pinned)
```

- [ ] **Step 4: 跑測試，確認全過**

Run: `cd tools/provision && python3 -m unittest discover -s tests -t . -v`
Expected: `Ran 51 tests` / `OK`

- [ ] **Step 5: Commit**

```bash
git add tools/provision/
git commit -m "feat(provision): 漂移比對

多出來的欄位也算漂移：mirage-poc 有多餘的 disk.dataPartition.path = <temp>，
--apply 會整份重寫，不報的話它會靜默消失。

package 的「版本讀不出來」不可當成「符合」——現裝的 playstore 映像沒有
package.xml，版本無從追溯，而那正是 D33 記載的手工環境問題本體。

輸出排序：順序不穩定的話，同一種漂移每次印出來長得不一樣，看的人會以為
情況變了。"
```

---

### Task 6：`fetch.py`——唯一有副作用的模組

**Files:**
- Create: `tools/provision/fetch.py`
- Test: `tools/provision/tests/test_fetch.py`

**Interfaces:**
- Consumes: `lib.manifest.parse_local_revision`
- Produces:
  - `class FetchError(Exception)`
  - `fetch_text(url: str, *, timeout: int = 60) -> str`
  - `verify_sha1(path: str, expected: str) -> None`（不符則**刪檔**再拋 `FetchError`）
  - `ensure_space(path: str, needed: int) -> None`
  - `download(url: str, dest: str, expected_sha1: str, expected_size: int) -> None`
  - `extract_into(zip_path: str, install_dir: str) -> None`
  - `installed_revision(sdk_root: str, install_path: str) -> str | None`

**測試不需要網路。** sha1 驗證與解壓都用 `tempfile` + `zipfile` 當場造出來的檔案測，
唯一沒有自動測試的是 `fetch_text`（三行 `urllib`），它在 Task 9 的真下載裡驗。

**`extract_into` 不寫死 zip 的最外層目錄名。** 我們無法在不下載 1.8GB 的前提下確認
sys-img zip 解開後的最外層叫什麼，所以**解壓到暫存目錄後檢查實際內容**：恰好一個目錄
就把它 move 到位，否則拋錯。少一個猜錯就會裝歪的常數。

- [ ] **Step 1: 寫失敗的測試**

`tools/provision/tests/test_fetch.py`：

```python
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
```

- [ ] **Step 2: 跑測試，確認它失敗**

Run: `cd tools/provision && python3 -m unittest tests.test_fetch -v`
Expected: `ModuleNotFoundError: No module named 'fetch'`

- [ ] **Step 3: 實作 `fetch.py`**

```python
"""**唯一碰網路與磁碟的模組。**

`lib/` 底下全是純函式，副作用集中在這裡——這條邊界就是「不下載 GB 也能測」
的機制（設計文件 §6）。這個檔案本身的測試用 tempfile 與 zipfile 當場造檔案，
一樣不需要網路；唯一沒有自動測試的是 `fetch_text`。

**原則：任何中止都不可以留下「看起來裝好了但其實壞掉」的狀態。**
"""
from __future__ import annotations

import hashlib
import os
import shutil
import tempfile
import urllib.error
import urllib.request
import zipfile

from lib.manifest import ManifestError, parse_local_revision


class FetchError(Exception):
    """網路、checksum 或解壓失敗。"""


def fetch_text(url: str, *, timeout: int = 60) -> str:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        raise FetchError(f"{url} → HTTP {error.code}") from error
    except OSError as error:
        raise FetchError(f"{url} → {error}") from error


def verify_sha1(path: str, expected: str) -> None:
    """不符就**刪檔**。

    留下壞檔案的話，下一次跑會看到「檔案已存在」而跳過下載，
    於是那個壞檔案就永久留在那裡了。
    """
    digest = hashlib.sha1()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual != expected:
        os.remove(path)
        raise FetchError(f"{os.path.basename(path)} 的 sha1 是 {actual}，預期 {expected}（已刪除）")


def ensure_space(path: str, needed: int) -> None:
    """下載前先估算（設計文件 §9）。

    空間不足時讓下載跑到一半才失敗，會留下 GB 級的半成品，而且錯誤訊息指向
    I/O error 而不是真正的原因。manifest 本來就提供 size，先問一次很便宜。

    留 20% 餘裕：解壓時 zip 與解開後的內容會同時存在。
    """
    usage = shutil.disk_usage(path)
    required = int(needed * 1.2)
    if usage.free < required:
        raise FetchError(
            f"{path} 剩餘空間 {usage.free // (1 << 20)} MiB，"
            f"這一步需要約 {required // (1 << 20)} MiB（含解壓餘裕）"
        )


def download(url: str, dest: str, expected_sha1: str, expected_size: int) -> None:
    """先下載到 `.part` 再改名——中斷留下的半成品不會被誤認為完整檔案。"""
    part = dest + ".part"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    ensure_space(os.path.dirname(dest), expected_size)
    try:
        with urllib.request.urlopen(url, timeout=120) as response, open(part, "wb") as out:
            shutil.copyfileobj(response, out, length=1024 * 1024)
    except OSError as error:
        if os.path.exists(part):
            os.remove(part)
        raise FetchError(f"下載 {url} 失敗：{error}") from error

    actual_size = os.path.getsize(part)
    if actual_size != expected_size:
        os.remove(part)
        raise FetchError(f"{url} 的大小是 {actual_size}，預期 {expected_size}（已刪除）")
    verify_sha1(part, expected_sha1)
    os.replace(part, dest)


def extract_into(zip_path: str, install_dir: str) -> None:
    """解壓並就位。

    **不寫死 zip 的最外層目錄名**：在不下載 1.8GB 的前提下無法確認 sys-img
    zip 解開後最外層叫什麼，所以解到暫存目錄後**檢查實際內容**——恰好一個
    目錄就把它 move 到位，否則拋錯。少一個猜錯就會裝歪的常數。

    **失敗要還原**：舊目錄先移到旁邊，成功才刪。中途失敗卻把舊的刪了，
    等於用一次失敗的升級換掉一個本來能跑的環境。
    """
    parent = os.path.dirname(install_dir.rstrip("/")) or "."
    os.makedirs(parent, exist_ok=True)
    staging = tempfile.mkdtemp(prefix=".provision-", dir=parent)
    backup = None
    try:
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(staging)
        entries = os.listdir(staging)
        if len(entries) != 1 or not os.path.isdir(os.path.join(staging, entries[0])):
            raise FetchError(
                f"{os.path.basename(zip_path)} 解開後最外層有 {len(entries)} 個項目，"
                f"預期恰好一個目錄：{entries[:5]}"
            )
        if os.path.exists(install_dir):
            backup = install_dir + ".provision-old"
            if os.path.exists(backup):
                shutil.rmtree(backup)
            os.rename(install_dir, backup)
        os.rename(os.path.join(staging, entries[0]), install_dir)
    except Exception:
        if backup is not None and not os.path.exists(install_dir):
            os.rename(backup, install_dir)
            backup = None
        raise
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        if backup is not None:
            shutil.rmtree(backup, ignore_errors=True)


def installed_revision(sdk_root: str, install_path: str) -> str | None:
    """`None` ＝ 沒裝；`""` ＝ 裝了但版本讀不出來。

    這兩者必須分得開：現裝的 google_apis_playstore 映像就是後者——目錄在、
    但沒有 `package.xml`，版本無從追溯。那正是 D33 記載的手工環境問題本體。
    """
    target = os.path.join(sdk_root, install_path)
    if not os.path.isdir(target):
        return None
    package_xml = os.path.join(target, "package.xml")
    if not os.path.isfile(package_xml):
        return ""
    try:
        with open(package_xml, encoding="utf-8") as handle:
            return parse_local_revision(handle.read())
    except (OSError, ManifestError):
        return ""
```

- [ ] **Step 4: 跑測試，確認全過**

Run: `cd tools/provision && python3 -m unittest discover -s tests -t . -v`
Expected: `Ran 62 tests` / `OK`

- [ ] **Step 5: Commit**

```bash
git add tools/provision/
git commit -m "feat(provision): fetch——唯一有副作用的模組

extract_into 不寫死 zip 的最外層目錄名：在不下載 1.8GB 的前提下無法確認
sys-img zip 解開後最外層叫什麼，所以解到暫存目錄後檢查實際內容，恰好一個
目錄就 move 到位，否則拋錯。少一個猜錯就會裝歪的常數。

失敗要還原：舊目錄先移到旁邊、成功才刪。中途失敗卻把舊的刪了，等於用一次
失敗的升級換掉一個本來能跑的環境。有測試守這一條。

sha1 不符就刪檔——留著的話下一次跑會因為「檔案已存在」而跳過下載，壞檔案
就永久留在那裡。

installed_revision 用 None 與空字串區分「沒裝」與「裝了但版本讀不出來」：
現裝的 playstore 映像正是後者，而把「不知道」當成「符合」正是 D33 的病本體。

測試全部用 tempfile + zipfile 當場造檔案，不需要網路。"
```

---

### Task 7：CLI

**Files:**
- Create: `tools/provision/lib/report.py`
- Create: `tools/provision/provision.py`
- Test: `tools/provision/tests/test_report.py`

**Interfaces:**
- Consumes: 全部先前模組
- Produces:
  - `@dataclass(frozen=True) class Row: label: str; ok: bool; detail: str; hint: str`
  - `format_report(title: str, rows: list[Row]) -> str`
  - `exit_code(rows: list[Row]) -> int`
  - `provision.py` 的 `main(argv: list[str]) -> int`

**報告的純邏輯放 `lib/report.py`**，`provision.py` 只負責接線與真正的 I/O——這樣輸出格式
與退出碼可以離線測試。

- [ ] **Step 1: 寫失敗的測試**

`tools/provision/tests/test_report.py`：

```python
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
        text = format_report("SDK", [Row("a", True, "", ""), Row("b", False, "x", "")])
        self.assertIn("✓", text)
        self.assertIn("✗", text)

    def test_title_appears_first(self):
        text = format_report("SDK: /path", [Row("a", True, "", "")])
        self.assertTrue(text.startswith("SDK: /path"))

    def test_empty_rows_still_renders_title(self):
        self.assertIn("SDK", format_report("SDK", []))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑測試，確認它失敗**

Run: `cd tools/provision && python3 -m unittest tests.test_report -v`
Expected: `ModuleNotFoundError: No module named 'lib.report'`

- [ ] **Step 3: 實作 `lib/report.py`**

```python
"""報告的純邏輯：格式與退出碼。與 I/O 分開才能離線測試。"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Row:
    label: str
    ok: bool
    detail: str
    hint: str  # 只在 ok=False 時印


def format_report(title: str, rows: list[Row]) -> str:
    lines = [title]
    for row in rows:
        mark = "✓" if row.ok else "✗"
        # 提示只印在有問題的那一列：符合的項目印提示只會製造雜訊，
        # 讓真正該做的事更難被看到。
        suffix = f"  （{row.hint}）" if (not row.ok and row.hint) else ""
        lines.append(f"  {row.label:<34} {row.detail:<30} {mark}{suffix}")
    return "\n".join(lines) + "\n"


def exit_code(rows: list[Row]) -> int:
    """`0` 一律代表「現況等於規格」，與給了哪些旗標無關。"""
    return 1 if any(not row.ok for row in rows) else 0
```

- [ ] **Step 4: 實作 `provision.py`**

```python
#!/usr/bin/env python3
"""Mirage 的 AVD provisioning。

用法：
    python3 provision.py              # 只報告，一行都不寫
    python3 provision.py --apply      # 另外寫 AVD 的 .ini 與 config.ini
    python3 provision.py --upgrade    # 另外覆蓋 SDK 裡的 package

缺失的東西一律直接裝（無破壞風險）；**已存在但不符**才需要旗標。
兩個旗標分開的理由：改 config.ini 的 RAM 會讓既有快照失效，換 emulator 則
影響整台機器上所有已量測的數字——後果不同級，不該由同一個旗標決定。
"""
from __future__ import annotations

import argparse
import os
import platform
import sys
import tempfile

import fetch
from lib import config_ini, drift, manifest, report, sdkpaths, versions
from lib.avdspec import SPECS

_HOST_OS = {"Darwin": "macosx", "Linux": "linux"}
_HOST_ARCH = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x64"}


def _resolve() -> list[tuple[versions.Pin, manifest.PackageRef]]:
    host_os = _HOST_OS.get(platform.system(), platform.system().lower())
    host_arch = _HOST_ARCH.get(platform.machine(), platform.machine())
    refs = {}
    for key, url in versions.MANIFESTS.items():
        refs[key] = manifest.parse_manifest(
            fetch.fetch_text(url),
            versions.MANIFEST_BASES[key],
            host_os=host_os,
            host_arch=host_arch,
        )
    return versions.resolve_pins(refs)


def _sdk_rows(sdk_root: str, resolved, upgrade: bool, cache: str) -> list[report.Row]:
    rows = []
    for pin, ref in resolved:
        installed = fetch.installed_revision(sdk_root, pin.install_path)
        difference = drift.package_drift(pin.path, installed, pin.revision)
        if difference is None:
            rows.append(report.Row(pin.path, True, pin.revision, ""))
            continue
        # 沒裝＝直接裝，無破壞風險；已裝但不符＝需要 --upgrade。
        may_write = installed is None or upgrade
        if may_write:
            zip_path = os.path.join(cache, os.path.basename(ref.url))
            if not os.path.exists(zip_path):
                fetch.download(ref.url, zip_path, ref.sha1, ref.size)
            fetch.extract_into(zip_path, os.path.join(sdk_root, pin.install_path))
            rows.append(report.Row(pin.path, True, f"已安裝 {pin.revision}", ""))
        else:
            shown = "版本無從追溯" if installed == "" else installed
            rows.append(
                report.Row(pin.path, False, f"{shown} ≠ {pin.revision}", "--upgrade 可更新")
            )
    return rows


def _avd_rows(avd_home: str, apply_changes: bool) -> list[report.Row]:
    rows = []
    for spec in SPECS:
        avd_dir = os.path.join(avd_home, spec.name + ".avd")
        config_path = os.path.join(avd_dir, "config.ini")
        exists = os.path.isfile(config_path)
        current = {}
        if exists:
            with open(config_path, encoding="utf-8") as handle:
                current = config_ini.parse_config(handle.read())
        diffs = drift.config_drift(current, config_ini.expected_config(spec))
        if not diffs:
            rows.append(report.Row(spec.name, True, "符合", ""))
            continue
        if not exists or apply_changes:
            os.makedirs(avd_dir, exist_ok=True)
            with open(config_path, "w", encoding="utf-8") as handle:
                handle.write(config_ini.render_config(spec))
            pointer = os.path.join(avd_home, spec.name + ".ini")
            with open(pointer, "w", encoding="utf-8") as handle:
                handle.write(config_ini.render_pointer_ini(spec, avd_home))
            rows.append(report.Row(spec.name, True, "已建立" if not exists else "已修正", ""))
            continue
        head = "；".join(
            f"{d.key} {d.current!r}→{d.expected!r}" for d in diffs[:3]
        )
        more = f"（共 {len(diffs)} 項）" if len(diffs) > 3 else ""
        rows.append(report.Row(spec.name, False, head + more, "--apply 可修正"))
    return rows


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="建立 Mirage 的 Android SDK 與兩台 AVD")
    parser.add_argument("--apply", action="store_true", help="覆寫已存在但不符的 AVD 設定")
    parser.add_argument("--upgrade", action="store_true", help="覆蓋已安裝但版本不符的 SDK package")
    parser.add_argument("--sdk-root", default=None)
    parser.add_argument("--avd-home", default=None)
    args = parser.parse_args(argv)

    home = os.path.expanduser("~")
    sdk_root = args.sdk_root or sdkpaths.sdk_root(dict(os.environ), home)
    avd_home = args.avd_home or sdkpaths.avd_home(dict(os.environ), home)

    try:
        resolved = _resolve()
    except (fetch.FetchError, manifest.ManifestError, versions.PinDriftError) as error:
        print(f"錯誤：{error}", file=sys.stderr)
        return 2

    cache = os.path.join(tempfile.gettempdir(), "mirage-provision-cache")
    os.makedirs(cache, exist_ok=True)
    try:
        sdk_rows = _sdk_rows(sdk_root, resolved, args.upgrade, cache)
        avd_rows = _avd_rows(avd_home, args.apply)
    except fetch.FetchError as error:
        print(f"錯誤：{error}", file=sys.stderr)
        return 2

    print(report.format_report(f"SDK: {sdk_root}", sdk_rows), end="")
    print(report.format_report(f"AVD: {avd_home}", avd_rows), end="")
    return report.exit_code(sdk_rows + avd_rows)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
```

- [ ] **Step 5: 跑測試與煙霧測試**

Run: `cd tools/provision && python3 -m unittest discover -s tests -t . -v`
Expected: `Ran 69 tests` / `OK`

Run: `cd tools/provision && python3 provision.py --sdk-root /tmp/nope --avd-home /tmp/nope-avd --help`
Expected: 印出說明並 exit 0（確認 argparse 接線沒壞；此步不連網）

- [ ] **Step 6: Commit**

```bash
git add tools/provision/
git commit -m "feat(provision): CLI 與報告

報告的純邏輯（格式與退出碼）放 lib/report.py，provision.py 只做接線與真正的
I/O——這樣輸出格式與退出碼可以離線測試。

提示只印在有問題的那一列：符合的項目印提示只會製造雜訊，讓真正該做的事更難
被看到。

缺失的東西直接裝（無破壞風險），已存在但不符才需要旗標；--apply 與 --upgrade
分開，因為改 config.ini 的 RAM 會讓既有快照失效、換 emulator 則影響整台機器
所有已量測的數字，後果不同級。"
```

---

### Task 8：`ci.sh` 閘門 6

**Files:**
- Modify: `app/scripts/ci.sh`（在閘門 5 之後、最終總結之前插入）

**Interfaces:**
- Consumes: `tools/provision/tests/`
- Produces: 無（閘門）

**為什麼需要這道閘門：** `tools/probe/tests/` 有 13 個測試檔全部用 pytest，而這台機器
**沒有裝 pytest**，也沒有任何腳本或 CI 步驟會跑它們——**那 13 個檔案現在是死的**。
不加閘門的話，這個 task 寫的測試會落入完全相同的下場。

**注意 `ci.sh` 的工作目錄是 `app/`**（開頭有 `cd "$(dirname "$0")/.."`），所以路徑是
`../tools/provision`。

- [ ] **Step 1: 插入閘門 6**

在 `app/scripts/ci.sh` 的閘門 5 區塊之後、`echo "======"` 總結之前插入：

```bash
echo ""
echo "=== 閘門 6：tools/provision 的 Python 測試 ==="
# 2026-07-31 新增（D33）。**加這道閘門的理由是「沒有它，測試就是死的」**：
# tools/probe/tests/ 有 13 個測試檔全部用 pytest，而本機沒有裝 pytest
# （`python3 -m pytest` → `No module named pytest`），也沒有任何腳本或 CI 步驟
# 會跑它們。寫了但沒有任何東西會執行的測試比沒有測試更糟——它讓人以為有涵蓋。
#
# 所以 tools/provision 一律用標準函式庫的 unittest（零依賴），並由這道閘門執行。
#
# **路徑**：本腳本開頭 `cd "$(dirname "$0")/.."`，工作目錄是 app/，
# 所以要往上一層找 tools/。
# **`-t .`**：把 top-level 設為 tools/provision，測試才 import 得到 lib/。
# tests/__init__.py 必須存在，否則 unittest 會回
# `ImportError: Start directory is not importable`（實測）。
PROVISION_DIR="../tools/provision"
if [ ! -d "$PROVISION_DIR/tests" ]; then
    fail "找不到 ${PROVISION_DIR}/tests——閘門 6 沒有東西可跑"
else
    PROVISION_LOG=$(mktemp)
    if (cd "$PROVISION_DIR" && python3 -m unittest discover -s tests -t .) \
        > "$PROVISION_LOG" 2>&1; then
        ok "tools/provision 測試通過（$(grep -oE 'Ran [0-9]+ tests?' "${PROVISION_LOG}" | tail -1)）"
        rm -f "$PROVISION_LOG"
    else
        fail "tools/provision 測試失敗："
        tail -20 "$PROVISION_LOG"
        echo "   完整 log 保留在：${PROVISION_LOG}"
    fi
fi
```

同時把最終總結那一行改成：

```bash
全部通過（$RUNS 次跑次、0 行 NIO ERROR、無假 skip、無全形標點陷阱、無永不紅的 #expect、provision 測試綠）
```

- [ ] **Step 2: 語法檢查**

Run: `bash -n app/scripts/ci.sh`
Expected: 無輸出

- [ ] **Step 3: 乾淨跑，確認閘門 6 綠**

Run: `cd app && ./scripts/ci.sh`
Expected: `CI_EXIT=0`，輸出含 `✅ tools/provision 測試通過（Ran NN tests）`

- [ ] **Step 4: 故障注入，證明閘門 6 會紅**

**本專案的規矩：沒有被證明會紅的閘門等於沒有閘門。**

```bash
cat >> tools/provision/tests/test_drift.py <<'EOF'


class G6FaultInjection(unittest.TestCase):
    def test_injected_failure(self):
        self.assertEqual(1, 2)
EOF
cd app && ./scripts/ci.sh; echo "CI_EXIT=$?"
```

Expected: `CI_EXIT=1`，且輸出含 `❌ tools/provision 測試失敗：` 與 `FAILED (failures=1)`

還原：

```bash
cd /Users/hanfourhuang/Projects/mirage
git checkout tools/provision/tests/test_drift.py
```

- [ ] **Step 5: 再跑一次確認乾淨**

Run: `cd app && ./scripts/ci.sh; echo "CI_EXIT=$?"`
Expected: `CI_EXIT=0`，六道閘門全綠

- [ ] **Step 6: Commit**

```bash
git add app/scripts/ci.sh
git commit -m "ci: 閘門 6 跑 tools/provision 的 Python 測試

加這道閘門的理由是「沒有它，測試就是死的」：tools/probe/tests/ 有 13 個測試檔
全部用 pytest，而本機沒裝 pytest、也沒有任何腳本或 CI 會跑它們——那 13 個檔案
現在是死的。不加閘門的話，D33 這批測試會落入完全相同的下場。

所以 tools/provision 一律用標準函式庫的 unittest（零依賴），由閘門執行。

已用故障注入證明會紅：注入一條 assertEqual(1, 2) 後 CI_EXIT=1、訊息指出
FAILED (failures=1)。"
```

---

### Task 9：真下載的端到端驗證與文件收尾

**Files:**
- Modify: `docs/specs/2026-07-29-project-review.md`（D33 條目與 §6 說明）
- Create: `tools/provision/README.md`

**Interfaces:**
- Consumes: 全部先前 task
- Produces: 無程式碼

**這個 task 是唯一會碰網路的驗證**，且**只下載 platform-tools**（16MB，四個 package 裡
最小的）。**不要在任何自動化流程裡放 GB 級下載。**

- [ ] **Step 1: 用暫存的 SDK root 驗端到端**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/provision
TMPSDK=$(mktemp -d)
TMPAVD=$(mktemp -d)
python3 provision.py --sdk-root "$TMPSDK" --avd-home "$TMPAVD"; echo "exit=$?"
```

Expected：`platform-tools` 那一列變成 `已安裝 37.0.1`（16MB，數秒）。**其餘三個 package
會真的開始下載（含 1.8GB 的 playstore 映像）——看到 platform-tools 成功之後就 Ctrl-C**，
這一步要驗的是「下載 → 驗 sha1 → 解壓 → 就位」這條鏈路會動，不是把整個 SDK 裝一遍。

- [ ] **Step 2: 確認裝出來的東西是對的**

```bash
ls "$TMPSDK/platform-tools/adb" && "$TMPSDK/platform-tools/adb" version | head -1
grep -o 'path="platform-tools"' "$TMPSDK/platform-tools/package.xml"
```

Expected：`adb` 存在且可執行、印出版本；`package.xml` 存在（證明 `extract_into` 的
「恰好一個最外層目錄」推論對真 zip 成立）。

- [ ] **Step 3: 確認 AVD 產生正確且冪等**

```bash
python3 provision.py --sdk-root "$TMPSDK" --avd-home "$TMPAVD" 2>/dev/null | grep mirage
cat "$TMPAVD/mirage-poc.ini"
python3 provision.py --sdk-root "$TMPSDK" --avd-home "$TMPAVD" 2>/dev/null | grep mirage
```

Expected：第一次兩台皆 `已建立`；`.ini` 的 `path` 是 `$TMPAVD` 底下的絕對路徑；
**第二次兩台皆 `符合 ✓`**（冪等）。

- [ ] **Step 4: 確認在真環境上是唯讀的**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/provision
python3 provision.py; echo "exit=$?"
git -C /Users/hanfourhuang/Projects/mirage status --short
```

Expected：`exit=1`（有漂移：emulator 37.2.1 ≠ 37.1.11、mirage-poc 的 RAM 與佔位符），
**且 `~/.android/avd` 與 SDK 一行都沒被改**。用 `ls -l ~/.android/avd/mirage-poc.avd/config.ini`
的 mtime 對照執行前後確認。

清理：`rm -rf "$TMPSDK" "$TMPAVD"`

- [ ] **Step 5: 寫 `tools/provision/README.md`**

```markdown
# Mirage AVD Provisioning

在一台只有 Xcode CommandLineTools 的 Mac 上，把 Android SDK 與兩台 Mirage AVD
建到與 git 裡宣告的規格一致。**不需要 JDK**（`avdmanager`／`sdkmanager` 需要 Java，
本專案刻意不依賴它們）。

## 用法

    python3 provision.py              # 只報告，一行都不寫
    python3 provision.py --apply      # 另外覆寫已存在但不符的 AVD 設定
    python3 provision.py --upgrade    # 另外覆蓋已安裝但版本不符的 SDK package

缺失的東西一律直接裝。退出碼：`0` = 現況等於規格；`1` = 仍有漂移；`2` = 錯誤。

## 測試

    python3 -m unittest discover -s tests -t . -v

離線、零依賴、不下載任何東西。由 `app/scripts/ci.sh` 的閘門 6 執行。

## 會做與不會做

**不會**幫你登入 Google 帳號或安裝遊戲——那需要人。自動化的天花板是
「兩台一致的 AVD 可被重建」。遊戲請走 sideload（`app/scripts/verify_apk_install.sh`）
或人工登入。

## 升版

`lib/versions.py` 的 `PINS` 是唯一的版本來源。上游 bump 之後腳本會**主動報錯中止**
（manifest 對每個 package 只提供當下最新的一個 revision），這是設計而非故障：
它逼一個人來確認新版可用，並讓換環境留下 commit。

設計文件：`docs/specs/2026-07-31-d33-avd-provisioning-design.md`
```

- [ ] **Step 6: 更新 D33 條目與 §6 表格**

在 `docs/specs/2026-07-29-project-review.md`：

**(a)** 把 D33 那一列的**債務名稱**加上刪除線（`| ~~**D33**~~ |`），並在**成本欄**逐字寫入：

> **✅ 已修（(b) 2026-07-30，(a) 2026-07-31）**。(b)：§6 的 ✅ 已標明前提。(a)：`tools/provision/` 可由 manifest 重建 SDK 與兩台 AVD，不依賴 JDK。**天花板沒有變**——Play Store 登入不可自動化，自動化只到「兩台一致的 AVD 可被重建」。三台收成兩台（統一後 `mirage-bench` 與 `mirage-poc` 完全重複），既有的 `mirage-bench` 不動。

**(b)** 把 §6 表格「1 款指標遊戲開箱即玩」那一列的**瓶頸欄**改成：

> **前提：先跑 `tools/provision/provision.py --apply --upgrade`，再人工登入 Play Store 或 sideload APK**

**(c)** §6 表下的三點查證事實**全部保留**：第 1 點（`avdmanager`／`sdkmanager` 無 Java）
仍是本設計不依賴 JDK 的理由；第 2、3 點記錄的是手工環境的證據，是這筆債的來由。

- [ ] **Step 7: 把三筆側面發現登記成債務**

設計文件 §11 記了三件查證時挖到、不在本次範圍的事。**沒有編號的東西每一輪都會被合理地
跳過**（D33 自己就是這樣被漏掉的），所以要落成條目。在 `docs/specs/2026-07-29-project-review.md`
的債務表末尾新增三列：

| 編號 | 內容 | 影響 | 修法 | 成本 | 優先序 |
|---|---|---|---|---|---|
| **D37** | **`tools/probe/tests/` 的 13 個測試檔從未被跑過**。全部用 pytest，而本機沒裝 pytest（`python3 -m pytest` → `No module named pytest`）、沒有 requirements、沒有入口、不在 `ci.sh` 裡 | 與 D3（假 skip）同一族：**存在但不執行的測試比沒有測試更糟**，因為它讓人以為有涵蓋。13 個檔案涵蓋 coords／gesture／targets／framebuffer 等 probe 的核心邏輯，全都沒有保護 | 改寫成 unittest 併入 `ci.sh` 閘門 6，或加 requirements 並讓閘門裝 pytest。前者與 D33 的選擇一致（零依賴） | 半天 | P2 |
| **D38** | `mirage-poc.avd/config.ini` 帶字面上未取代的範本佔位符（`avd.id = <build>`、`avd.name = <build>`、`disk.dataPartition.path = <temp>`） | 它照樣能跑，所以不是功能問題；但它是**手工環境的具體證據**，也說明當初的建立程序沒有任何檢查 | `tools/provision/provision.py --apply` 會修正 | 1 分鐘 | P3 |
| **D39** | **MMAP transport 的重驗前提可能已經成立**。當初記載「等含上游修正的 build 發布」時，manifest 上 aarch64 只有 37.2.1(canary)／37.1.10(beta)／36.6.11(stable)；**現在 stable 是 37.1.11，build 15917651 比我們在跑的 canary 37.2.1（15875889）還新** | 「阻礙已消失但沒人回頭驗」那一類。MMAP 目前預設關閉，而 `FallbackTransport` 只認全零、認不出凍結幀（黑色像素是 `00 00 00 FF`），所以它不能靠自動降級兜住 | 升到 stable 37.1.11 後跑 `app/scripts/verify_mmap.sh`；拿到 ≥3 個非零且互異的幀才考慮改預設。**先確認它要解的問題還存在**——2026-07-28 實測顯示頻寬不是 fps 的瓶頸 | 1 小時 | P3 |

- [ ] **Step 8: 跑完整 CI 並 commit**

```bash
cd /Users/hanfourhuang/Projects/mirage/app && ./scripts/ci.sh; echo "CI_EXIT=$?"
cd /Users/hanfourhuang/Projects/mirage
git add tools/provision/README.md docs/specs/2026-07-29-project-review.md
git commit -m "docs: D33 (a) 完成——provisioning 腳本可重建 SDK 與兩台 AVD

端到端驗過：platform-tools（16MB，四個 package 裡最小）真下載 → 驗 sha1 →
解壓 → adb 可執行；兩台 AVD 產生後再跑一次全部「符合」（冪等）；在真環境上
不帶旗標時 exit=1 且一行都沒改（唯讀）。

天花板沒有變：Play Store 登入不可自動化，自動化只到「兩台一致的 AVD 可被
重建」。§6 的前提欄照這條邊界更新。"
```

---

## 執行順序與依賴

Task 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9，嚴格循序。Task 2 依賴 Task 1 的
`PackageRef`／`find_ref`；Task 6 依賴 Task 1 的 `parse_local_revision`；Task 7 依賴全部；
Task 8 依賴有測試可跑；Task 9 依賴 CLI 能動。

## 每個 task 完成後的共同檢查

- `cd tools/provision && python3 -m unittest discover -s tests -t . -v` 全綠
- 新增的每一條測試都要能說出「production code 改成什麼樣它會紅」——說不出來就是廢測試，
  刪掉重寫
- `lib/` 底下沒有 `open(`、`urllib`、`os.environ`
- 註解寫為什麼不寫做什麼
