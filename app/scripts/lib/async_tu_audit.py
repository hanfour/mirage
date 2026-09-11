"""找出跨模組 weak async 函式指標（Tu）副本的 context 大小不一致。"""

import collections
from pathlib import Path
import re
import subprocess
import sys


def sections(obj):
    output = subprocess.run(
        ["otool", "-l", str(obj)], capture_output=True, text=True, check=True
    ).stdout
    return [(int(m[3], 16), int(m[4], 16), int(m[5])) for m in re.finditer(
        r"sectname (\S+)\n\s+segname (\S+)\n\s+addr (0x[0-9a-f]+)\n"
        r"\s+size (0x[0-9a-f]+)\n\s+offset (\d+)", output)]


def audit(build_dir):
    if not build_dir.is_dir():
        raise ValueError(f"找不到建置產物目錄：{build_dir}")
    objects = sorted(build_dir.glob("*.build/*.o"))
    if not objects:
        raise ValueError(f"{build_dir} 的 .o 檔數量為 0，無法稽核")

    sizes = collections.defaultdict(lambda: collections.defaultdict(set))
    for obj in objects:
        module = obj.parent.name.removesuffix(".build")
        data = None
        output = subprocess.run(
            ["nm", "-m", str(obj)], capture_output=True, text=True, check=True
        ).stdout
        for line in output.splitlines():
            if "undefined" in line or "weak" not in line or not line.rstrip().endswith("Tu"):
                continue
            if data is None:
                data = obj.read_bytes()
                ss = sections(obj)
            address = int(line.split()[0], 16)
            for start, size, offset in ss:
                if start <= address < start + size:
                    position = offset + address - start + 4
                    if address + 8 > start + size or position + 4 > len(data):
                        raise ValueError(f"{obj} 的 Tu context 大小欄位不完整：{line}")
                    context_size = int.from_bytes(data[position:position + 4], "little")
                    sizes[line.split()[-1]][context_size].add(module)
                    break
            else:
                raise ValueError(f"{obj} 的 Tu 符號找不到 section：{line}")

    bad = [(symbol, by) for symbol, by in sizes.items()
           if len(set().union(*by.values())) > 1 and len(by) > 1]
    for symbol, by in bad:
        print("⚠️", {k: sorted(v) for k, v in sorted(by.items())}, symbol)
    print(f"掃描 {len(objects)} 個 .o 檔")
    print(f"大小不一致 {len(bad)} 個")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("用法：python3 async_tu_audit.py <建置產物目錄>")
    try:
        sys.exit(audit(Path(sys.argv[1])))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"async Tu 稽核失敗：{error}", file=sys.stderr)
        sys.exit(1)
