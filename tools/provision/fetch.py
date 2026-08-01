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
