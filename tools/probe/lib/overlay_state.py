"""pointer_location 疊層的原值狀態檔。

疊層是為了量測而開的，不還原會一直留在使用者的裝置上——2026-07-28 那輪開了
兩台機器的疊層，全靠自己記得關。`on` 存原值、`restore` 讀回來。
"""
import os

STATE_DIR = os.path.expanduser("~/.mirage-probe")


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
