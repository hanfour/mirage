"""MMAP 通道可用性探測——本計畫的 go/no-go 閘門。

回答四個問題：
  1. streamScreenshot 帶 MMAP transport 會不會直接報錯？
  2. Image 訊息的 image payload 是否為空（資料走 mmap 而非 gRPC）？
  3. mmap 檔案內容是否隨畫面變化（動畫下連續三幀 hash 應不同）？
  4. 訊息裡 format.width/height 是否照常回報？
前置：emulator 執行中；另終端跑 `python animate.py --seconds 30` 供應動畫。
"""
import hashlib
import sys
import tempfile
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.mmap_source import frame_array, make_handle, open_frame_buffer

TARGET = "localhost:8554"
GUEST_W, GUEST_H = 1080, 2400
N_PROBE_FRAMES = 5


def main() -> int:
    path = tempfile.mktemp(prefix="mirage_mmap_", suffix=".bin")
    buf = open_frame_buffer(path, GUEST_W, GUEST_H)
    channel = grpc.insecure_channel(
        TARGET, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)
    fmt = ec.ImageFormat(
        format=ec.ImageFormat.RGBA8888,
        transport=ec.ImageTransport(
            channel=ec.ImageTransport.MMAP, handle=make_handle(path)),
    )
    print(f"handle={make_handle(path)}")
    hashes = []
    try:
        for i, frame in enumerate(stub.streamScreenshot(fmt)):
            arr = frame_array(buf, GUEST_W, GUEST_H)
            digest = hashlib.md5(arr.tobytes()).hexdigest()[:12]
            hashes.append(digest)
            print(f"frame {i}: payload_bytes={len(frame.image)} "
                  f"reported={frame.format.width}x{frame.format.height} "
                  f"mmap_md5={digest} mmap_nonzero={bool(arr.any())}")
            if i + 1 >= N_PROBE_FRAMES:
                break
    except grpc.RpcError as err:
        print(f"PROBE FAIL: gRPC {err.code().name}: {err.details()}",
              file=sys.stderr)
        return 1
    finally:
        buf.close()

    distinct = len(set(hashes))
    verdict = "MMAP_OK" if distinct >= 2 else "MMAP_SUSPECT(內容未變化)"
    print(f"distinct_hashes={distinct}/{len(hashes)} -> {verdict}")
    return 0 if distinct >= 2 else 2


if __name__ == "__main__":
    sys.exit(main())
