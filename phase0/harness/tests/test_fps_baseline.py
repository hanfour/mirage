import importlib
import json
import sys
import types

import numpy as np
import pytest


class FakeImageTransport:
    MMAP = 1

    def __init__(self, channel=0, handle=""):
        self.channel = channel
        self.handle = handle


class FakeImageFormat:
    RGBA8888 = 1

    def __init__(self, format=0, width=0, height=0, transport=None):
        self.format = format
        self.width = width
        self.height = height
        self.transport = transport


class FakeFrame:
    def __init__(self, image=b""):
        self.image = image


class FakeChannel:
    def close(self):
        pass


def load_baseline(monkeypatch):
    pb = types.ModuleType("emulator_controller_pb2")
    pb.ImageFormat = FakeImageFormat
    pb.ImageTransport = FakeImageTransport
    pbg = types.ModuleType("emulator_controller_pb2_grpc")
    pbg.EmulatorControllerStub = object
    monkeypatch.setitem(sys.modules, "emulator_controller_pb2", pb)
    monkeypatch.setitem(sys.modules, "emulator_controller_pb2_grpc", pbg)
    sys.path.insert(0, "phase0/harness")
    module = importlib.import_module("fps_baseline")
    return importlib.reload(module)


class Stub:
    def __init__(self, frames):
        self.frames = frames
        self.request = None

    def streamScreenshot(self, request, timeout):
        self.request = request
        yield from self.frames


def measure_with_stub(baseline, stub, transport="rgba", frame_array_fn=None):
    return baseline.measure(
        "localhost:8556",
        seconds=1,
        width=4,
        height=2,
        transport=transport,
        stub=stub,
        channel_factory=lambda endpoint, **kwargs: FakeChannel(),
        buffer_factory=lambda path, width, height: object(),
        frame_array_fn=frame_array_fn,
    )


def test_rgba_and_mmap_build_correct_image_formats(monkeypatch, tmp_path):
    baseline = load_baseline(monkeypatch)

    rgba_stub = Stub([FakeFrame(b"a" * 32), FakeFrame(b"b" * 32)])
    rgba = measure_with_stub(baseline, rgba_stub)
    assert rgba_stub.request.format == FakeImageFormat.RGBA8888
    assert rgba_stub.request.width == 4
    assert rgba_stub.request.height == 2
    assert rgba_stub.request.transport is None

    mmap_stub = Stub([FakeFrame(), FakeFrame()])
    contents = iter([np.full((2, 4, 4), 1, dtype=np.uint8),
                     np.full((2, 4, 4), 2, dtype=np.uint8)])
    mmap_result = baseline.measure(
        "localhost:8556",
        seconds=1,
        width=4,
        height=2,
        transport="mmap",
        stub=mmap_stub,
        channel_factory=lambda endpoint, **kwargs: FakeChannel(),
        buffer_factory=lambda path, width, height: object(),
        frame_array_fn=lambda buf, width, height: next(contents),
        temp_path_factory=lambda: str(tmp_path / "mmap-frame.bin"),
    )
    assert mmap_stub.request.format == FakeImageFormat.RGBA8888
    assert mmap_stub.request.width == 4
    assert mmap_stub.request.height == 2
    assert mmap_stub.request.transport.channel == FakeImageTransport.MMAP
    assert mmap_stub.request.transport.handle == f"file://{tmp_path / 'mmap-frame.bin'}"
    assert mmap_result["transport"] == "mmap"


@pytest.mark.parametrize(
    ("frames", "distinct", "error", "status", "code"),
    [
        (2, 2, None, "measured", 0),
        (0, 0, None, "static", 2),
        (2, 1, None, "stale", 3),
        (0, 0, "Unavailable", "error", 1),
    ],
)
def test_status_and_exit_code_mapping(monkeypatch, frames, distinct, error, status, code):
    baseline = load_baseline(monkeypatch)
    assert baseline.status_for(frames, distinct, error) == status
    assert baseline.exit_code(status) == code


def test_rgba_and_mmap_distinct_fingerprints_are_consistent(monkeypatch):
    baseline = load_baseline(monkeypatch)
    first = np.arange(32, dtype=np.uint8).reshape(2, 4, 4)
    second = np.full((2, 4, 4), 255, dtype=np.uint8)

    rgba_stub = Stub([FakeFrame(first.tobytes()), FakeFrame(second.tobytes())])
    rgba = measure_with_stub(baseline, rgba_stub)
    mmap_stub = Stub([FakeFrame(), FakeFrame()])
    mmap_contents = iter([first, second])
    mmap = measure_with_stub(
        baseline,
        mmap_stub,
        transport="mmap",
        frame_array_fn=lambda buf, width, height: next(mmap_contents),
    )
    assert rgba["distinct"] == 2
    assert mmap["distinct"] == rgba["distinct"]


def test_stale_is_reported_when_notifications_repeat_same_content(monkeypatch):
    baseline = load_baseline(monkeypatch)
    stub = Stub([FakeFrame(b"same" * 8), FakeFrame(b"same" * 8)])
    result = measure_with_stub(baseline, stub)
    assert result["frames"] == 2
    assert result["distinct"] == 1
    assert result["status"] == "stale"
    assert baseline.exit_code(result["status"]) == 3


def test_default_transport_keeps_old_json_fields_and_adds_new_fields(monkeypatch, capsys):
    baseline = load_baseline(monkeypatch)
    old_fields = {
        "status", "error", "fps", "frames", "elapsed", "width", "height"
    }
    result = {
        "status": "measured",
        "error": None,
        "fps": 60.0,
        "frames": 2,
        "elapsed": 1.0,
        "width": 4,
        "height": 2,
        "transport": "rgba",
        "distinct": 2,
    }
    calls = {}

    def fake_measure(endpoint, seconds, width, height, transport):
        calls["transport"] = transport
        return result

    monkeypatch.setattr(baseline, "measure", fake_measure)
    monkeypatch.setattr(sys, "argv", ["fps_baseline.py", "--json"])
    assert baseline.main() == 0
    output = json.loads(capsys.readouterr().out)
    assert old_fields <= output.keys()
    assert {"transport", "distinct"} <= output.keys()
    assert calls["transport"] == "rgba"


def test_mmap_temp_path_is_absolute_and_removed(monkeypatch, tmp_path):
    baseline = load_baseline(monkeypatch)
    path = tmp_path / "frame.bin"
    path.write_bytes(b"placeholder")
    stub = Stub([FakeFrame()])
    result = baseline.measure(
        "localhost:8556",
        seconds=1,
        width=4,
        height=2,
        transport="mmap",
        stub=stub,
        channel_factory=lambda endpoint, **kwargs: FakeChannel(),
        buffer_factory=lambda path, width, height: object(),
        frame_array_fn=lambda buf, width, height: np.ones((2, 4, 4), dtype=np.uint8),
        temp_path_factory=lambda: str(path),
    )
    assert result["transport"] == "mmap"
    assert not path.exists()
