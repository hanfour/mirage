#!/usr/bin/env python3
"""產生 D44 用的受控音源 WAV，兩種波形共用同一支產生器。

兩個檔案的唯一差別是「音訊有沒有中斷」：

- `tone.wav`：整段連續的 440Hz 正弦波，振幅固定 12000。§11 已量過兩輪各 640 秒零崩潰。
- `tone_gap.wav`：同樣的正弦波，每 `--on` 秒之後插入 `--off` 秒的數位靜音（樣本為 0）。

兩者取樣率、聲道、振幅、長度全部相同，所以交付率的差異只能來自中斷本身。
靜音段寫的是 0 而不是略過，檔案長度與連續版一致，播放端的時間軸也一致。

用法：
    python3 app/scripts/lib/audio_make_tone.py app/scripts/lib/audio_www
"""

import argparse
import math
import os
import struct
import wave

RATE = 48_000
CHANNELS = 2
AMPLITUDE = 12_000
FREQ_HZ = 440.0


def samples(seconds: float, on: float, off: float) -> bytes:
    """回傳交錯的 s16 樣本；`off` 為 0 時是連續波形。"""
    total = int(seconds * RATE)
    period = on + off
    out = bytearray()
    for i in range(total):
        t = i / RATE
        silent = off > 0 and (t % period) >= on
        value = 0 if silent else int(AMPLITUDE * math.sin(2 * math.pi * FREQ_HZ * t))
        out += struct.pack("<hh", value, value)
    return bytes(out)


def write_wav(path: str, payload: bytes) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(payload)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("out_dir")
    p.add_argument("--seconds", type=float, default=30.0)
    p.add_argument("--on", type=float, default=8.0)
    p.add_argument("--off", type=float, default=2.0)
    args = p.parse_args()

    # 迴圈播放時接點要對齊：長度必須是 on+off 的整數倍，否則每輪的靜音位置會漂移。
    period = args.on + args.off
    if abs(args.seconds / period - round(args.seconds / period)) > 1e-9:
        raise SystemExit(f"--seconds {args.seconds} 不是 on+off={period} 的整數倍")

    os.makedirs(args.out_dir, exist_ok=True)
    write_wav(os.path.join(args.out_dir, "tone.wav"), samples(args.seconds, args.seconds, 0))
    write_wav(os.path.join(args.out_dir, "tone_gap.wav"),
              samples(args.seconds, args.on, args.off))
    print(f"tone.wav 連續 {args.seconds}s；tone_gap.wav {args.on}s 響 {args.off}s 靜音，"
          f"{RATE}Hz/{CHANNELS}ch/振幅 {AMPLITUDE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
