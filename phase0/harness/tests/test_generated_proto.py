from pathlib import Path

import emulator_controller_pb2 as pb
import emulator_controller_pb2_grpc as pbg


def test_generated_proto_is_loaded_from_gen():
    gen_dir = Path(__file__).resolve().parents[1] / "gen"
    module_file = getattr(pb, "__file__", None)

    assert module_file is not None
    assert Path(module_file).resolve().parent == gen_dir.resolve()
    assert hasattr(pb, "ImageFormat")
    assert hasattr(pb, "ImageTransport")
    assert hasattr(pbg, "EmulatorControllerStub")
