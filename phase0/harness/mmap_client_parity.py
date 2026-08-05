"""MMAP 的 client 對照：同一台 emulator 上，Python(grpcio) 拿不拿得到持續更新的幀。

**存在的理由**（D39，2026-08-05）：`MmapStreamTransport`（grpc-swift）在真模擬器上凍結，
而同條件的 Python client 正常。這個不對稱是整個 MMAP 缺陷的核心事實，但在 D39 之前它
只在 emulator 37.2.1.0 上量過一次、且是手工做的。沒有這支腳本，每次重驗都要重新手工
搭一次對照，而「有人手工驗過」正是 D33／D42 那批債的病本身。

**它回答的是一個 Swift 測試回答不了的問題**：Swift 那條紅燈只說「Swift 拿不到」，
分不出「emulator 的 MMAP 寫入端壞了」與「只有 grpc-swift 這條路壞了」。兩者的下一步
完全不同——前者要等上游，後者要查我們自己的 client。

條件刻意與 `MmapStreamLiveTests` 逐項對齊（尺寸、明確帶尺寸、handle 放 $TMPDIR、
先 getStatus 再 streamScreenshot、同一條 channel），唯一的變數是 client 實作。

用法（需 emulator 執行中，且 guest 畫面正在變動——streamScreenshot 是變化驅動）：
    cd phase0/harness
    ./.venv/bin/python animate.py --seconds 60 &      # 供應動畫
    ./.venv/bin/python mmap_client_parity.py [--width 540] [--height 1200]

**必須用 `.venv` 的 python，不能用系統的**：`gen/` 下的產生碼是 protobuf 7.x 產的，
系統 python 裝的是 4.x，一 import 就炸（D49）。平常是 `app/scripts/verify_mmap.sh`
呼叫本腳本，它已經處理好直譯器選擇。

退出碼：0 = Python 拿得到相異的幀（emulator 側正常）／2 = Python 也凍結／3 = RPC 失敗
"""
import argparse
import hashlib
import os
import sys
import tempfile
import time

sys.path.insert(0, "gen")

import grpc
from google.protobuf import empty_pb2
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.mmap_source import frame_array, make_handle, open_frame_buffer


def main() -> int:
    parser = argparse.ArgumentParser(description="MMAP client 對照（Python vs Swift）")
    parser.add_argument("--target", default="localhost:8554")
    # 預設對齊 MmapStreamLiveTests 的 540x1200——兩邊尺寸不同，對照就不成立。
    parser.add_argument("--width", type=int, default=540)
    parser.add_argument("--height", type=int, default=1200)
    # **30 幀不是隨便挑的**：通知以近 60Hz 到達，5 幀只跨約 83ms——若 guest 畫面的
    # 實際變化率低於 60Hz（animate.py 供應的動畫就是），那 83ms 內畫面本來就可能
    # 一模一樣，於是「全同」會被誤讀成凍結。D39 第一次跑就踩到這個偽陰性。
    # 30 幀跨約 500ms，與前人判定 Swift 凍結時用的窗口一致（30 幀／480ms）。
    parser.add_argument("--frames", type=int, default=30)
    # **沒有逾時的驗證腳本會無限掛住**：`streamScreenshot` 是變化驅動的，guest 畫面
    # 完全靜止時它一格都不送，`for` 迴圈就永遠等下去。D39 收尾時真的掛住一次
    # （animate.py 意外跑了兩個實例、emulator 剛冷開機），腳本停在那裡不動也不紅。
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    # tempfile 用 $TMPDIR，與 Swift 的 NSTemporaryDirectory() 落在同一個目錄——
    # 路徑長度與所在檔案系統都會影響 emulator 端開檔，不能一邊 /tmp 一邊 $TMPDIR。
    path = tempfile.mktemp(prefix="mirage_mmap_parity_", suffix=".bin")
    buf = open_frame_buffer(path, args.width, args.height)
    channel = grpc.insecure_channel(
        args.target, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)

    hashes: list[str] = []
    rpc_failed = False
    started = elapsed = 0.0
    try:
        # Swift 測試也先打 getStatus 過版本閘，順序一併對齊。
        status = stub.getStatus(empty_pb2.Empty(), timeout=5)
        print(f"emulator 版本：{status.version}")
        print(f"handle 路徑：{path}")

        fmt = ec.ImageFormat(
            format=ec.ImageFormat.RGBA8888,
            # 必須明確帶尺寸：不帶會踩上游 b/537802959 的 0x0 pre-borrow。
            width=args.width,
            height=args.height,
            transport=ec.ImageTransport(
                channel=ec.ImageTransport.MMAP, handle=make_handle(path)),
        )
        started = time.monotonic()
        for i, frame in enumerate(stub.streamScreenshot(fmt, timeout=args.timeout)):
            arr = frame_array(buf, args.width, args.height)
            digest = hashlib.md5(arr.tobytes()).hexdigest()[:12]
            nonzero = bool(arr.any())
            del arr                      # 釋放 export，否則 buf.close() 會 BufferError
            hashes.append(digest)
            elapsed = time.monotonic() - started
            print(f"  frame {i}: payload={len(frame.image)}B md5={digest} "
                  f"nonzero={nonzero} t={elapsed * 1000:.0f}ms")
            if i + 1 >= args.frames:
                break
    except grpc.RpcError as err:
        print(f"  gRPC {err.code().name}: {err.details()}", file=sys.stderr)
        rpc_failed = True
    finally:
        try:
            buf.close()
        except BufferError:
            pass                         # 提早 break 時仍可能有殘存 export，不影響判讀
        channel.close()
        # **unlink 不能掛在 buf.close() 上**：上面那個 BufferError 就是常態（我們一定
        # 提早 break），一旦吞掉，檔案就留在 $TMPDIR，每跑一次多 2.5MB。D39 第一次跑完
        # 留了 5 個才發現。POSIX 語意保證這裡 unlink 是安全的——還在映射／還開著的檔案
        # 要等最後一個引用消失才真的刪掉。
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

    distinct = len(set(hashes))
    print(f"\n[mmap-parity] frames={len(hashes)} distinct={distinct} "
          f"window={elapsed * 1000:.0f}ms")
    # **先判 distinct 再判 rpc_failed**，順序有意義：逾時只有在幀沒收滿時才會觸發，
    # 而「收到的幀已經足以證明映射區在動」就是這支腳本要回答的全部問題——那時逾時
    # 只是我們沒等到第 30 幀，不是結論失效。
    if distinct >= 2:
        print("→ PYTHON_OK：emulator 的 MMAP 寫入端正常；Swift 若仍紅，缺陷在 client 側")
        return 0
    if rpc_failed:
        print(f"→ RPC_FAILED：{args.timeout}s 內只收到 {len(hashes)} 幀，這次結果不能拿來判讀對照。")
        print("   最常見的原因是 guest 畫面沒在動（animate.py 沒起來、或跑了多個實例互搶）。")
        return 3
    # 全同有兩種讀法，而它們的下一步完全相反：真凍結要去查 emulator，
    # 「guest 畫面在這個窗口內本來就沒變」只是取樣沒供應——不先排除後者就下結論，
    # 等於把供應不足讀成缺陷。
    print("→ PYTHON_FROZEN：Python 也拿不到相異的幀。")
    print("   **先確認 animate.py 真的在跑**——streamScreenshot 是變化驅動的，")
    print("   guest 畫面靜止時本來就會連續送出相同內容，那不是凍結。")
    return 2


if __name__ == "__main__":
    sys.exit(main())
