#!/usr/bin/env python3
"""手機遙控的 WebSocket 用戶端（活體腳本用，不進產品）。

連 /ws/video 等 keyframe、追幀序；--touch 時連 /ws/input 送
一組 down/move/up；--pinch 秒數送雙指約 120Hz 縮放並持續收 stats。
--key GoHome 送按鍵，--text 送整串文字。
量 ping 往返，輸入完成前保持 video 連線。輸出 KEY=VAL 供 bash 斷言。
--loop：反覆重連、丟掉收到的幀，只為了讓編碼器有 viewer（驗收線 7 對照用）。

退出碼：0 通過、2 連不上（403／409／refused）、3 等不到 keyframe。
"""
import argparse
import asyncio
import json
import math
from pathlib import Path
import re
import statistics
import struct
import sys
import time

NAVIGATION_KEYS = ("GoBack", "GoHome", "AppSwitch", "Backspace")

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

def text_message(text: str, now_ms: float) -> str:
    """與 Swift／viewer 一致：非空，最多 4096 個 UTF-16 單元。"""
    if not isinstance(text, str) or not text or len(text.encode("utf-16-le")) // 2 > 4096:
        raise ValueError("text must contain 1–4096 UTF-16 units")
    return json.dumps({"type": "text", "text": text, "t": now_ms}, ensure_ascii=False)

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

def report_stats(message, results):
    """文字只作診斷，不干擾幀序、keyframe 期限或二進位解碼。"""
    try:
        stats = json.loads(message)
    except (ValueError, TypeError) as error:
        print(f"stats JSON error: {error}", file=sys.stderr)
        return
    if not isinstance(stats, dict) or stats.get("type") != "stats":
        return
    encoded = json.dumps(stats, ensure_ascii=False, separators=(",", ":"))
    print(f"MAC_STATS={encoded}", flush=True)
    results["MAC_STATS_WINDOWS"] = results.get("MAC_STATS_WINDOWS", 0) + 1
    results["MAC_STATS_LAST"] = encoded
    if contained_stats(stats, results, time.monotonic()):
        print(f"PINCH_STATS={encoded}", flush=True)

async def receive_video(args, results):
    from websockets.asyncio.client import connect

    tracker = SequenceTracker()
    started = time.monotonic()
    keyframe_at = None
    pinch = getattr(args, "pinch", None)
    seconds = max(args.seconds, pinch + 2) if pinch else args.seconds
    async with connect(video_url(args.host, args.port, args.token), max_size=None, **connect_options()) as video:
        pinch_task = None
        try:
            while True:
                elapsed = time.monotonic() - started
                budget = remaining_budget(elapsed, keyframe_at, args.wait_keyframe, seconds)
                if budget <= 0:
                    break
                try:
                    message = await asyncio.wait_for(video.recv(), timeout=budget)
                except asyncio.TimeoutError:
                    break
                if not isinstance(message, bytes):
                    report_stats(message, results)
                    continue
                _, seq, keyframe, _ = parse_header(message)
                if keyframe_at is None and not keyframe:
                    continue
                if keyframe_at is None:
                    keyframe_at = time.monotonic() - started
                    if pinch:
                        pinch_task = asyncio.create_task(run_pinch(args, results))
                tracker.observe(seq, keyframe)
            # input 依附 video；pinch Task 與上述收幀／stats 迴圈並行。
            if (args.touch or args.key or args.text is not None) and keyframe_at is not None:
                await send_touch(args, results)
            if pinch_task is not None:
                await pinch_task
        finally:
            if pinch_task is not None:
                pinch_task.cancel()
                await asyncio.gather(pinch_task, return_exceptions=True)
    results["KEYFRAME_SECONDS"] = f"{keyframe_at:.2f}" if keyframe_at is not None else ""
    results["FRAMES"] = tracker.frames
    results["KEYFRAMES"] = tracker.keyframes
    results["SEQ_GAPS"] = tracker.gaps
    return keyframe_at is not None

async def run_pinch(args, results):
    from websockets.asyncio.client import connect
    async with connect(input_url(args.host, args.port, args.token), **connect_options()) as inbound:
        await send_pinch(inbound, args.pinch, results)

async def send_touch(args, results):
    from websockets.asyncio.client import connect

    results["TOUCH_SENT"] = 0
    async with connect(input_url(args.host, args.port, args.token), **connect_options()) as inbound:
        messages = touch_messages(0.5, 0.5, pointer_id=args.pointer_id, now_ms=time.monotonic() * 1000) if args.touch else []
        for text in messages:
            await inbound.send(text)
            results["TOUCH_SENT"] += 1
            await asyncio.sleep(0.08)
        if args.key:
            await inbound.send(key_message(args.key, time.monotonic() * 1000))
            results["KEY_SENT"] = args.key
        if args.text is not None:
            await inbound.send(text_message(args.text, time.monotonic() * 1000))
            results["TEXT_SENT"] = 1
        sent = time.monotonic()
        ping = json.dumps({"type": "ping", "t": sent * 1000})
        await inbound.send(ping)
        echo = await asyncio.wait_for(inbound.recv(), timeout=5)
        results["PING_RTT_MS"] = f"{(time.monotonic() - sent) * 1000:.1f}"
        results["PING_ECHO_OK"] = 1 if echo == ping else 0

async def loop_forever(args):
    from websockets.asyncio.client import connect

    last_report = -1
    stats_results = {}
    while True:
        try:
            async with connect(video_url(args.host, args.port, args.token), max_size=None, **connect_options()) as video:
                async for message in video:
                    if not isinstance(message, bytes):
                        report_stats(message, stats_results)
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
        if key.startswith("_"): continue
        print(f"{key}={value}")
    return 0 if keyframe else 3

def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", required=True)
    parser.add_argument("--wait-keyframe", type=float, default=60.0, help="等第一個 keyframe 的秒數")
    parser.add_argument("--seconds", type=float, default=10.0, help="keyframe 之後再收幾秒")
    parser.add_argument("--pinch", type=float, help="雙指約 120Hz 縮放秒數；結束後立即送單點 tap")
    parser.add_argument("--touch", action="store_true")
    parser.add_argument("--pointer-id", type=int, default=1, help="觸控識別碼（可為 iOS Safari 的負數）")
    parser.add_argument("--key", choices=NAVIGATION_KEYS, help="送出一組導覽鍵按放")
    parser.add_argument("--text", help="完整文字經既有剪貼簿提交交易送入 guest")
    parser.add_argument("--loop", action="store_true")
    args = parser.parse_args(argv)
    if args.pinch is not None:
        if not math.isfinite(args.pinch) or args.pinch <= 0:
            parser.error("--pinch 必須為有限正秒數")
        if args.loop or args.touch or args.key or args.text is not None:
            parser.error("--pinch 不可與 --loop/--touch/--key/--text 同用")
    return args


def pinch_message(phase, elapsed, now_ms):
    radius = 0.18 + 0.10 * math.sin(elapsed * math.tau)
    return json.dumps({"type": "touches", "t": now_ms, "points": [
        {"id": -101, "phase": phase, "x": 0.5 - radius, "y": 0.5},
        {"id": -102, "phase": phase, "x": 0.5 + radius, "y": 0.5},
    ]})

async def send_pinch(inbound, seconds, results, clock=time.monotonic, sleep=asyncio.sleep):
    started = clock()
    results["_pinch_started"] = started
    results["_pinch_end"] = started + seconds
    await inbound.send(pinch_message("down", 0, started * 1000))
    count = 1
    # 固定 deadline 約每 8ms 一則；落後時不補送過期座標造成額外 burst。
    next_at = started + 0.008
    while next_at < started + seconds:
        await sleep(max(0, next_at - clock()))
        now = clock()
        if now >= started + seconds:
            break
        await inbound.send(pinch_message("move", now - started, now * 1000))
        count += 1
        next_at = max(next_at + 0.008, clock() + 0.001)
    await sleep(max(0, started + seconds - clock()))
    await inbound.send(pinch_message("up", seconds, clock() * 1000))
    ended = clock()
    results["_pinch_end"] = ended
    results["PINCH_BATCHES"] = count + 1
    results["PINCH_SECONDS"] = ended - started
    await sleep(0.08)
    tap_at = clock()
    results["POST_PINCH_TAP_AT"] = tap_at
    results["POST_PINCH_TAP_SENT_MS"] = (tap_at - ended) * 1000
    await inbound.send(json.dumps({"type": "down", "id": -103, "t": tap_at * 1000, "x": 0.5, "y": 0.7}))
    await sleep(0.05)
    await inbound.send(json.dumps({"type": "up", "id": -103, "t": clock() * 1000, "x": 0.5, "y": 0.7}))
    # 保持配對，不能靠斷線 releaseAll 補出測試所期待的 up。
    await sleep(0.6)

def contained_stats(stats, results, received_at):
    start, end = results.get("_pinch_started"), results.get("_pinch_end")
    interval = stats.get("intervalMs")
    return (start is not None and end is not None and finite_number(interval) and interval > 0
            and received_at <= end and received_at - interval / 1000 >= start)

def finite_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)

def touch_evidence(text):
    slot = 0
    transitions = []
    for line in text.splitlines():
        match = re.search(r"ABS_MT_SLOT\s+([0-9a-fA-F]+)", line)
        if match:
            slot = int(match[1], 16)
        match = re.search(r"ABS_MT_TRACKING_ID\s+([0-9a-fA-F]+)", line)
        if match:
            timestamp = re.search(r"\[\s*(\d+\.\d+)\s*\]", line)
            if not timestamp:
                raise ValueError("getevent 缺少 guest monotonic 時間戳")
            transitions.append((float(timestamp[1]), slot, int(match[1], 16) != 0xFFFFFFFF))
    return transitions

def verify(client_text, event_text):
    samples = []
    values = {}
    for line in client_text.splitlines():
        if line.startswith("PINCH_STATS="):
            samples.append(json.loads(line.split("=", 1)[1]))
        elif "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    if len(samples) < 2:
        raise ValueError(f"pinch 完整統計窗口不足：{len(samples)}，至少需要 2 窗")
    rates, transits = [], []
    for sample in samples:
        rate, transit = sample.get("inputRPCsPerSecond"), sample.get("transitMs")
        if not finite_number(rate) or rate <= 0 or not finite_number(transit) or transit < 0:
            raise ValueError(f"RPC/transit 有缺值或無效樣本：{sample}")
        rates.append(rate)
        transits.append(transit)
    print(f"R7 RPC/s 各窗={rates}；合併批次={[s.get('inputCoalesced') for s in samples]}")
    median = statistics.median(transits)
    print(f"R7 transit 各窗 p50={transits} ms；窗口 p50 中位數={median:.2f} ms（非原始幀合併百分位）")
    if max(rates) > 70 or max(transits) >= 50:
        raise ValueError("RPC/s 必須每窗 ≤70，完整窗口的 transit p50 必須全部 <50ms")
    duration = float(values.get("PINCH_SECONDS", "nan"))
    batches = float(values.get("PINCH_BATCHES", "nan"))
    sent_ms = float(values.get("POST_PINCH_TAP_SENT_MS", "nan"))
    print(f"R7 來源：{batches} 批／{duration:.3f}s；結束後 {sent_ms:.2f}ms 發出 tap")
    if not (3 <= duration < 4 and 110 <= batches / duration <= 130 and 0 <= sent_ms <= 500):
        raise ValueError("來源未達 3 秒約 120Hz 或 tap 未在 500ms 內送出")
    transitions = touch_evidence(event_text)
    print(f"R7 guest TRACKING_ID 證據（秒、slot、down）：{transitions}")
    # 獨立 capture 只應有雙指按下、雙指放開、接續 tap 按放六個邊緣。
    if len(transitions) != 6:
        raise ValueError("預期 pinch 四個邊緣及 tap 兩個邊緣；缺漏或額外輸入")
    downs, ups, tap = transitions[:2], transitions[2:4], transitions[4:]
    slots = {event[1] for event in downs}
    if (len(slots) != 2 or not all(e[2] for e in downs) or any(e[2] for e in ups)
            or {e[1] for e in ups} != slots or not tap[0][2] or tap[1][2] or tap[0][1] != tap[1][1]):
        raise ValueError("兩個 slot 必須先各按下及放開，才是獨立 tap")
    if any(a[0] > b[0] for a, b in zip(transitions, transitions[1:])):
        raise ValueError("guest 時間戳倒退")
    # 三秒縮放不可被整串壓縮成短 burst 後才一起出現。
    guest_duration = min(e[0] for e in ups) - max(e[0] for e in downs)
    gap_ms = (tap[0][0] - max(e[0] for e in ups)) * 1000
    print(f"R7 guest pinch 持續={guest_duration:.3f}s；最後一指放開 → tap down={gap_ms:.2f}ms")
    arrivals = [float(match[1]) for line in event_text.splitlines()
                if "ABS_MT_TRACKING_ID" in line
                for match in [re.search(r"HOST_RECEIVED=(\d+\.\d+)", line)] if match]
    tap_at = float(values.get("POST_PINCH_TAP_AT", "nan"))
    if len(arrivals) != 6 or not math.isfinite(tap_at):
        raise ValueError("缺少 host 接收時間或 tap 發送時間，不能證明未排隊")
    arrival_ms = (arrivals[4] - tap_at) * 1000
    print(f"R7 tap send → host 讀到 guest TRACKING_ID={arrival_ms:.2f}ms（含 adb 傳輸）")
    if not 0 <= arrival_ms <= 500:
        raise ValueError("tap 送出後未在 500ms 內看到 guest TRACKING_ID")
    if not 2.5 <= guest_duration <= 3.5 or not 0 <= gap_ms <= 500:
        raise ValueError("guest 縮放時長異常或後續 tap 排隊超過 500ms")

def verify_pinch_files(argv):
    try:
        verify(Path(argv[0]).read_text(), Path(argv[1]).read_text())
    except (ValueError, KeyError, OSError, IndexError) as error:
        print(f"❌ R7：{error}", file=sys.stderr)
        return 1
    print("✅ R7 多點縮放、RPC、transit 與後續 tap 證據通過")
    return 0

if __name__ == "__main__":
    if sys.argv[1:] == ["--stamp"]:
        for line in sys.stdin:
            print(f"HOST_RECEIVED={time.monotonic():.9f} {line.rstrip()}", flush=True)
    elif sys.argv[1:2] == ["--verify-pinch"]:
        sys.exit(verify_pinch_files(sys.argv[2:]))
    else:
        sys.exit(asyncio.run(main(parse_args())))
