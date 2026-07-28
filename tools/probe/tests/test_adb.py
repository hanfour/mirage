"""lib.adb 的子行程錯誤包裝——用假的 subprocess.run 測，全程不碰真裝置。

**為什麼這條路徑重要**：`subprocess.TimeoutExpired` 不是 AdbError、不是
EmulatorError、也不是 ValueError，會直接穿過 `probe.main()` 的 except 子句變成
traceback。這支工具的輸出是給 Claude session 讀的——噴 traceback 等於把唯一的
溝通管道砸掉，session 只會看到一坨堆疊而不知道是哪台機器、哪條指令、卡了多久。

而且這不是罕見路徑：`foreground_activity` 的 `dumpsys`（逾時 25 秒）在
`launch` 的輪詢迴圈裡每秒被呼叫一次，正好是接下來 Phase-1 要一直用的那條。
"""
import subprocess

import pytest

from lib import adb


@pytest.fixture(autouse=True)
def fake_adb_path(monkeypatch):
    """繞過「找得到可執行的 adb」這個前提，測的是逾時包裝本身。"""
    monkeypatch.setattr(adb, "adb_path", lambda: "/fake/adb")


def _timeout_run(monkeypatch):
    """讓 subprocess.run 一律丟 TimeoutExpired，並記下它收到的參數。"""
    seen = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        seen["timeout"] = kwargs["timeout"]
        raise subprocess.TimeoutExpired(cmd, kwargs["timeout"])

    monkeypatch.setattr(adb.subprocess, "run", fake_run)
    return seen


def test_run_wraps_timeout_as_adb_error(monkeypatch):
    seen = _timeout_run(monkeypatch)
    with pytest.raises(adb.AdbError) as excinfo:
        adb.run("emulator-5558", ["shell", "true"], timeout=20)
    assert seen["timeout"] == 20
    message = str(excinfo.value)
    assert "20" in message          # 逾時秒數
    assert "shell true" in message  # 實際執行的指令
    assert "emulator-5558" in message


def test_foreground_activity_timeout_reports_its_own_25s(monkeypatch):
    """launch 迴圈裡每秒呼叫一次的就是這條，逾時秒數要是它自己的 25，
    不是 run() 的預設 20——否則訊息會指向錯的地方。"""
    _timeout_run(monkeypatch)
    with pytest.raises(adb.AdbError) as excinfo:
        adb.foreground_activity("emulator-5558")
    assert "25" in str(excinfo.value)
    assert "dumpsys" in str(excinfo.value)


def test_ensure_online_wraps_timeout(monkeypatch):
    """`get-state` 自己就可能卡住（adb server 掛掉時）。它是每條指令的第一步，
    逾時噴 traceback 的話使用者連「裝置有沒有在線」都得不到答案。"""
    _timeout_run(monkeypatch)
    with pytest.raises(adb.AdbError, match="逾時"):
        adb.ensure_online("emulator-5558")


def test_screencap_wraps_timeout(monkeypatch):
    """screencap 走 text=False 這條分支，逾時包裝不能只做在 text=True 那條。"""
    _timeout_run(monkeypatch)
    with pytest.raises(adb.AdbError, match="逾時"):
        adb.screencap_rgba("emulator-5558")


def test_os_error_is_wrapped_too(monkeypatch):
    """OSError（例如 adb 二進位在檢查之後才被換掉）同樣會穿過 main() 的
    except 變成 traceback。"""
    def boom(cmd, **kwargs):
        raise OSError(13, "Permission denied")

    monkeypatch.setattr(adb.subprocess, "run", boom)
    with pytest.raises(adb.AdbError, match="無法執行"):
        adb.run("emulator-5558", ["shell", "true"])


def test_wrapped_errors_are_catchable_by_the_cli(monkeypatch):
    """釘住真正在意的事：包出來的東西必須落在 probe.main() 接得住的類別裡。"""
    _timeout_run(monkeypatch)
    try:
        adb.run("emulator-5558", ["shell", "true"])
    except (adb.AdbError, ValueError):
        pass
    else:
        raise AssertionError("逾時必須被包成 main() 接得住的例外")
