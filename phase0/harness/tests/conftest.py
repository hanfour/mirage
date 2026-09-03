import sys
from pathlib import Path


HARNESS_DIR = str(Path(__file__).resolve().parents[1])
if HARNESS_DIR not in sys.path:
    sys.path.insert(0, HARNESS_DIR)


try:
    import emulator_controller_pb2  # noqa: F401
    import emulator_controller_pb2_grpc  # noqa: F401
except Exception:
    import types

    class ImageTransport:
        MMAP = 1

        def __init__(self, channel=0, handle=""):
            self.channel = channel
            self.handle = handle

    class ImageFormat:
        RGBA8888 = 1

        def __init__(self, **kwargs):
            self.format = kwargs.get("format")
            self.width = kwargs.get("width")
            self.height = kwargs.get("height")
            self.transport = kwargs.get("transport")

    pb = types.ModuleType("emulator_controller_pb2")
    pb.ImageFormat = ImageFormat
    pb.ImageTransport = ImageTransport
    pbg = types.ModuleType("emulator_controller_pb2_grpc")
    pbg.EmulatorControllerStub = object
    sys.modules["emulator_controller_pb2"] = pb
    sys.modules["emulator_controller_pb2_grpc"] = pbg
