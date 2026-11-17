#!/usr/bin/env python3
"""生成 Swei 子集字体（WOFF2），供 Godot 作为 FontFile 直接导入。

背景
----
`SweiGothicLegCJKsc` 的完整版覆盖 44936 个字形（20972 汉字 + 9033 Ext），
两个字重经 Godot 的 zstd 压缩后仍占 19.97 MiB。项目实际只用到 2743 个汉字，
且移动端包体吃紧，因此改为「GB2312 ∪ 仓库实际用字 ∪ 常用标点」的子集。

体积（实测）：
  完整 TTF -> Godot zstd fontdata   10.13 / 9.84 MiB
  完整 TTF -> WOFF2（无损）           5.62 / 5.71 MiB
  子集     -> WOFF2                   1.05 / 1.10 MiB

字形集合 = GB2312 汉字(6763) ∪ 仓库文本出现的全部字符 ∪ 常用标点符号。
仓库新增内容若用到 GB2312 之外的生僻字，会落到 `allow_system_fallback`
的系统字体上；用 `--check` 可以让 CI 提前发现这种漂移。

用法
----
    python tools/fonts/subset_swei.py            # 重新生成两个 .woff2
    python tools/fonts/subset_swei.py --check     # 只检查，缺字则 exit 1

依赖：pip install fonttools brotli
"""

from __future__ import annotations

import argparse
import io
import sys
from pathlib import Path

try:
    from fontTools import subset as ft_subset
    from fontTools.ttLib import TTFont
except ImportError:  # pragma: no cover
    sys.exit("需要 fonttools：pip install fonttools brotli")
try:
    import brotli  # noqa: F401
except ImportError:  # pragma: no cover
    sys.exit("需要 brotli：pip install brotli")

PROJECT = Path(__file__).resolve().parents[2] / "Project" / "project-keynes"
FONT_DIR = PROJECT / "assets" / "fonts" / "swei"
SOURCE_DIR = FONT_DIR / "source"

FACES = {
    "Regular": "SweiGothicLegCJKsc-Regular",
    "Bold": "SweiGothicLegCJKsc-Bold",
}

# 扫描范围与后缀：仓库里可能承载玩家可见文本的东西
SCAN_ROOTS = ["data", "scenes", "scripts", "assets", "ui", "localization"]
SCAN_SUFFIXES = {".gd", ".tscn", ".tres", ".json", ".cfg", ".csv", ".md", ".txt", ".po", ".translation"}
SKIP_DIRS = {".godot", ".git", "tmp", "node_modules"}

# 永远保留：ASCII、拉丁补充、通用标点、CJK 标点、全角形式、常用符号。
# 按码段整块取，避免逐个手写标点漏码位（U+00B7 与 U+2027 会映射到不同字形，
# 只写其中一个会让另一个在 Bold 里掉字）。
KEEP_RANGES = [
    (0x0020, 0x007E),  # ASCII
    (0x00A0, 0x00FF),  # Latin-1 补充（· × ÷ © 等）
    (0x2000, 0x206F),  # 通用标点（– — ‘ ’ “ ” … • ‥ ※）
    (0x2160, 0x217F),  # 罗马数字 ⅠⅡⅢ
    (0x2190, 0x21FF),  # 箭头 ← → ↑ ↓
    (0x2460, 0x2473),  # ①②③
    (0x25A0, 0x25FF),  # 几何图形 ■ □ ◆ ◇ ▲ ▼
    (0x2600, 0x26FF),  # 杂项符号 ★ ☆
    (0x2700, 0x27BF),  # 装饰符号 ✅ ✗ ❌
    (0x3000, 0x303F),  # CJK 标点 、。〈〉《》「」【】・ー
    (0xFF01, 0xFF5E),  # 全角 ！？：；（）＋－
    (0xFFE0, 0xFFE5),  # 全角 ￥ ￠
    (0x3007, 0x3007),  # 〇
]


def base_chars() -> set[str]:
    out: set[str] = set()
    for lo, hi in KEEP_RANGES:
        out |= {chr(c) for c in range(lo, hi + 1)}
    return out


def repo_chars() -> set[str]:
    chars: set[str] = set()
    for root_name in SCAN_ROOTS:
        root = PROJECT / root_name
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in SCAN_SUFFIXES:
                continue
            if SKIP_DIRS & set(path.relative_to(PROJECT).parts):
                continue
            try:
                chars |= set(path.read_text(encoding="utf-8", errors="ignore"))
            except OSError:
                continue
    return chars


def gb2312_hanzi() -> set[str]:
    out: set[str] = set()
    for hi in range(0xB0, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                ch = bytes([hi, lo]).decode("gb2312")
            except UnicodeDecodeError:
                continue
            if 0x4E00 <= ord(ch) <= 0x9FFF:
                out.add(ch)
    return out


def wanted_chars() -> set[str]:
    return gb2312_hanzi() | repo_chars() | base_chars()


def build_face(stem: str, chars: set[str]) -> tuple[int, int]:
    source = SOURCE_DIR / f"{stem}.ttf"
    if not source.is_file():
        sys.exit(f"缺少母版字体：{source}")
    options = ft_subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.notdef_outline = True
    options.hinting = True
    font = ft_subset.load_font(str(source), options)
    subsetter = ft_subset.Subsetter(options=options)
    subsetter.populate(text="".join(sorted(chars)))
    subsetter.subset(font)

    out = FONT_DIR / f"{stem}.woff2"
    buf = io.BytesIO()
    font.flavor = "woff2"
    font.save(buf)
    out.write_bytes(buf.getvalue())
    font.close()
    return len(chars), out.stat().st_size


def unicode_coverage(path: Path) -> set[int]:
    """只取 Unicode cmap（platform 0 / 3-1 / 3-10）。

    字体里常留有 MacRoman 等旧子表，按所有子表求并集会把「母版本来就没有」的
    码位算成有（U+00B7 就是这种情况），从而误报成子集掉字。
    """
    font = TTFont(path)
    codes: set[int] = set()
    for table in font["cmap"].tables:
        if (table.platformID, table.platEncID) in ((0, 3), (0, 4), (3, 1), (3, 10)):
            codes |= set(table.cmap.keys())
    font.close()
    return codes


def check() -> int:
    """检查仓库用字是否被随包子集覆盖。

    判据是「母版有、子集没有」才算回归；母版本身就没有的字（如 `巽`）属于
    既有缺口，运行时交给系统字体，只做提示不判失败。
    """
    repo = {ord(c) for c in repo_chars()}
    failed = False
    for label, stem in FACES.items():
        path = FONT_DIR / f"{stem}.woff2"
        master = SOURCE_DIR / f"{stem}.ttf"
        if not path.is_file():
            print(f"[{label}] 缺少子集字体：{path}")
            failed = True
            continue
        subset_codes = unicode_coverage(path)
        master_codes = unicode_coverage(master) if master.is_file() else set()
        regression = sorted(c for c in repo - subset_codes if c in master_codes)
        pregap = sorted(c for c in repo - master_codes)
        if regression:
            failed = True
            print(f"[{label}] 回归 {len(regression)} 个：{''.join(map(chr, regression))[:80]}")
        else:
            print(f"[{label}] 仓库用字全覆盖（母版既有缺口 {len(pregap)} 个，走系统兜底）")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="生成 Swei 子集 WOFF2")
    parser.add_argument("--check", action="store_true", help="只检查仓库用字是否都在子集里")
    args = parser.parse_args()
    if args.check:
        return check()

    chars = wanted_chars()
    print(f"字形集合：{len(chars)} 个（GB2312 + 仓库用字 + 标点）")
    total = 0
    for label, stem in FACES.items():
        glyphs, size = build_face(stem, chars)
        total += size
        print(f"  {label:8s} glyphs={glyphs:5d}  {size / 1048576:5.2f} MiB -> {stem}.woff2")
    print(f"合计 {total / 1048576:.2f} MiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
