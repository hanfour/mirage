"""MMAP client 對照：檢查同一台 emulator 上的映射區是否持續更新。

這支工具在 2026-08-05 用來追查 grpc-swift 與 grpcio 結果不一致的現象。2026-10-01 重測時
grpc-swift 已能以接近 60 fps 交付畫面，但先前異常為何消失仍未查明。保留 Python 對照，
可協助區分 emulator 寫入端和 client 路徑問題，並在活體驗證前確認 emulator 端可用。

條件與 `MmapStreamLiveTests` 對齊（尺寸、明確帶尺寸、handle 放 $TMPDIR、先 getStatus
再 streamScreenshot、同一條 channel），唯一的變數是 client 實作。

用法（需 emulator 執行中，且 guest 畫面正在變動；streamScreenshot 是變化驅動）：
    cd phase0/harness
    ./.venv/bin/python animate.py --seconds 60 &      # 供應動畫
    ./.venv/bin/python mmap_client_parity.py [--width 898] [--height 1996]

**必須用 `.venv` 的 python，不能用系統的**：`gen/` 下的產生碼是 protobuf 7.x 產的，
系統 python 裝的是 4.x，一 import 就炸（D49）。平常是 `app/scripts/verify_mmap.sh`
呼叫本腳本，它已經處理好直譯器選擇。

退出碼：0 = 觀察到相異畫面／2 = 窗口內畫面全同／3 = RPC 失敗
"""
import argparse
import hashlib
import importlib.util
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


def _load_grpc_auth():
    """按路徑載入 probe 的 token helper，不讓同名 lib 遮蔽 harness/lib。"""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", "tools", "probe", "lib", "grpc_auth.py")
    spec = importlib.util.spec_from_file_location("mirage_probe_grpc_auth", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description="MMAP client 對照（Python vs Swift）")
    parser.add_argument("--target", default="localhost:8554")
    # 預設對齊 MmapStreamLiveTests 的 898x1996，避免用不同尺寸對照。
    parser.add_argument("--width", type=int, default=898)
    parser.add_argument("--height", type=int, default=1996)
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
    grpc_auth = _load_grpc_auth()
    port = int(args.target.rsplit(":", 1)[1])
    token = grpc_auth.discover_token(port)
    metadata = [("authorization", f"Bearer {token}")] if token else []
    channel = grpc.intercept_channel(
        grpc.insecure_channel(
            args.target, options=[("grpc.max_receive_message_length", -1)]),
        grpc_auth.AuthInterceptor(metadata))
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
    print("→ PYTHON_NO_CHANGE：窗口內沒有觀察到相異畫面。")
    print("   **先確認 animate.py 真的在跑**，streamScreenshot 是變化驅動的。")
    print("   guest 畫面靜止時本來就會連續送出相同內容，這不足以判定 MMAP 失效。")
    return 2


if __name__ == "__main__":
    sys.exit(main())
