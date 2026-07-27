"""單一變數診斷：mmap 之後「關閉 fd」vs「保留 fd」是否影響 emulator 的寫入。

背景：`MmapStreamTransport`（Swift）在真模擬器上只寫入一次就凍結，而同尺寸、同協定的
Python client 正常。逐行比對兩邊的緩衝區建立程式碼後，唯一的實質差異是：

    Python (lib/mmap_source.py:23)：mmap 之後立刻 os.close(fd)
    Swift  (MmapBuffer.swift)      ：把 fd 保留在實例裡直到 close()

本腳本把 Python 端改成「保留 fd」，其餘（尺寸、handle 格式、RPC、消費節奏）完全不變，
以單一變數確認這是不是根因。

用法（需 emulator 執行中，另需 animate.py 供應動畫）：
    python diag_fd_variable.py
"""
import hashlib
import mmap
import os
import sys
import tempfile

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg

TARGET = "localhost:8554"
W, H = 540, 1200
N = 5


def run(keep_fd: bool, use_o_trunc: bool) -> tuple[int, bool]:
    """回傳 (相異雜湊數, 是否曾非零)。"""
    path = tempfile.mktemp(prefix="mirage_diag_", suffix=".bin")
    size = W * H * 4
    flags = os.O_RDWR | os.O_CREAT | (os.O_TRUNC if use_o_trunc else 0)
    fd = os.open(path, flags, 0o600)
    os.ftruncate(fd, size)
    buf = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
    if not keep_fd:
        os.close(fd)

    channel = grpc.insecure_channel(
        TARGET, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)
    fmt = ec.ImageFormat(
        format=ec.ImageFormat.RGBA8888, width=W, height=H,
        transport=ec.ImageTransport(channel=ec.ImageTransport.MMAP,
                                    handle=f"file://{path}"))

    hashes, nonzero = [], False
    try:
        for i, _ in enumerate(stub.streamScreenshot(fmt)):
            data = buf[:]
            hashes.append(hashlib.md5(data).hexdigest()[:12])
            nonzero = nonzero or any(data[:4096])
            if i + 1 >= N:
                break
    except grpc.RpcError as err:
        print(f"  gRPC {err.code().name}: {err.details()}", file=sys.stderr)
    finally:
        buf.close()
        if keep_fd:
            os.close(fd)
        channel.close()
        if os.path.exists(path):
            os.unlink(path)
    return len(set(hashes)), nonzero


def main() -> int:
    cases = [
        ("關閉 fd（Python 原樣）", False, False),
        ("保留 fd（模仿 Swift）", True, False),
        ("關閉 fd + O_TRUNC", False, True),
        ("保留 fd + O_TRUNC（完全模仿 Swift）", True, True),
    ]
    print(f"{W}x{H}，各取 {N} 幀\n")
    results = []
    for label, keep, trunc in cases:
        distinct, nonzero = run(keep, trunc)
        results.append((label, distinct, nonzero))
        print(f"{label:38s} 相異雜湊={distinct}/{N}  曾非零={nonzero}")

    print("\n=== 判讀 ===")
    baseline = results[0][1]
    swift_like = results[3][1]
    if baseline >= 2 and swift_like < 2:
        print("→ 根因在檔案建立語意（保留 fd 或 O_TRUNC）——與 Swift/gRPC 無關")
    elif baseline >= 2 and swift_like >= 2:
        print("→ 檔案建立語意不是根因；差異在 Swift/grpc-swift 端")
    else:
        print("→ 基準組自己就不動，本次量測無效（動畫是否在跑？）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
