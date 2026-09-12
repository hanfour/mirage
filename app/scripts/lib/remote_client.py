#!/usr/bin/env python3
"""手機遙控的 WebSocket 用戶端（活體腳本用，不進產品）。

模仿 viewer.html：連 /ws/video 等第一個 keyframe、追幀序；--touch 時連 /ws/input 送
一組 down/move/up；--key GoHome 送導覽鍵，並量 ping 往返；輸入完成前保持 video 連線。輸出 KEY=VAL 供 bash 斷言。
--loop：反覆重連、丟掉收到的幀，只為了讓編碼器有 viewer（驗收線 7 對照用）。

退出碼：0 通過、2 連不上（403／409／refused）、3 等不到 keyframe。
純函式（parse_header、SequenceTracker、touch_messages、video_url、input_url）不依賴
websockets，remote_client_selftest.py 用系統 python3 直接測。
"""
import argparse
import asyncio
import json
import struct
import sys
import time

NAVIGATION_KEYS = ("GoBack", "GoHome", "AppSwitch")

HEADER = struct.Struct(">QIB")   # 8 bytes monotonic ns、4 bytes seq、1 byte keyframe（spec 第 4 節）


def parse_header(data: bytes):
    """回 (sent_ns, seq, is_keyframe, access_unit)。短於標頭或旗標不是 0/1 就 ValueError。"""
    if len(data) <= HEADER.size:
        raise ValueError(f"short video message: {len(data)} bytes")
    sent_ns, seq, key = HEADER.unpack_from(data, 0)
    if key > 1:
        raise ValueError(f"bad keyframe flag: {key}")
    unit = data[HEADER.size:]
    if not unit.startswith((b"\x00\x00\x01", b"\x00\x00\x00\x01")):
        raise ValueError("video payload is not Annex-B")
    return sent_ns, seq, key == 1, unit


class SequenceTracker:
    """幀序連續性：與 viewer.html 同一個算法（32 位元回繞）。"""

    def __init__(self):
        self.last = None
        self.frames = 0
        self.keyframes = 0
        self.gaps = 0

    def observe(self, seq: int, keyframe: bool):
        if self.last is not None:
            self.gaps += (seq - self.last - 1) & 0xFFFFFFFF
        self.last = seq
        self.frames += 1
        self.keyframes += 1 if keyframe else 0


def touch_messages(x: float, y: float, pointer_id: int = 1, now_ms: float = 0.0):
    """一組 down/move/up 的 JSON 文字，格式同 viewer.html:196。"""
    return [
        json.dumps({"t": now_ms, "id": pointer_id, "type": "down", "x": x, "y": y}),
        json.dumps({"t": now_ms + 40, "id": pointer_id, "type": "move", "x": min(1.0, x + 0.05), "y": y}),
        json.dumps({"t": now_ms + 80, "id": pointer_id, "type": "up", "x": min(1.0, x + 0.05), "y": y}),
    ]


def key_message(key: str, now_ms: float) -> str:
    """導覽三鍵白名單，與伺服器協定相同。"""
    if key not in NAVIGATION_KEYS:
        raise ValueError(f"unsupported navigation key: {key}")
    return json.dumps({"type": "key", "key": key, "t": now_ms})


def video_url(host: str, port: int, token: str) -> str:
    return f"ws://{host}:{port}/ws/video?t={token}"


def input_url(host: str, port: int, token: str) -> str:
    return f"ws://{host}:{port}/ws/input?t={token}"


def remaining_budget(elapsed, keyframe_at, wait_keyframe, seconds):
    """從連線開始算固定期限；非 keyframe／文字訊息不能重設倒數。"""
    deadline = wait_keyframe if keyframe_at is None else keyframe_at + seconds
    return max(0.0, deadline - elapsed)


def connect_options():
    """websockets 13 沒有 proxy 參數；15 起必須明確停用代理。"""
    import websockets
    return {"proxy": None} if int(websockets.__version__.split(".")[0]) >= 15 else {}


async def receive_video(args, results):
    from websockets.asyncio.client import connect

    tracker = SequenceTracker()
    started = time.monotonic()
    keyframe_at = None
    async with connect(video_url(args.host, args.port, args.token), max_size=None, **connect_options()) as video:
        while True:
            elapsed = time.monotonic() - started
            budget = remaining_budget(elapsed, keyframe_at, args.wait_keyframe, args.seconds)
            if budget <= 0:
                break
            try:
                message = await asyncio.wait_for(video.recv(), timeout=budget)
            except asyncio.TimeoutError:
                break
            if not isinstance(message, bytes):
                continue
            _, seq, keyframe, _ = parse_header(message)
            if keyframe_at is None and not keyframe:
                continue                      # 伺服器從 IDR 起送，這裡再守一次
            if keyframe_at is None:
                keyframe_at = time.monotonic() - started
            tracker.observe(seq, keyframe)
        # input 只能依附目前的 video 配對；先完成觸控／echo，再離開 video context。
        if (args.touch or args.key) and keyframe_at is not None:
            await send_touch(args, results)
    results["KEYFRAME_SECONDS"] = f"{keyframe_at:.2f}" if keyframe_at is not None else ""
    results["FRAMES"] = tracker.frames
    results["KEYFRAMES"] = tracker.keyframes
    results["SEQ_GAPS"] = tracker.gaps
    return keyframe_at is not None


async def send_touch(args, results):
    from websockets.asyncio.client import connect

    results["TOUCH_SENT"] = 0
    async with connect(input_url(args.host, args.port, args.token), **connect_options()) as inbound:
        messages = touch_messages(0.5, 0.5, now_ms=time.monotonic() * 1000) if args.touch else []
        for text in messages:
            await inbound.send(text)
            results["TOUCH_SENT"] += 1
            await asyncio.sleep(0.08)
        if args.key:
            await inbound.send(key_message(args.key, time.monotonic() * 1000))
            results["KEY_SENT"] = args.key
        sent = time.monotonic()
        ping = json.dumps({"type": "ping", "t": sent * 1000})
        await inbound.send(ping)
        echo = await asyncio.wait_for(inbound.recv(), timeout=5)
        results["PING_RTT_MS"] = f"{(time.monotonic() - sent) * 1000:.1f}"
        results["PING_ECHO_OK"] = 1 if echo == ping else 0


async def loop_forever(args):
    from websockets.asyncio.client import connect

    last_report = -1
    while True:
        try:
            async with connect(video_url(args.host, args.port, args.token), max_size=None, **connect_options()) as video:
                async for message in video:
                    if not isinstance(message, bytes):
                        continue
                    parse_header(message)
                    second = int(time.time())
                    if second != last_report:
                        print(f"LOOP_FRAME={second}", flush=True)
                        last_report = second
            print(f"LOOP_DISCONNECTED={int(time.time())}", flush=True)
        except Exception as error:             # App 重啟中：等一下再連
            print(f"LOOP_DISCONNECTED={int(time.time())}", flush=True)
            print(f"viewer reconnect: {type(error).__name__}", file=sys.stderr, flush=True)
        await asyncio.sleep(0.5)


async def main(args) -> int:
    if args.loop:
        await loop_forever(args)
        return 0
    results = {}
    try:
        keyframe = await receive_video(args, results)
    except (OSError, ConnectionError) as error:
        print(f"CONNECT_ERROR={error}")
        return 2
    except Exception as error:                 # websockets 的 InvalidStatus（403／409）等
        print(f"CONNECT_ERROR={type(error).__name__}: {error}")
        return 2
    for key, value in results.items():
        print(f"{key}={value}")
    return 0 if keyframe else 3


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", required=True)
    parser.add_argument("--wait-keyframe", type=float, default=60.0, help="等第一個 keyframe 的秒數")
    parser.add_argument("--seconds", type=float, default=10.0, help="keyframe 之後再收幾秒")
    parser.add_argument("--touch", action="store_true")
    parser.add_argument("--key", choices=NAVIGATION_KEYS, help="送出一組導覽鍵按放")
    parser.add_argument("--loop", action="store_true")
    sys.exit(asyncio.run(main(parser.parse_args())))
