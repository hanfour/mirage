"""gRPC 連通煙霧測試：連上 emulator、印出狀態。"""
import sys

sys.path.insert(0, "gen")

import grpc
from google.protobuf import empty_pb2
import emulator_controller_pb2_grpc as ecg

TARGET = "localhost:8554"


def main() -> int:
    channel = grpc.insecure_channel(TARGET)
    stub = ecg.EmulatorControllerStub(channel)
    try:
        status = stub.getStatus(empty_pb2.Empty(), timeout=5)
    except grpc.RpcError as err:
        print(f"FAIL: gRPC {err.code().name}: {err.details()}", file=sys.stderr)
        return 1
    print(status)
    print("OK: gRPC reachable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
