#!/usr/bin/env python3
"""第四段 Mac age 驗收：各有新幀窗口的 p95 必須嚴格小於 10 ms。

窗口百分位不能再平均當作整段百分位；取各窗口最大值作保守判定。
只有心跳的窗口沒有 age，不當作零；整段都沒有新幀則驗收失敗。
"""
import json
import math
import sys
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
        value = age.get("p95")
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise ValueError("age p95 不是有效毫秒值")
        values.append(value)
    if not values:
        raise ValueError("未收到有新幀的 age 樣本，無法量測")
    return values


def verify(lines):
    try:
        values = age_windows(lines)
    except (ValueError, TypeError) as error:
        print(f"❌ Mac age p95：{error}")
        return 1
    worst = max(values)
    print("Mac age p95 各窗（ms）：" + ", ".join(f"{value:.3f}" for value in values))
    passed = worst < 10
    print(f"{'✅' if passed else '❌'} Mac age p95 最大值={worst:.3f} ms；"
          f"有效窗口={len(values)}；門檻 < 10 ms（事件驅動預期 < 5 ms）")
    return 0 if passed else 1


if __name__ == "__main__":
    with Path(sys.argv[1]).open() as source:
        sys.exit(verify(source))
