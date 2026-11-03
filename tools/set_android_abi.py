"""设置 Android 导出预设的 ABI 开关（模拟器 x86_64 / 真机 arm64）。

为什么要有这个脚本：export_presets.cfg 是 Godot 编辑器会回写的文件，手工改一行
容易和别的会话/编辑器互相覆盖；这里按"预设块"精确定位，只动 Android 的
`architectures/*`，其余字节不变（UTF-8、CRLF 原样保留）。

用法：
    python tools/set_android_abi.py x86_64     # 模拟器
    python tools/set_android_abi.py arm64      # 真机 / 发布
    python tools/set_android_abi.py both
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
PRESETS = REPO / "Project" / "project-keynes" / "export_presets.cfg"

KEYS = {
    "arm64": "architectures/arm64-v8a",
    "x86_64": "architectures/x86_64",
    "x86": "architectures/x86",
    "armeabi-v7a": "architectures/armeabi-v7a",
}


def android_block_span(lines: list[str]) -> tuple[int, int]:
    """Return [start, end) line indexes of the Android [preset.N] .. [preset.N.options] block."""
    start = -1
    for index, line in enumerate(lines):
        if line.strip().startswith("[preset.") and not line.strip().endswith(".options"):
            if any(lines[j].strip() == 'platform="Android"' for j in range(index, min(index + 12, len(lines)))):
                start = index
                break
    if start < 0:
        raise SystemExit("Android preset block not found in export_presets.cfg")
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].strip().startswith("[preset."):
            end = index
            break
    return start, end


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__)
        return 2
    wanted = argv[1]
    enabled = {"arm64": {"arm64"}, "x86_64": {"x86_64"}, "both": {"arm64", "x86_64"}}
    if wanted not in enabled:
        print(__doc__)
        return 2

    raw = PRESETS.read_bytes().decode("utf-8")
    lines = raw.splitlines(keepends=True)
    start, end = android_block_span(lines)
    touched: list[str] = []
    for index in range(start, end):
        for name, key in KEYS.items():
            if lines[index].strip().startswith(key + "="):
                value = "true" if name in enabled[wanted] else "false"
                newline = lines[index].split("=", 1)[1]
                trailing = "\r\n" if newline.endswith("\r\n") else "\n"
                lines[index] = "%s=%s%s" % (key, value, trailing)
                touched.append(lines[index].strip())
    PRESETS.write_bytes("".join(lines).encode("utf-8"))
    print("android preset ABI -> %s" % wanted)
    for line in touched:
        print("  " + line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
