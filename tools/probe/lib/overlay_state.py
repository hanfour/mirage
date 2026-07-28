"""pointer_location 疊層的原值狀態檔。

疊層是為了量測而開的，不還原會一直留在使用者的裝置上——2026-07-28 那輪開了
兩台機器的疊層，全靠自己記得關。`on` 存原值、`restore` 讀回來。
"""
import os

STATE_DIR = os.path.expanduser("~/.mirage-probe")

ON = "1"
OFF = "0"
_UNSET = ("", "null")   # `settings get` 沒設定過時回字面上的 "null"


def should_record(current: str) -> bool:
    """讀到的原值是否值得寫進狀態檔。

    **疊層已經開著（`"1"`）時不要記錄。** 「它已經開著」這件事本身沒有記錄的
    意義，記下去反而會蓋掉上一次 `on` 存的**真正**原值，之後 `restore` 就把
    疊層設回 1——設計文件 §4.4 要防的事情原封不動地回來。而且不是假想：
    `overlay on` 連按兩次就會踩中，2026-07-28 review 當下 `emulator-5554` 的
    `pointer_location` 就正是遺留的 `1`。
    """
    return current.strip() != ON


def restore_value(original: str) -> str:
    """狀態檔裡的原值 → `restore` 要寫回 settings 的值。

    沒設定過（空字串或字面上的 "null"）對應到關閉；`settings put null` 只會
    寫進一個字面上的字串 "null"，不是清除設定。
    """
    value = original.strip()
    return OFF if value in _UNSET else value


def state_path(target_name: str) -> str:
    return os.path.join(STATE_DIR, f"{target_name}-overlay")


def save_original(target_name: str, value: str) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(state_path(target_name), "w") as f:
        f.write(value.strip())


def load_original(target_name: str) -> str | None:
    try:
        with open(state_path(target_name)) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None
