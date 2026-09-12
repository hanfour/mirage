#!/usr/bin/env python3
"""第四段 Mac age 驗收：各窗 p50 的中位數 < 12 ms 且各窗 p95 的中位數 < 25 ms。

使用各窗口百分位的中位數，每窗等權；這不是合併原始幀樣本後的整段百分位。
偶數窗口取中間兩值的平均。逐窗數字保留作尖峰證據。
只有心跳的窗口沒有 age，不當作零；整段都沒有新幀則驗收失敗。
"""
import json
import math
import sys
from statistics import median
from pathlib import Path


def age_windows(lines):
    values = []
    for line in lines:
        if not line.startswith("MAC_STATS="):
            continue
        stats = json.loads(line.split("=", 1)[1])
        if not isinstance(stats, dict) or stats.get("type") != "stats":
            raise ValueError("MAC_STATS 不是 stats 物件")
        count = stats.get("newFrames")
        if type(count) is not int or count < 0:
            raise ValueError("newFrames 必須是非負整數")
        age = stats.get("age")
        if count == 0 and age is None:
            continue
        if not isinstance(age, dict) or type(age.get("count")) is not int or age["count"] != count or count == 0:
            raise ValueError("age 樣本數與新幀數不一致")
        pair = (age.get("p50"), age.get("p95"))
        for name, value in zip(("p50", "p95"), pair):
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError(f"age {name} 不是有效毫秒值")
        if pair[0] > pair[1]:
            raise ValueError("age p50 不得大於 p95")
        values.append(pair)
    if not values:
        raise ValueError("未收到有新幀的 age 樣本，無法量測")
    return values


def verify(lines):
    try:
        values = age_windows(lines)
    except (ValueError, TypeError) as error:
        print(f"❌ Mac age p50/p95：{error}")
        return 1
    median50 = median(pair[0] for pair in values)
    median95 = median(pair[1] for pair in values)
    print("Mac age p50/p95 各窗（ms）：" + ", ".join(f"{p50:.3f}/{p95:.3f}" for p50, p95 in values))
    passed = median50 < 12 and median95 < 25
    print(f"{'✅' if passed else '❌'} Mac age p50/p95 各窗中位數={median50:.3f}/{median95:.3f} ms；"
          f"有效窗口={len(values)}；中位數門檻 p50 < 12 ms 且 p95 < 25 ms")
    return 0 if passed else 1


if __name__ == "__main__":
    with Path(sys.argv[1]).open() as source:
        sys.exit(verify(source))
