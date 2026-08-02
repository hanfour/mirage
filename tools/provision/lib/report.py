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
