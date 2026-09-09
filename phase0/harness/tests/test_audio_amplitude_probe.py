"""`audio_amplitude_probe.tail_verdict` 的判定邏輯。

會有這支測試是因為「封包中途停止」這個判定曾經被直接當成缺陷記進債務表（D70），
而它其實分不出「RPC 停止交付」與「guest 不放音訊了」。判定本身沒錯，錯在沒有把
那個歧義講出來，所以這裡除了鎖住門檻，也鎖住警告一定要跟著出現。
"""
import importlib.util
import pathlib
import sys

import pytest

HARNESS = pathlib.Path(__file__).resolve().parents[1]


def _load_probe():
    # 探針會 import 產生碼，而那需要 gen/ 在 sys.path 上；測試只用純函式，
    # 但 import 階段仍會執行那幾行，所以照它自己的方式先鋪好路徑。
    sys.path.insert(0, str(HARNESS / "gen"))
    spec = importlib.util.spec_from_file_location(
        "audio_amplitude_probe", HARNESS / "audio_amplitude_probe.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe = _load_probe()


def test_delivery_to_the_end_has_no_caution():
    gap, verdict, caution = probe.tail_verdict(elapsed=60.0, last_packet_offset=60.0)
    assert gap == pytest.approx(0.0)
    assert verdict == "交付持續到結束"
    assert caution == ""


def test_threshold_is_exclusive():
    _, verdict, caution = probe.tail_verdict(elapsed=60.0, last_packet_offset=58.0)
    assert verdict == "交付持續到結束"
    assert caution == ""


def test_just_past_threshold_stops():
    gap, verdict, caution = probe.tail_verdict(elapsed=60.0, last_packet_offset=57.9)
    assert gap == pytest.approx(2.1)
    assert verdict == "封包中途停止"
    assert caution


def test_stop_always_carries_the_conflation_caution():
    """這一條是這支測試存在的理由：判定為停止就一定要附上歧義警告。"""
    for offset in (0.0, 10.0, 23.0, 57.0):
        _, verdict, caution = probe.tail_verdict(elapsed=60.0, last_packet_offset=offset)
        assert verdict == "封包中途停止"
        assert "guest 停止輸出音訊" in caution


def test_no_packets_at_all_is_a_stop():
    gap, verdict, caution = probe.tail_verdict(elapsed=30.0, last_packet_offset=0.0)
    assert gap == pytest.approx(30.0)
    assert verdict == "封包中途停止"
    assert caution


def test_threshold_is_configurable():
    _, verdict, _ = probe.tail_verdict(elapsed=60.0, last_packet_offset=55.0, threshold=10.0)
    assert verdict == "交付持續到結束"
    _, verdict, _ = probe.tail_verdict(elapsed=60.0, last_packet_offset=55.0, threshold=1.0)
    assert verdict == "封包中途停止"
