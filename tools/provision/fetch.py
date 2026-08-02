"""**唯一碰網路與磁碟的模組。**

`lib/` 底下全是純函式，副作用集中在這裡——這條邊界就是「不下載 GB 也能測」
的機制（設計文件 §6）。這個檔案本身的測試用 tempfile 與 zipfile 當場造檔案，
一樣不需要網路；唯一沒有自動測試的是 `fetch_text`。

**原則：任何中止都不可以留下「看起來裝好了但其實壞掉」的狀態。**
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import tempfile
import urllib.error
import urllib.request
import zipfile

from lib.manifest import ManifestError, parse_local_revision


class FetchError(Exception):
    """網路、checksum 或解壓失敗。"""


PROVENANCE_FILE = ".mirage-provision.json"


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

    **倍率是 3.2，不是「留 20% 餘裕」那個直覺數字**——那個數字量錯了：它假設
    解壓後的內容跟 zip 差不多大，但四個真 zip 的實測解壓膨脹率遠不只如此
    （2026-08-02，讀 zip central directory 的 uncompressed size 加總，
    `needed` 是 manifest 給的壓縮後 size）：

        platform-tools    2.41×
        emulator          3.12×
        default sysimg    2.30×
        playstore sysimg  1.29×

    失效情境（倍率 1.2 時）：剩 2 GB 跑 emulator。檢查要求 needed*1.2 ≈
    473 MB → 通過 → 下載 394 MB → 解壓需要 1.23 GB（3.12×）→ ENOSPC，
    而 §9 承諾的「下載前先估算」在它唯一該生效的情境下沒有生效。3.2 蓋過
    四個實測值裡最大的 3.12×，留一點餘裕但不到需要重新量測才能用的地步。
    """
    usage = shutil.disk_usage(path)
    required = int(needed * 3.2)
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


def _extract_preserving_modes(archive: zipfile.ZipFile, dest: str) -> None:
    """`zipfile.extractall()` 不還原 Unix 權限——`external_attr` 裡的 mode 被丟掉。

    真實後果（2026-08-02 實測 `platform-tools_r37.0.1-darwin.zip`）：zip 裡 11
    個項目標著 `0o755`，`extractall()` 解出來全變成 `-rw-r--r--`，`adb` 直接
    `PermissionError`——這是這支工具第一次真下載就踩到的 bug，78 條 mocked
    測試全綠時完全沒被抓到。

    **單元測試原本抓不到這個**：舊測試用 `zipfile.writestr()` 造 zip，那樣寫
    出來的項目 `external_attr` 是 0——測試的 zip 根本沒有權限位可以丟，所以
    「有沒有還原權限」這件事在合成 zip 上測不出差異。只有真下載才會現形，
    這條註解與 `tests/test_fetch.py` 的 `ExtractModeTests` 就是那次的紀錄。
    """
    for info in archive.infolist():
        mode = info.external_attr >> 16
        if stat.S_ISLNK(mode):
            # platform-tools 的真 zip 沒有符號連結，但別的 package 可能有。
            # 與其猜著寫一條沒被驗證過的還原邏輯，不如當場說清楚——裝歪的
            # SDK 只會在啟動模擬器時以看不懂的訊息現形。
            raise FetchError(f"{info.filename} 是符號連結，目前不支援")
        target = archive.extract(info, dest)
        if mode & 0o777:
            os.chmod(target, mode & 0o777)


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
            _extract_preserving_modes(archive, staging)
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


def record_installed(sdk_root: str, install_path: str, revision: str) -> None:
    """記下我們自己裝了什麼版本，寫進 `sdk_root` 底下的 `PROVENANCE_FILE`。

    **為什麼需要這個檔案**：Google 的原始 repository zip 不含 `package.xml`
    ——那是 `sdkmanager`／Android Studio 在「管理式安裝」時額外合成的本地
    metadata，不是 zip 的內容物（2026-08-02 用真下載的 `platform-tools`
    zip 實測確認：14 個項目裡沒有 `package.xml`）。本工具刻意不依賴 JDK，
    不會呼叫 `sdkmanager`，所以少了這份紀錄，`installed_revision` 對我們
    自己裝的任何 package 永遠回 `""`（無從追溯）——第二次跑就會把剛裝好的
    東西報成漂移，建議的 `--upgrade` 一旦照做就會每次重新下載 GB 級檔案，
    直接違反設計文件 §8 的冪等驗收條件。

    **用新字典整份重寫，不原地改**：`_read_provenance` 回傳的是獨立的一份，
    這裡疊上新的一筆再整份 `json.dump`，不對它做原地賦值——寫檔本身就該是
    「舊狀態 + 這次的變更 → 新狀態」，而不是修飾一個可能被別處持有的物件。
    """
    records = {**_read_provenance(sdk_root), install_path: revision}
    path = os.path.join(sdk_root, PROVENANCE_FILE)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(records, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _read_provenance(sdk_root: str) -> dict[str, str]:
    """讀不到或壞掉一律當成空的。

    這份檔案只是加速用的紀錄，不是真相來源——壞掉的後果應該是「回頭報告
    漂移」，而不是讓整支工具崩潰。壞掉的來源可能是手動編輯、磁碟寫到一半，
    或單純是舊版格式。
    """
    path = os.path.join(sdk_root, PROVENANCE_FILE)
    try:
        with open(path, encoding="utf-8") as handle:
            records = json.load(handle)
    except (OSError, ValueError):
        return {}
    return records if isinstance(records, dict) else {}


def installed_revision(sdk_root: str, install_path: str) -> str | None:
    """`None` ＝ 沒裝；`""` ＝ 裝了但版本讀不出來。

    這兩者必須分得開：現裝的 google_apis_playstore 映像就是後者——目錄在、
    但沒有 `package.xml`，版本無從追溯。那正是 D33 記載的手工環境問題本體。

    **優先序**：`package.xml` 存在就用它——那是 `sdkmanager`／Android Studio
    寫的，代表這份是別人（或使用者事後用官方工具）裝的，比我們自己的紀錄
    更該相信。沒有的話才查 `PROVENANCE_FILE`：那是 `record_installed` 留下的，
    只涵蓋「本工具自己裝的東西」。兩者都沒有才回空字串。
    """
    target = os.path.join(sdk_root, install_path)
    if not os.path.isdir(target):
        return None
    package_xml = os.path.join(target, "package.xml")
    if os.path.isfile(package_xml):
        try:
            with open(package_xml, encoding="utf-8") as handle:
                return parse_local_revision(handle.read())
        except (OSError, ManifestError):
            return ""
    return _read_provenance(sdk_root).get(install_path, "")
