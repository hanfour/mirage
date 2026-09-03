import json
import os
import sys
from types import SimpleNamespace

import numpy as np
import pytest

import bench_mmap_vs_rgba as bench
import fps_baseline as baseline


class FakeImageTransport:
    MMAP = 7

    def __init__(self, channel=0, handle=""):
        self.channel = channel
        self.handle = handle


class FakeImageFormat:
    RGBA8888 = 3

    def __init__(self, **kwargs):
        self.format = kwargs.get("format")
        self.width = kwargs.get("width")
        self.height = kwargs.get("height")
        self.transport = kwargs.get("transport")


FAKE_PB = SimpleNamespace(
    ImageFormat=FakeImageFormat,
    ImageTransport=FakeImageTransport,
)


class FakeFrame:
    def __init__(self, image=b""):
        self.image = image


class FakeStub:
    def __init__(self, frames):
        self.frames = frames
        self.request = None

    def streamScreenshot(self, request, timeout=None):
        self.request = request
        return iter(self.frames)


class FakeBuffer:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


class FakeChannel:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


def _payloads():
    first = bytearray(12000)
    second = bytearray(first)
    second[4099] = 1
    return [bytes(first), bytes(second)]


def test_image_format_contains_expected_transport_fields():
    rgba = baseline.make_image_format(
        "rgba", 900, 2000, pb_module=FAKE_PB)
    assert rgba.format == FAKE_PB.ImageFormat.RGBA8888
    assert rgba.width == 900
    assert rgba.height == 2000
    assert rgba.transport is None

    mmap_format = baseline.make_image_format(
        "mmap", 900, 2000, handle="file:///tmp/d58.bin", pb_module=FAKE_PB)
    assert mmap_format.format == FAKE_PB.ImageFormat.RGBA8888
    assert mmap_format.transport.channel == FAKE_PB.ImageTransport.MMAP
    assert mmap_format.transport.handle == "file:///tmp/d58.bin"


@pytest.mark.parametrize(
    ("frames", "distinct", "error", "status", "exit_code"),
    [
        (0, 0, None, "static", 2),
        (3, 2, None, "measured", 0),
        (3, 1, None, "stale", 3),
        (0, 0, "UNAVAILABLE", "error", 1),
    ],
)
def test_status_and_exit_code_mapping(frames, distinct, error, status, exit_code):
    assert baseline.status_for(frames, distinct, error) == status
    assert baseline._EXIT_BY_STATUS[status] == exit_code


def test_sampled_distinct_is_consistent_for_rgba_and_mmap_sources():
    payloads = _payloads()
    rgba_distinct = baseline.count_distinct(payloads)
    mmap_distinct = baseline.count_distinct(
        [np.frombuffer(payload, dtype=np.uint8).reshape(1, 3000, 4)
         for payload in payloads]
    )
    assert rgba_distinct == mmap_distinct == 2


@pytest.mark.parametrize("transport", ["rgba", "mmap"])
def test_measure_supports_injected_stub_and_buffer_source(tmp_path, transport):
    payloads = _payloads()
    stub = FakeStub(
        [FakeFrame(payload) if transport == "rgba" else FakeFrame()
         for payload in payloads]
    )
    buffer = FakeBuffer()
    paths = []
    sources = iter(payloads)

    def buffer_factory(path, width, height):
        paths.append(path)
        return buffer

    def frame_source_factory(_buffer, _width, _height):
        return next(sources)

    result = baseline.measure(
        "localhost:8556",
        1,
        900,
        2000,
        transport=transport,
        stub=stub,
        pb_module=FAKE_PB,
        buffer_factory=buffer_factory,
        frame_source_factory=frame_source_factory,
    )

    assert result["transport"] == transport
    assert result["distinct"] == 2
    assert result["status"] == "measured"
    assert stub.request.format == FAKE_PB.ImageFormat.RGBA8888
    assert stub.request.width == 900
    assert stub.request.height == 2000
    if transport == "mmap":
        assert stub.request.transport.channel == FAKE_PB.ImageTransport.MMAP
        assert stub.request.transport.handle.startswith("file://")
        assert paths and os.path.isabs(paths[0])
        assert not os.path.exists(paths[0])
        assert buffer.closed
    else:
        assert stub.request.transport is None


def test_mmap_setup_failure_cleans_buffer_path_and_channel(monkeypatch, tmp_path):
    path = tmp_path / "partial-frame.bin"
    channel = FakeChannel()
    stub_factory = SimpleNamespace(
        EmulatorControllerStub=lambda _channel: object())
    monkeypatch.setattr(
        baseline, "_require_proto", lambda: (FAKE_PB, stub_factory))

    def failing_buffer_factory(buffer_path, _width, _height):
        path.write_bytes(b"partial")
        raise OSError("disk full")

    with pytest.raises(OSError, match="disk full"):
        baseline.measure(
            "localhost:8556",
            1,
            900,
            2000,
            transport="mmap",
            channel_factory=lambda _endpoint, **_kwargs: channel,
            buffer_factory=failing_buffer_factory,
            temp_path_factory=lambda: str(path),
            pb_module=FAKE_PB,
        )

    assert not path.exists()
    assert channel.closed


def test_endpoint_port_derivation():
    assert bench.port_from_endpoint("localhost:8556") == 8556
    assert bench.port_from_endpoint("127.0.0.1:45999") == 45999
    assert bench.port_from_endpoint("[::1]:8554") == 8554
    with pytest.raises(ValueError):
        bench.port_from_endpoint("localhost")


def test_bench_connection_failure_exits_before_fps_output(monkeypatch, capsys):
    monkeypatch.setattr(bench, "probe_endpoint", lambda endpoint: (False, "timeout"))
    monkeypatch.setattr(
        sys,
        "argv",
        ["bench_mmap_vs_rgba.py", "--endpoint", "localhost:45999", "--no-animate"],
    )

    assert bench.main() == 1
    captured = capsys.readouterr()
    assert "fps" not in captured.out.lower()
    assert "fps" not in captured.err.lower()


def test_default_transport_json_keeps_existing_fields(monkeypatch, capsys):
    old_fields = {
        "status", "error", "fps", "frames", "elapsed", "width", "height"
    }

    def fake_measure(endpoint, seconds, width, height, transport):
        return {
            "status": "measured",
            "error": None,
            "fps": 60.0,
            "frames": 3,
            "elapsed": 0.05,
            "width": width,
            "height": height,
            "transport": transport,
            "distinct": 3,
        }

    monkeypatch.setattr(baseline, "measure", fake_measure)
    monkeypatch.setattr(sys, "argv", ["fps_baseline.py", "--json"])

    assert baseline.main() == 0
    result = json.loads(capsys.readouterr().out)
    assert old_fields <= result.keys()
    assert result["transport"] == "rgba"
    assert result["distinct"] == 3
