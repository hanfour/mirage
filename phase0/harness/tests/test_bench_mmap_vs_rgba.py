import importlib
import sys
import types

import grpc
import pytest


class FakeImageTransport:
    MMAP = 1


class FakeImageFormat:
    RGBA8888 = 1


def load_bench(monkeypatch):
    pb = types.ModuleType("emulator_controller_pb2")
    pb.ImageFormat = FakeImageFormat
    pb.ImageTransport = FakeImageTransport
    pbg = types.ModuleType("emulator_controller_pb2_grpc")
    pbg.EmulatorControllerStub = object
    monkeypatch.setitem(sys.modules, "emulator_controller_pb2", pb)
    monkeypatch.setitem(sys.modules, "emulator_controller_pb2_grpc", pbg)
    sys.path.insert(0, "phase0/harness")
    module = importlib.import_module("bench_mmap_vs_rgba")
    return importlib.reload(module)


def test_endpoint_to_port(monkeypatch):
    bench = load_bench(monkeypatch)
    assert bench.endpoint_to_port("localhost:8554") == 8554
    assert bench.endpoint_to_port("dns:///localhost:8556") == 8556
    with pytest.raises(ValueError):
        bench.endpoint_to_port("localhost")


def test_connection_failure_exits_before_table_or_fps(monkeypatch, capsys):
    bench = load_bench(monkeypatch)

    class DeadFuture:
        def result(self, timeout):
            raise grpc.FutureTimeoutError()

    class Channel:
        def close(self):
            pass

    monkeypatch.setattr(bench.grpc, "insecure_channel", lambda *args, **kwargs: Channel())
    monkeypatch.setattr(bench.grpc, "channel_ready_future", lambda channel: DeadFuture())
    monkeypatch.setattr(
        sys,
        "argv",
        ["bench_mmap_vs_rgba.py", "--endpoint", "localhost:45999", "--no-animate"],
    )

    assert bench.main() == 1
    output = capsys.readouterr()
    assert "❌" in output.err
    assert "45999" in output.err
    assert "fps" not in output.out.lower()
    assert "fps" not in output.err.lower()
