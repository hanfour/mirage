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


def _parse_xml(xml_text: str):
    """把 ElementTree 的 ParseError 包成 ManifestError。

    這個模組的契約是「形狀不對就拋 ManifestError」。讓 ParseError 漏出去的話，
    每個呼叫端都得知道我們內部用了 ElementTree——而且真的會漏：截斷寫入的
    package.xml 會讓 fetch.installed_revision 直接崩潰，而它的契約說那種情況
    應該回傳空字串（「裝了但版本讀不出來」）。
    """
    try:
        return ElementTree.fromstring(xml_text)
    except ElementTree.ParseError as error:
        raise ManifestError(f"XML 格式錯誤：{error}") from error


def _revision(node) -> str:
    """`<revision><major>37</major><minor>1</minor><micro>11</micro></revision>` → `"37.1.11"`

    **缺的部分不補零。** sys-img 的 revision 只有 `<major>`，它就是 `"2"`
    而不是 `"2.0.0"`——pin 表裡記的是前者，補零會讓每次比對都判成漂移。
    """
    if node is None:
        raise ManifestError("revision 缺少 major")
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
    root = _parse_xml(xml_text)
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
    root = _parse_xml(xml_text)
    for node in root.iter():
        if node.tag == "localPackage":
            revision_node = node.find("revision")
            return _revision(revision_node)
    raise ManifestError("找不到 <localPackage>")
