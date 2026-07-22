"""幀時戳序列的統計摘要。純函式、不可變輸出。"""
from dataclasses import dataclass


@dataclass(frozen=True)
class StreamStats:
    frames: int
    duration_s: float
    fps: float
    p50_ms: float
    p95_ms: float


def percentile(values: list[float], p: float) -> float:
    if not values:
        raise ValueError("values 不可為空")
    if not 0 <= p <= 100:
        raise ValueError(f"p 必須在 0–100 之間，收到 {p}")
    ordered = sorted(values)
    k = (len(ordered) - 1) * p / 100
    lo = int(k)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def summarize(timestamps: list[float]) -> StreamStats:
    if len(timestamps) < 2:
        raise ValueError("至少需要 2 個時戳")
    deltas_ms = [
        (b - a) * 1000 for a, b in zip(timestamps, timestamps[1:])
    ]
    duration = timestamps[-1] - timestamps[0]
    return StreamStats(
        frames=len(timestamps),
        duration_s=duration,
        fps=(len(timestamps) - 1) / duration,
        p50_ms=percentile(deltas_ms, 50),
        p95_ms=percentile(deltas_ms, 95),
    )
