#!/usr/bin/env python3
"""R8：先連線取得首幀並斷開，再驗證重連後十秒內有真正的新幀。

沿用 remote_client 的連線選項、協定解析與參數。此測試不操作 Mac 視窗，
休眠／隱藏的轉移由 LifecyclePolicyTests 覆蓋。
"""
import asyncio
import json
import sys
import time

from remote_client import connect_options, finite_number, parse_args, parse_header, video_url


def fresh_connected_stats(stats, elapsed):
    """只接受完整落在本次連線內的窗口；快取首幀、心跳不算恢復證據。"""
    if not isinstance(stats, dict) or stats.get("type") != "stats":
        return False
    interval = stats.get("intervalMs")
    frames = stats.get("newFrames")
    age = stats.get("secondsSinceNewFrame")
    return (0 <= elapsed <= 10 and stats.get("emulatorConnected") is True
            and finite_number(interval) and 0 < interval <= elapsed * 1000
            and finite_number(frames) and frames > 0
            and finite_number(age) and 0 <= age < elapsed)


async def observe(video, started, *, prime, clock=time.monotonic):
    """期限從握手完成起算，stats／心跳不得延長。輸出原文而非重新序列化。"""
    binary_frames = 0
    fresh = False
    while True:
        remaining = 10 - (clock() - started)
        if remaining <= 0:
            raise TimeoutError("十秒內未收到已連線且有新幀的證據")
        message = await asyncio.wait_for(video.recv(), timeout=remaining)
        elapsed = clock() - started
        if elapsed > 10:
            raise TimeoutError("證據抵達時已超過十秒")
        if isinstance(message, bytes):
            _, _, keyframe, _ = parse_header(message)
            binary_frames += 1
            if prime and keyframe:
                return
        else:
            print(f"{'PRIME' if prime else 'R8'}_MAC_STATS={message}", flush=True)
            try:
                stats = json.loads(message)
            except (ValueError, TypeError):
                continue
            fresh = fresh or fresh_connected_stats(stats, elapsed)
        if not prime and fresh and binary_frames > 0:
            print(f"R8_SECONDS={elapsed:.3f}", flush=True)
            print(f"R8_VIDEO_FRAMES={binary_frames}", flush=True)
            return


async def verify(args, *, connect=None, clock=time.monotonic, pause=asyncio.sleep):
    if connect is None:
        from websockets.asyncio.client import connect
    url = video_url(args.host, args.port, args.token)
    options = {**connect_options(), "max_size": None, "open_timeout": 5, "close_timeout": 1}
    async with connect(url, **options) as video:
        await observe(video, clock(), prime=True, clock=clock)
    print("R8_PRIME_DISCONNECTED=1", flush=True)
    # server 的 close callback 可能稍晚清除 viewer；僅在握手 409 時有限重試。
    for attempt in range(5):
        opened = False
        try:
            async with connect(url, **options) as video:
                opened = True
                await observe(video, clock(), prime=False, clock=clock)
            return
        except Exception as error:
            response = getattr(error, "response", None)
            status = getattr(response, "status_code", getattr(error, "status_code", None))
            if opened or status != 409 or attempt == 4:
                raise
            await pause(0.2)


async def main(args):
    try:
        await verify(args)
    except Exception as error:
        print(f"❌ R8：{type(error).__name__}: {error}", file=sys.stderr)
        return 1
    print("✅ R8 重連後十秒內 emulatorConnected=true 且 newFrames>0")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main(parse_args())))
