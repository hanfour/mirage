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
