#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Web 导出的中文字体子集化（只在打 Web 包时用；桌面/Android/编辑器不受影响）。

为什么需要
----------
`WebBuild/ProjectKeynes.pck` 约 282 MB，其中 `.fontdata` 约 57-59 MB（5 套中文字体
+ 2 套手写体 + FontAwesome）。gzip 只能再压 0.45%（纹理已是 VRAM 压缩格式），所以
体积只能从内容下手：把 6 个 10-16 MB 的全字库裁成"游戏里真正会出现的字符"。

子集化怎么落地（关键约束）
--------------------------
Godot 导出打包的是 **`.godot/imported/*.fontdata`**（导入产物），不是 `assets/fonts`
里的 `.ttf` 源文件；而 `res://assets/fonts/...` 的引用、`.import` 的 remap 路径都是
固定的。所以本脚本不去改源文件、也不去改任何 `res://` 引用（桌面构建因此逐字节不变），
而是分三步"借用"导入缓存：

  1. 把字体裁成子集，写到 `tmp/web_font_subset/fonts/...`（gitignored 的缓存目录）；
  2. 在 `tmp/web_font_subset/import_proj/` 建一个一次性迷你 Godot 工程（只含子集字体
     + 原 `.import` 的 `[params]`），用 `godot --headless --import` 让**真正的导入器**
     生成 `.fontdata`（压缩、参数、结构都和其它构建完全一致，不手写格式）；
  3. 备份原 `.godot/imported/<name>.fontdata`，把子集产物覆盖上去 → 导出 → 再还原。

`.godot/` 是纯缓存（已 gitignore），且源 `.ttf` 的 md5 没变，Godot 的导入扫描不会重导
（实测 `--import` 不会因为 dest 内容变了而重导）。还原由 `restore` 子命令完成，并在崩溃
后由下一次 `prepare` 自动补做（`pending_restore.json` 标记）。任何一步失败都会先还原
再退出，所以最坏情况是"这次 Web 包还是全字库"，而不是"桌面字体被裁了"。

字符集
------
源码扫描（.gd/.tscn/.tres/data/*.json|csv... 的非 ASCII + \\uXXXX 转义）
  ∪ ASCII 全集
  ∪ Unicode 标点/符号/全角/拉丁扩展等冗余区段
  ∪ EXTRA_SAFE_CHARS / EXTRA_SAFE_HANZI 白名单
  ∪ GB2312 一级汉字（3755 常用字，给玩家自己输入的文字兜底）
最后一项是必要的：主菜单的国名输入框（main_menu.gd %CountryEdit）和各处搜索框都是
LineEdit，玩家用 IME 打的字不可能出现在源码里；国名还会以手写体印在年度报告封面上，
漏字就是直接可见的方块。不想要这份保险就设 PK_WEB_FONT_SUBSET_NO_GB2312=1。

自检（宁可构建失败，也不发方块包）
----------------------------------
* 逐个字体比对子集前后 cmap：原字库能渲染的字符，子集里必须一个不少，否则 exit 1；
* 子集产物再让 Godot 自己 load 一遍，用 `Font.has_char()` 逐字复核（`--no-godot-probe` 关）；
* 构建后（`verify`）解析 pck 目录，确认打包的 `.fontdata` 确实是子集版本。

用法
----
    python tools/subset_fonts.py                    # = subset：只跑子集 + 自检 + 报告
    python tools/subset_fonts.py subset --force     # 忽略缓存重跑
    python tools/subset_fonts.py prepare --godot <godot.exe>   # 子集 + 注入缓存（Build-Web.cmd 用）
    python tools/subset_fonts.py verify --pck WebBuild/ProjectKeynes.pck
    python tools/subset_fonts.py restore            # 还原 .godot 里的原 fontsdata
    python tools/subset_fonts.py status             # 看是否还残留注入

依赖：`python -m pip install fonttools brotli`（woff2 输入/输出需要 brotli）。
回退：设置 `PK_WEB_SKIP_FONT_SUBSET=1` 跳过整件事（Build-Web.cmd 会按现状打包全字库）。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# 路径与常量
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PROJECT = REPO_ROOT / "Project" / "project-keynes"
DEFAULT_CACHE = REPO_ROOT / "tmp" / "web_font_subset"

# 子集算法/参数变了就 bump 这个版本号：缓存会整体失效，避免旧的（更小的）子集被复用。
SUBSET_VERSION = "v1"

FONT_SUFFIXES = {".ttf", ".otf", ".woff", ".woff2"}

# 扫描字符集的文本后缀。只扫文本，不碰 .res/.scn/.png/.ctex 等二进制资源。
TEXT_SUFFIXES = {
    ".gd",
    ".gdshader",
    ".gdshaderinc",
    ".tscn",
    ".tres",
    ".json",
    ".csv",
    ".cfg",
    ".txt",
}

# 这些目录不参与扫描：.godot 是导入缓存，tmp/test_output 是本地产物。
SCAN_SKIP_DIRS = {".godot", ".git", "tmp", "test_output", "_debug_atlas", "__pycache__", ".pytest_cache"}

# Web 预设 export_presets.cfg 的 exclude_filter（不在 pck 里的目录）。里面的字符只进
# 字符集（更保险），但"没有任何字体能渲染"的检查只对会真正打包的目录报警。
NOT_SHIPPED_PREFIXES = (
    "tests/",
    "tools/",
    "test_output/",
    "tmp/",
    "android/",
    "docs/",
    "addons/FmodGodot/",
    "assets/audio/banks/",
)

# ASCII 可打印全集（数字、拉丁、半角标点）。
ASCII_CHARS = "".join(chr(cp) for cp in range(0x20, 0x7F))

# 冗余白名单（第一层）：按 Unicode 区段整段保留。都是小字形（拉丁/标点/符号），
# 对体积影响只有几十 KB，但能挡住"运行期拼出来的符号/单位/箭头"这类漏字。
REDUNDANT_RANGES: tuple[tuple[int, int], ...] = (
    (0x00A0, 0x00FF),  # Latin-1 补充：¡ ¿ ° ± × ÷ é ß …
    (0x0100, 0x017F),  # Latin Extended-A
    (0x2000, 0x206F),  # 通用标点：‐ – — ― ‘ ’ “ ” … ‰ ′ ″ ※ ‼
    (0x2100, 0x214F),  # 字母式符号：℃ ℉ № ™ Ω ⅓
    (0x2190, 0x21FF),  # 箭头：← ↑ → ↓ ↔ ↕ ⇒ ⇧
    (0x2200, 0x22FF),  # 数学运算符：≠ ≤ ≥ ≈ ∞ ∑ √ ∫ ⊂ ⊗
    (0x2460, 0x24FF),  # 带圈数字：① ⑩ ⓵
    (0x2500, 0x257F),  # 制表符：─ │ ┌ ┐ └ ┘ ├ ┤ ┼
    (0x25A0, 0x25FF),  # 几何图形：■ □ ▲ ▼ ◆ ◇ ○ ● ◄ ►
    (0x2600, 0x26FF),  # 杂项符号：☀ ☁ ☂ ☼ ☾ ♀ ♂ ♠ ♥ ♦ ♣ ⚠ ⚙
    (0x3000, 0x303F),  # 中日韩标点：　、。〃〈〉《》「」『』【】〔〕〖〗
    (0xFF01, 0xFF5E),  # 全角 ASCII：！＂＃…～（全角数字/字母/标点）
    (0xFFE0, 0xFFE5),  # 全角符号：￠ ￡ ￢ ￣ ￥
)

# 冗余白名单（第二层）：游戏 UI 里常见、但可能出现在素材/将来文案里的零散字符。
# 想加字直接往下面加，不用改代码逻辑（重复字符无所谓）。
EXTRA_SAFE_CHARS = (
    # 中文常用标点 / 引号 / 破折号 / 省略号 / 间隔号
    "、。，．；：？！…‥·—–―＿～＃＆＊＠｜／＼＋－＝％"
    "「」『』（）〔〕【】〈〉《》〖〗〘〙〚〛"
    "“”‘’‛‟〝〞〟"
    # 货币 / 单位 / 数学 / 箭头 / 几何（游戏数值展示常用）
    "¥￥$€£¢₩₹₽₺₴₦฿"
    "°′″℃℉‰‱㎜㎝㎞㎎㎏㎡㎥㏄"
    "±×÷≈≠≡≤≥∞∑∏√∫∂∆∇∈∉∩∪⊂⊃⊆⊇⊕⊗⊥∥∠"
    "←↑→↓↔↕↖↗↘↙⇐⇒⇧⇩⇦⇨"
    "▲▼◀▶△▽◁▷◆◇○●◎■□▪▫★☆✦✧✓✔✕✖✗✘"
    # 杂项：勾选 / 警告 / 时间 / 播放控制 / 性别
    "⚠☀☁☂☃☼♀♂♠♥♦♣"
    "⏵⏸⏹⏺⏭⏮"
    # 带圈/括号数字（列表、朝代编号常用）
    "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳"
    "㈠㈡㈢㈣㈤㈥㈦㈧㈨㈩"
    "ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩⅪⅫ"
    # 计量/年代常见杂项
    "〇〡〢〣〤〥〦〧〨〩"
)

# 冗余白名单（第三层）：只放"运行期会拼出来、但源码里查不到"的汉字。
# 目前游戏文本全部来自 .gd/.tscn/.tres/data/*.json，扫描已经覆盖；留空即可。
EXTRA_SAFE_HANZI = ""

# 冗余白名单（第四层，默认开）：GB2312 一级汉字（3755 个常用字）。
# 这是给"玩家自己输入的文字"兜底的：主菜单的国名输入框（main_menu.gd 的 %CountryEdit）、
# 各处搜索框都是 LineEdit，玩家用 IME 打的字不可能出现在源码扫描里；而且国名会以
# 手写体出现在年度报告封面，漏字就是直接可见的方块。成本约 +5-6 MB pck。
# 关掉：set PK_WEB_FONT_SUBSET_NO_GB2312=1（或改这里为 False）。
INCLUDE_GB2312_LEVEL1 = True
_GB2312_LEVEL1_CACHE: str | None = None


def gb2312_level1() -> str:
    """GB2312 一级汉字（0xB0A1..0xD7F9，按拼音序的 3755 个常用字）。

    用 codec 现场枚举而不是把 3755 个字写死进源码：不依赖 Python 版本的字表文件，
    也不会因为手抄漏字。GB2312 一级 = 中国大陆"常用字"标准，覆盖现代汉语约 99% 的用字。
    """
    global _GB2312_LEVEL1_CACHE
    if _GB2312_LEVEL1_CACHE is None:
        chars = []
        for high in range(0xB0, 0xD8):
            for low in range(0xA1, 0xFF):
                try:
                    chars.append(bytes((high, low)).decode("gb2312"))
                except UnicodeDecodeError:
                    continue
        _GB2312_LEVEL1_CACHE = "".join(chars)
    return _GB2312_LEVEL1_CACHE

# 这些字体保持完整，不做子集化（按文件名匹配）。
#   fa-solid-900.woff2：图标字体的码位是 PUA（U+E000..），在源码里以数字/名称引用，
#   扫不到对应字符，裁掉就会丢图标。它只有 118 KB，不值得冒险。
KEEP_FULL_FONT_NAMES = {"fa-solid-900.woff2"}

# 附加保险：PUA 码位占比超过这个阈值的字体一律视为图标字体 → 保持完整。
KEEP_FULL_PUA_RATIO = 0.25

# 零宽 / 不可见字符：不是字形，扫描时直接剔掉（BOM、零宽空格、软连字符、变体选择符）。
INVISIBLE_CHARS = {"\ufeff", "\u200b", "\u200c", "\u200d", "\u2060", "\u00ad"}
INVISIBLE_CHARS.update(chr(cp) for cp in range(0xFE00, 0xFE10))  # VS1..VS16

# 已知"所有随包字体都没有、只能靠系统 fallback"的字符（桌面正常、web 上本来就是方块）。
# 这是**既有缺陷**，不是子集化引入的，所以不阻断构建，但每次都会在报告里列出位置。
# 新增字符如果不在这个名单里、又没有任何字体能渲染 → 构建直接失败，逼着先修。
#
#   ── 真的会渲染成方块（web 上，UI 文案）─────────────────────────────────────
#   ▴ U+25B4  scenes/ui/family/family_founding_dialog.tscn:91 "收起看图 ▴"
#             scripts/ui/components/family_founding_card.gd:460 展开/收起箭头
#             scripts/ui/components/dossier/overview_page.gd:110 "明细 ▴"
#   ▾ U+25BE  同上（收起态）+ scenes/ui/economy_dossier/overview_page.tscn:38 "明细 ▾"
#   ▸ U+25B8  scenes/ui/colonization_planner_panel.tscn:139/160 装饰箭头
#   ⏳⏸⏹⏺📸  scripts/ui/debug_console.gd 的 GM 录制按钮文案（只有 GM 面板看得到）
#
#   ── 只在注释 / print() 里，不会渲染 ────────────────────────────────────────
#   ⌈ ⌉ U+2308/2309  scripts/data/climate_profile.gd 注释里的取整记号
#   ► U+25BA  scripts/audio/game_audio_service.gd 注释里的 "──►"
#   ✅ U+2705  scripts/data_core/view_adapter.gd、weather_system.gd 注释 + bench print()
#   ✗ U+2717  scripts/simulation/climate/climate_math.gd 注释
#   ↟ U+219F  scripts/ui/icon_catalog.gd 的旧图标 key（"\u219f"），只做查表不做绘制
#   ☼ U+263C  同上（"\u263c"），只做查表不做绘制
KNOWN_UNCOVERED_CHARS = "▴▾▸⌈⌉►✅✗❌↟☼⏳⏸⏹⏺📸"

# 迷你工程里让 Godot 复核子集产物的探针脚本（临时写在缓存目录，不进仓库）。
GODOT_PROBE_SCRIPT = r"""extends SceneTree

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("PROBE_ERROR no manifest")
		quit(4)
		return
	var manifest_text := FileAccess.get_file_as_string(args[0])
	var manifest: Variant = JSON.parse_string(manifest_text)
	if typeof(manifest) != TYPE_DICTIONARY:
		print("PROBE_ERROR manifest parse failed: ", manifest_text.length())
		quit(5)
		return
	var checked := 0
	var missing_total := 0
	for item in manifest.get("fonts", []):
		var res_path: String = String(item.get("res_path", ""))
		var expect_path: String = String(item.get("expect_path", ""))
		var font := load(res_path) as Font
		if font == null:
			print("PROBE_ERROR cannot load ", res_path)
			missing_total += 1
			continue
		var expect := FileAccess.get_file_as_string(expect_path)
		var missing: Array[int] = []
		for i in expect.length():
			var cp := expect.unicode_at(i)
			checked += 1
			if not font.has_char(cp):
				missing.append(cp)
		missing_total += missing.size()
		print("PROBE_FONT ", res_path, " expect=", expect.length(), " missing=", missing.size(),
			" ", _fmt_codepoints(missing))
	print("PROBE_RESULT checked=", checked, " missing=", missing_total)
	quit(0 if missing_total == 0 else 3)


func _fmt_codepoints(cps: Array[int]) -> String:
	var out := ""
	var limit: int = mini(cps.size(), 40)
	for i in limit:
		out += "U+%04X " % cps[i]
	if cps.size() > limit:
		out += "..."
	return out
"""


# ---------------------------------------------------------------------------
# 输出工具（Windows 控制台是 GBK，打印符号/生僻字不能把构建搞崩）
# ---------------------------------------------------------------------------


def _reconfigure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="backslashreplace")
        except Exception:  # noqa: BLE001 - 老版本/被重定向时忽略
            pass


def log(msg: str = "") -> None:
    print(msg, flush=True)


def warn(msg: str) -> None:
    print("WARNING: " + msg, flush=True)


def die(msg: str, code: int = 1) -> "NoReturn":  # type: ignore[name-defined]
    print("=== ERROR: " + msg + " ===", flush=True)
    raise SystemExit(code)


def fmt_mb(num_bytes: float) -> str:
    return f"{num_bytes / (1024.0 * 1024.0):6.2f} MB"


def codepoints(text: str, limit: int = 60) -> str:
    """把缺字列表打印成 `U+25BE` 这种形式（控制台安全，且可直接复制）。"""
    items = [f"U+{ord(ch):04X}" for ch in text]
    if len(items) > limit:
        return " ".join(items[:limit]) + f" ... (+{len(items) - limit})"
    return " ".join(items)


# ---------------------------------------------------------------------------
# 数据结构
# ---------------------------------------------------------------------------


@dataclass
class FontEntry:
    """一个被导入的字体：源文件、`.import`、以及导入产物（`.fontdata`）的落点。"""

    src: Path  # 绝对路径：<project>/assets/fonts/...
    rel: str  # 相对 project 的 posix 路径
    import_file: Path
    params_block: str
    dest_res: str  # res://.godot/imported/<name>.fontdata
    dest: Path  # 绝对路径
    md5_file: Path
    keep_full: bool = False
    keep_full_reason: str = ""


@dataclass
class FontPlan:
    entry: FontEntry
    subset_path: Path
    subset_flavor: str | None
    charset: str  # 该字体需要保留的字符（∩ 原 cmap）
    orig_cmap_size: int
    subset_cmap_size: int = 0
    lost: str = ""  # 子集里丢掉的字符（应为空）
    original_bytes: int = 0
    subset_bytes: int = 0
    fontdata_original: int = 0
    fontdata_subset: int = 0


@dataclass
class ScanResult:
    chars: set[str] = field(default_factory=set)
    shipped: set[str] = field(default_factory=set)
    samples: dict[str, tuple[str, int]] = field(default_factory=dict)
    files: int = 0
    bytes_read: int = 0


# ---------------------------------------------------------------------------
# 1. 扫描字符集
# ---------------------------------------------------------------------------

_ESCAPE_RE = re.compile(r"\\u([0-9a-fA-F]{4})|\\U([0-9a-fA-F]{8})")


def is_shipped(rel: str) -> bool:
    return not rel.startswith(NOT_SHIPPED_PREFIXES)


def scan_project_text(project: Path) -> ScanResult:
    """把 res:// 下所有文本里的非 ASCII 字符扫出来（+ 源码里的 \\uXXXX 转义）。"""
    result = ScanResult()
    for dirpath, dirnames, filenames in os.walk(project):
        dirnames[:] = [d for d in dirnames if d not in SCAN_SKIP_DIRS]
        for name in filenames:
            suffix = os.path.splitext(name)[1].lower()
            if suffix not in TEXT_SUFFIXES:
                continue
            path = Path(dirpath) / name
            try:
                if path.stat().st_size > 16 * 1024 * 1024:
                    continue
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            rel = path.relative_to(project).as_posix()
            shipped = is_shipped(rel)
            result.files += 1
            result.bytes_read += len(text)

            for lineno, line in enumerate(text.splitlines(), 1):
                if line.isascii():
                    continue
                for ch in set(line):
                    if ord(ch) <= 0x7F or ch in INVISIBLE_CHARS:
                        continue
                    result.chars.add(ch)
                    if shipped:
                        result.shipped.add(ch)
                    if ch not in result.samples:
                        result.samples[ch] = (rel, lineno)

            # GDScript / JSON 里的 \uXXXX 写法：源码里看不到真实字符，但运行期会渲染。
            if "\\u" in text or "\\U" in text:
                for match in _ESCAPE_RE.finditer(text):
                    cp = int(match.group(1) or match.group(2), 16)
                    if cp <= 0x1F:
                        continue
                    ch = chr(cp)
                    if ch in INVISIBLE_CHARS:
                        continue
                    result.chars.add(ch)
                    if shipped:
                        result.shipped.add(ch)
                    if ch not in result.samples:
                        result.samples[ch] = (rel, text.count("\n", 0, match.start()) + 1)
    return result


def build_charset(scan: ScanResult, extra_chars: str) -> tuple[set[str], dict[str, int]]:
    chars: set[str] = set(scan.chars)
    scanned = len(chars)

    chars.update(ASCII_CHARS)
    ascii_added = len(chars) - scanned

    before_redundant = len(chars)
    for lo, hi in REDUNDANT_RANGES:
        chars.update(chr(cp) for cp in range(lo, hi + 1))
    redundant_added = len(chars) - before_redundant

    before_extra = len(chars)
    chars.update(EXTRA_SAFE_CHARS)
    chars.update(EXTRA_SAFE_HANZI)
    chars.update(extra_chars)
    extra_added = len(chars) - before_extra

    before_gb = len(chars)
    if INCLUDE_GB2312_LEVEL1 and not os.environ.get("PK_WEB_FONT_SUBSET_NO_GB2312"):
        chars.update(gb2312_level1())
    gb2312_added = len(chars) - before_gb

    stats = {
        "scanned_distinct": scanned,
        "ascii_added": ascii_added,
        "redundant_added": redundant_added,
        "extra_added": extra_added,
        "gb2312_added": gb2312_added,
        "total": len(chars),
        "scanned_shipped_distinct": len(scan.shipped),
    }
    return chars, stats


# ---------------------------------------------------------------------------
# 2. 字体发现 / 子集化
# ---------------------------------------------------------------------------


def read_font_params(import_text: str) -> str:
    marker = "[params]"
    idx = import_text.find(marker)
    if idx < 0:
        return ""
    return import_text[idx + len(marker) :].strip("\r\n")


def discover_fonts(project: Path) -> list[FontEntry]:
    """按 `.import` 找出所有 `font_data_dynamic` 导入的字体（= pck 里真正会出现的字体）。"""
    fonts_dir = project / "assets" / "fonts"
    if not fonts_dir.is_dir():
        die(f"font directory not found: {fonts_dir}")

    entries: list[FontEntry] = []
    for dirpath, dirnames, filenames in os.walk(fonts_dir):
        dirnames[:] = [d for d in dirnames if d not in SCAN_SKIP_DIRS]
        for name in filenames:
            if os.path.splitext(name)[1].lower() not in FONT_SUFFIXES:
                continue
            src = Path(dirpath) / name
            import_file = Path(str(src) + ".import")
            if not import_file.is_file():
                warn(f"font without .import, skipped: {src}")
                continue
            text = import_file.read_text(encoding="utf-8", errors="replace")
            if 'importer="font_data_dynamic"' not in text:
                warn(f"font importer is not font_data_dynamic, skipped: {src}")
                continue
            match = re.search(r'^path="res://([^"]+)"', text, re.MULTILINE)
            if not match:
                warn(f"font .import has no [remap] path, skipped: {src}")
                continue
            dest_res = "res://" + match.group(1)
            dest = project / match.group(1)
            entries.append(
                FontEntry(
                    src=src,
                    rel=src.relative_to(project).as_posix(),
                    import_file=import_file,
                    params_block=read_font_params(text),
                    dest_res=dest_res,
                    dest=dest,
                    md5_file=dest.with_suffix(".md5"),
                )
            )
    entries.sort(key=lambda e: e.rel)
    return entries


def load_cmap(path: Path) -> set[int]:
    from fontTools.ttLib import TTFont

    font = TTFont(str(path), lazy=True, fontNumber=0)
    try:
        cmap: set[int] = set()
        for table in font["cmap"].tables:
            if table.isUnicode():
                cmap.update(table.cmap.keys())
        return cmap
    finally:
        font.close()


def decide_keep_full(entry: FontEntry) -> None:
    if entry.src.name in KEEP_FULL_FONT_NAMES:
        entry.keep_full = True
        entry.keep_full_reason = "icon font (PUA codepoints referenced numerically)"
        return
    try:
        cmap = load_cmap(entry.src)
    except Exception:  # noqa: BLE001
        return
    if not cmap:
        return
    pua = sum(1 for cp in cmap if 0xE000 <= cp <= 0xF8FF)
    if pua / len(cmap) >= KEEP_FULL_PUA_RATIO:
        entry.keep_full = True
        entry.keep_full_reason = f"icon font ({pua}/{len(cmap)} PUA codepoints)"


def subset_options(flavor: str | None):
    from fontTools import subset

    options = subset.Options()
    options.layout_features = ["*"]  # 保留 CJK 的 vert/liga/kern，渲染才和全字库一致
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.recommended_glyphs = True
    options.hinting = True  # 小字号 UI 文本依赖 hinting，不要为了几 KB 关掉
    options.canonical_order = True  # 输出稳定，缓存/比对友好
    options.flavor = flavor
    return options


def font_cache_fingerprint(src: Path, charset: str, flavor: str | None) -> str:
    digest = hashlib.sha256()
    digest.update(SUBSET_VERSION.encode())
    digest.update(b"\0")
    digest.update((flavor or "").encode())
    digest.update(b"\0")
    digest.update(charset.encode("utf-8"))
    digest.update(b"\0")
    with open(src, "rb") as handle:
        while True:
            chunk = handle.read(1 << 20)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def run_subset(entry: FontEntry, charset: str, out_path: Path, flavor: str | None) -> None:
    from fontTools.ttLib import TTFont

    out_path.parent.mkdir(parents=True, exist_ok=True)
    font = TTFont(str(entry.src), fontNumber=0)
    try:
        options = subset_options(flavor)
        subsetter = __import__("fontTools.subset", fromlist=["Subsetter"]).Subsetter(options=options)
        subsetter.populate(text=charset)
        subsetter.subset(font)
        font.save(str(out_path))
    finally:
        font.close()


def build_font_plans(project: Path, cache: Path, charset: set[str], force: bool) -> list[FontPlan]:
    fonts = discover_fonts(project)
    if not fonts:
        die("no importable fonts found under assets/fonts")

    plans: list[FontPlan] = []
    charset_text = "".join(sorted(charset))
    log(f"[subset] {len(fonts)} fonts, {len(charset)} codepoints in charset")

    for entry in fonts:
        decide_keep_full(entry)
        flavor = {".woff2": "woff2", ".woff": "woff"}.get(entry.src.suffix.lower())
        out_path = cache / "fonts" / entry.rel
        plan = FontPlan(
            entry=entry,
            subset_path=out_path,
            subset_flavor=flavor,
            charset="",
            orig_cmap_size=0,
            original_bytes=entry.src.stat().st_size,
        )

        try:
            orig_cmap = load_cmap(entry.src)
        except Exception as exc:  # noqa: BLE001
            die(f"cannot read cmap of {entry.rel}: {exc}")
        plan.orig_cmap_size = len(orig_cmap)
        plan.charset = "".join(ch for ch in sorted(charset) if ord(ch) in orig_cmap)

        if entry.keep_full:
            plan.charset = ""  # 留空 = 不裁
            plan.subset_bytes = plan.original_bytes
            plan.subset_cmap_size = plan.orig_cmap_size
            plan.subset_path = entry.src
            log(f"  {entry.rel}: keep full ({entry.keep_full_reason})")
            plans.append(plan)
            continue

        fingerprint = font_cache_fingerprint(entry.src, plan.charset, flavor)
        meta_path = cache / "fonts" / (entry.rel + ".json")
        cached = False
        if not force and meta_path.is_file() and out_path.is_file():
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                cached = meta.get("fingerprint") == fingerprint and meta.get("size") == out_path.stat().st_size
            except (OSError, json.JSONDecodeError):
                cached = False

        started = time.time()
        if cached:
            log(f"  {entry.rel}: cache hit ({len(plan.charset)} chars)")
        else:
            log(f"  {entry.rel}: subsetting {len(plan.charset)} chars ...")
            try:
                run_subset(entry, plan.charset, out_path, flavor)
            except Exception as exc:  # noqa: BLE001
                die(f"subsetting failed for {entry.rel}: {exc}")
            meta_path.parent.mkdir(parents=True, exist_ok=True)
            meta_path.write_text(
                json.dumps(
                    {
                        "fingerprint": fingerprint,
                        "size": out_path.stat().st_size,
                        "chars": len(plan.charset),
                        "source": entry.rel,
                    },
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            log(f"  {entry.rel}: done in {time.time() - started:.1f}s")

        plan.subset_bytes = out_path.stat().st_size
        try:
            subset_cmap = load_cmap(out_path)
        except Exception as exc:  # noqa: BLE001
            die(f"cannot read cmap of subset {entry.rel}: {exc}")
        plan.subset_cmap_size = len(subset_cmap)

        lost = "".join(ch for ch in plan.charset if ord(ch) not in subset_cmap)
        plan.lost = lost
        plans.append(plan)

    return plans


def report_table(plans: list[FontPlan], scan: ScanResult) -> str:
    """打印每个字体的：保留字符数、体积、对"游戏实际用到的字符"的覆盖率。"""
    used = scan.chars
    used_total = max(1, len(used))
    lines: list[str] = []
    width = max([len(plan.entry.rel) for plan in plans] + [30])
    lines.append("")
    lines.append(f"  {'font':<{width}}  {'kept':>5}  {'orig cmap':>9}  {'ttf orig -> subset':<22}  used%")
    lines.append(f"  {'-' * width}  {'-' * 5}  {'-' * 9}  {'-' * 22}  -----")
    total_orig = 0
    total_sub = 0
    for plan in plans:
        entry = plan.entry
        total_orig += plan.original_bytes
        total_sub += plan.subset_bytes
        if entry.keep_full:
            kept = plan.orig_cmap_size
            used_pct = 100.0
            note = "  (keep full: " + entry.keep_full_reason + ")"
        else:
            kept = len(plan.charset)
            used_pct = 100.0 * len(used & set(plan.charset)) / used_total
            note = ""
        sizes = f"{fmt_mb(plan.original_bytes)} -> {fmt_mb(plan.subset_bytes)}"
        lines.append(
            f"  {entry.rel:<{width}}  {kept:>5}  {plan.orig_cmap_size:>9}  {sizes:<22}  {used_pct:>5.2f}%{note}"
        )
    lines.append(f"  {'-' * width}  {'-' * 5}  {'-' * 9}  {'-' * 22}  -----")
    total_sizes = f"{fmt_mb(total_orig)} -> {fmt_mb(total_sub)}"
    lines.append(
        f"  {'TOTAL':<{width}}  {'':>5}  {'':>9}  {total_sizes:<22}  "
        f"{100.0 * (1 - total_sub / total_orig):>4.1f}% smaller"
    )
    return "\n".join(lines)


def check_plans(plans: list[FontPlan], charset: set[str], scan: ScanResult, strict: bool) -> tuple[int, str]:
    """漏字自检。返回 (致命缺失数, 报告文本)。"""
    lines: list[str] = []
    used = scan.chars

    lost_total = 0
    for plan in plans:
        if plan.lost:
            lost_total += len(plan.lost)
            lines.append(f"  [LOST] {plan.entry.rel}: {len(plan.lost)} chars dropped by subsetting")
            lines.append(f"         {codepoints(plan.lost)}")

    # "正文能力" = 任一非图标字体能渲染的字符（图标字体只覆盖 PUA/ASCII，不算）。
    covered_union: set[str] = set()
    for plan in plans:
        if plan.entry.keep_full:
            continue
        covered_union.update(plan.charset)

    # 只对"源码里真的出现过"的字符报警；纯冗余白名单里的字符（拉丁扩展之类）字体没有也正常。
    uncovered = sorted(ch for ch in used if ch not in covered_union)
    missing_in_fonts = uncovered
    known = set(KNOWN_UNCOVERED_CHARS)
    # 只有会真正打包的目录（scan.shipped）里的字符才算"会渲染"；tests/tools 里的 emoji 无所谓。
    shipped_missing = [ch for ch in missing_in_fonts if ch in scan.shipped]
    tests_only = [ch for ch in missing_in_fonts if ch not in scan.shipped]
    fatal_chars = shipped_missing if strict else [ch for ch in shipped_missing if ch not in known]

    lines.append("")
    lines.append(
        f"  charset: {len(used)} chars used by source text + {len(charset) - len(used)} redundancy/safety-only"
        f" = {len(charset)}; packaged text fonts cover {len(used) - len(missing_in_fonts)}/{len(used)} of the used set"
    )
    if missing_in_fonts:
        lines.append(
            f"  {len(missing_in_fonts)} used char(s) that no packaged font can render"
            f" ({len(shipped_missing)} in web-shipped files, {len(tests_only)} only under tests/tools):"
        )
        for ch in shipped_missing:
            sample = scan.samples.get(ch)
            where = f"{sample[0]}:{sample[1]}" if sample else "(only via \\uXXXX escape)"
            tag = "KNOWN" if ch in known else "NEW"
            lines.append(f"    [{tag}] U+{ord(ch):04X}  {where}")
        if tests_only:
            lines.append("    [tests-only] " + codepoints("".join(tests_only), limit=80))
    if fatal_chars:
        lines.append("")
        lines.append(f"  [FATAL] {len(fatal_chars)} char(s) appear in shipped files but no font can render them:")
        lines.append(f"          {codepoints(''.join(fatal_chars), limit=120)}")
        lines.append("          -> add a font that covers them, or add them to KNOWN_UNCOVERED_CHARS with a comment")

    text = "\n".join(lines)
    return lost_total + len(fatal_chars), text


# ---------------------------------------------------------------------------
# 3. 用 Godot 导入器生成 .fontdata（迷你工程，不碰主工程）
# ---------------------------------------------------------------------------


def find_godot(explicit: str | None) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit))
    env = os.environ.get("GODOT_BIN")
    if env:
        candidates.append(Path(env))
    candidates.extend(
        [
            REPO_ROOT.parent.parent / "Godot_v4.6.2-stable_win64.exe" / "Godot_v4.6.2-stable_win64.exe",
            REPO_ROOT.parent.parent / "Godot_v4.6.2-stable_win64.exe",
            REPO_ROOT.parent / "Godot_v4.6.2-stable_win64.exe",
            REPO_ROOT / "Godot_v4.6.2-stable_win64.exe",
        ]
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    which = shutil.which("godot") or shutil.which("godot4")
    if which:
        return Path(which).resolve()
    die(
        "Godot editor binary not found; pass --godot <path> or set GODOT_BIN "
        "(or export with PK_WEB_SKIP_FONT_SUBSET=1 to skip font subsetting)"
    )


def run_godot(args: list[str], log_path: Path, timeout: int = 1800) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "w", encoding="utf-8", errors="replace") as handle:
        handle.write("$ " + " ".join(args) + "\n\n")
        handle.flush()
        proc = subprocess.run(args, stdout=handle, stderr=subprocess.STDOUT, timeout=timeout)
    return proc.returncode


def import_subsets_with_godot(
    cache: Path, godot: Path, plans: list[FontPlan], probe: bool
) -> dict[str, Path]:
    """在迷你工程里让 Godot 导入子集字体；返回 {font rel: 生成的 .fontdata 路径}。"""
    stage = cache / "import_proj"
    if stage.exists():
        shutil.rmtree(stage, ignore_errors=True)
    (stage / "fonts").mkdir(parents=True, exist_ok=True)
    (stage / "project.godot").write_text(
        'config_version=5\n\n[application]\n\nconfig/name="PKWebFontSubsetImport"\n', encoding="utf-8"
    )

    staged: list[tuple[FontPlan, str, str]] = []
    for index, plan in enumerate(plans):
        if plan.entry.keep_full:
            continue
        rel_under_fonts = plan.entry.rel[len("assets/fonts/") :]
        dst = stage / "fonts" / rel_under_fonts
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(plan.subset_path, dst)
        res_source = "res://fonts/" + rel_under_fonts
        dest_res = f"res://.godot/imported/{dst.name}-subset.fontdata"
        params = plan.entry.params_block or "compress=true\n"
        (stage / "fonts" / (rel_under_fonts + ".import")).write_text(
            '[remap]\n\nimporter="font_data_dynamic"\ntype="FontFile"\n'
            f'path="{dest_res}"\n\n[deps]\n\nsource_file="{res_source}"\n'
            f'dest_files=["{dest_res}"]\n\n[params]\n\n{params}\n',
            encoding="utf-8",
        )
        staged.append((plan, res_source, rel_under_fonts))

    log(f"[import] godot --headless --import on {len(staged)} subset fonts ...")
    started = time.time()
    rc = run_godot([str(godot), "--headless", "--path", str(stage), "--import"], cache / "godot_import.log")
    if rc != 0:
        die(f"godot --import failed (rc={rc}); see {cache / 'godot_import.log'}")
    log(f"[import] ok in {time.time() - started:.1f}s")

    staged_fontdata: dict[str, Path] = {}
    for plan, _res_source, rel_under_fonts in staged:
        import_file = stage / "fonts" / (rel_under_fonts + ".import")
        text = import_file.read_text(encoding="utf-8", errors="replace")
        match = re.search(r'^path="res://([^"]+)"', text, re.MULTILINE)
        if not match:
            die(f"godot did not write a [remap] path for {rel_under_fonts}")
        produced = stage / match.group(1)
        if not produced.is_file():
            die(f"godot import produced no .fontdata for {rel_under_fonts}")
        staged_fontdata[plan.entry.rel] = produced
        plan.fontdata_subset = produced.stat().st_size

    if probe:
        probe_subsets_with_godot(cache, godot, stage, plans, staged_fontdata)
    return staged_fontdata


def probe_subsets_with_godot(
    cache: Path, godot: Path, stage: Path, plans: list[FontPlan], staged_fontdata: dict[str, Path]
) -> None:
    """让 Godot 自己 load 一遍子集 .fontdata，用 Font.has_char() 复核（比 fontTools 更接近真机）。"""
    expect_dir = stage / "expect"
    expect_dir.mkdir(exist_ok=True)
    manifest_fonts = []
    for index, plan in enumerate(plans):
        produced = staged_fontdata.get(plan.entry.rel)
        if produced is None:
            continue
        expect_path = expect_dir / f"{index:02d}.txt"
        expect_path.write_text(plan.charset, encoding="utf-8")
        manifest_fonts.append(
            {
                "res_path": "res://" + produced.relative_to(stage).as_posix(),
                # FileAccess 在 web/桌面都能读绝对路径；这里用正斜杠最稳。
                "expect_path": expect_path.as_posix(),
            }
        )
    manifest = stage / "probe_manifest.json"
    manifest.write_text(json.dumps({"fonts": manifest_fonts}, ensure_ascii=False), encoding="utf-8")
    (stage / "probe.gd").write_text(GODOT_PROBE_SCRIPT, encoding="utf-8")

    log("[probe] font.has_char() spot check on the generated .fontdata ...")
    rc = run_godot(
        [str(godot), "--headless", "--path", str(stage), "--script", "res://probe.gd", "--", str(manifest)],
        cache / "godot_probe.log",
        timeout=600,
    )
    text = (cache / "godot_probe.log").read_text(encoding="utf-8", errors="replace")
    result_line = next((line for line in text.splitlines() if line.startswith("PROBE_RESULT")), "")
    if not result_line:
        warn(f"godot font probe did not report a result (rc={rc}); see {cache / 'godot_probe.log'}")
        return
    log("  " + result_line)
    if "missing=0" not in result_line:
        for line in text.splitlines():
            if line.startswith("PROBE_FONT") or line.startswith("PROBE_ERROR"):
                log("  " + line)
        die(f"godot reports chars missing after subsetting; see {cache / 'godot_probe.log'}")


# ---------------------------------------------------------------------------
# 4. 注入 / 还原 .godot 导入缓存
# ---------------------------------------------------------------------------

MARKER_NAME = "pending_restore.json"
INJECTED_NAME = "injected.json"


def cache_manifest(cache: Path) -> Path:
    return cache / MARKER_NAME


def rewrite_md5_dest(md5_file: Path, new_dest_md5: str) -> None:
    """把 .md5 里的 dest_md5 换成注入产物的哈希（4.6 不校验它，但保持一致更安全）。"""
    try:
        text = md5_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return
    if re.search(r'^dest_md5="[0-9a-f]*"$', text, re.MULTILINE):
        text = re.sub(r'^dest_md5="[0-9a-f]*"$', f'dest_md5="{new_dest_md5}"', text, flags=re.MULTILINE)
    else:
        text = text.rstrip("\r\n") + f'\ndest_md5="{new_dest_md5}"\n'
    md5_file.write_text(text, encoding="utf-8")


def inject_fontdata(
    cache: Path, project: Path, plans: list[FontPlan], staged_fontdata: dict[str, Path]
) -> dict:
    backup_dir = cache / "backup"
    if backup_dir.exists():
        shutil.rmtree(backup_dir, ignore_errors=True)
    backup_dir.mkdir(parents=True, exist_ok=True)

    files = []
    for plan in plans:
        produced = staged_fontdata.get(plan.entry.rel)
        if produced is None:
            plan.fontdata_original = plan.entry.dest.stat().st_size if plan.entry.dest.is_file() else 0
            plan.fontdata_subset = plan.fontdata_original
            continue
        dest = plan.entry.dest
        plan.fontdata_original = dest.stat().st_size if dest.is_file() else 0
        if not dest.is_file():
            die(f"missing original fontdata: {dest}")
        backup_fontdata = backup_dir / dest.name
        shutil.copy2(dest, backup_fontdata)
        backup_md5 = None
        if plan.entry.md5_file.is_file():
            backup_md5 = backup_dir / plan.entry.md5_file.name
            shutil.copy2(plan.entry.md5_file, backup_md5)

        shutil.copy2(produced, dest)
        injected_md5 = hashlib.md5(dest.read_bytes()).hexdigest()
        rewrite_md5_dest(plan.entry.md5_file, injected_md5)
        keep = cache / "fontdata" / dest.name
        keep.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(dest, keep)
        files.append(
            {
                "dest": dest.relative_to(REPO_ROOT).as_posix(),
                "backup": backup_fontdata.relative_to(REPO_ROOT).as_posix(),
                "md5_dest": plan.entry.md5_file.relative_to(REPO_ROOT).as_posix(),
                "md5_backup": backup_md5.relative_to(REPO_ROOT).as_posix() if backup_md5 else "",
                "original_size": plan.fontdata_original,
                "injected_size": plan.fontdata_subset,
                "injected_md5": injected_md5,
                "font": plan.entry.rel,
            }
        )

    payload = {
        "version": 1,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "project": str(project),
        "files": files,
    }
    cache.mkdir(parents=True, exist_ok=True)
    cache_manifest(cache).write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    (cache / INJECTED_NAME).write_text(
        json.dumps(
            {
                "fonts": [
                    {
                        "font": item["font"],
                        "dest": item["dest"],
                        "original_size": item["original_size"],
                        "injected_size": item["injected_size"],
                        "injected_md5": item["injected_md5"],
                    }
                    for item in files
                ],
                "total_original": sum(item["original_size"] for item in files),
                "total_injected": sum(item["injected_size"] for item in files),
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )
    return payload


def restore_fontdata(cache: Path, quiet: bool = False) -> int:
    marker = cache_manifest(cache)
    if not marker.is_file():
        if not quiet:
            log("[restore] nothing to restore")
        return 0
    payload = json.loads(marker.read_text(encoding="utf-8"))
    restored = 0
    problems = 0
    for item in payload.get("files", []):
        dest = REPO_ROOT / item["dest"]
        backup = REPO_ROOT / item["backup"]
        if not backup.is_file():
            warn(f"backup missing for {item['dest']}; leaving the injected file in place")
            problems += 1
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(backup, dest)
        restored += 1
        md5_backup = item.get("md5_backup")
        if md5_backup:
            md5_src = REPO_ROOT / md5_backup
            if md5_src.is_file():
                shutil.copy2(md5_src, REPO_ROOT / item["md5_dest"])
    marker.unlink()
    stage = cache / "import_proj"
    if stage.exists():
        shutil.rmtree(stage, ignore_errors=True)
    if not quiet:
        log(f"[restore] restored {restored} .fontdata file(s); backup kept in {cache / 'backup'}")
    return 0 if problems == 0 else 1


# ---------------------------------------------------------------------------
# 5. 导出后校验 pck
# ---------------------------------------------------------------------------


def parse_pck(path: Path) -> list[tuple[str, int, str]] | None:
    """解析 Godot 4.4+ 的 pck 目录表（pack_version 3：目录偏移在 header offset 32）。

    返回 [(path, size, md5_hex)]；格式不认识时返回 None（verify 会跳过而不是误报）。
    """
    try:
        with open(path, "rb") as handle:
            header = handle.read(112)
            if len(header) < 112 or header[:4] != b"GDPC":
                return None
            pack_version = struct.unpack_from("<I", header, 4)[0]
            if pack_version < 3:
                return None
            dir_offset = struct.unpack_from("<Q", header, 32)[0]
            handle.seek(dir_offset)
            directory = handle.read()
    except OSError:
        return None

    try:
        count = struct.unpack_from("<I", directory, 0)[0]
        off = 4
        entries: list[tuple[str, int, str]] = []
        for _ in range(count):
            name_len = struct.unpack_from("<I", directory, off)[0]
            off += 4
            raw = directory[off : off + name_len]
            off += name_len
            name = raw.split(b"\x00")[0].decode("utf-8", "replace")
            _file_offset, file_size = struct.unpack_from("<QQ", directory, off)
            off += 16
            file_md5 = directory[off : off + 16].hex()
            off += 16
            off += 4  # flags
            entries.append((name, file_size, file_md5))
        return entries
    except struct.error:
        return None


def verify_pck(cache: Path, pck: Path) -> int:
    injected_path = cache / INJECTED_NAME
    if not injected_path.is_file():
        warn(f"{injected_path} not found; skipping pck check (run `prepare` first)")
        return 0
    injected = json.loads(injected_path.read_text(encoding="utf-8"))
    expected = {Path(item["dest"]).name: item for item in injected["fonts"]}
    expected_total = injected["total_injected"]

    entries = parse_pck(pck)
    if entries is None:
        warn("this pck uses an unknown pack format; skipping font verification")
        return 0

    fontdata = {Path(name).name: (size, md5) for name, size, md5 in entries if name.endswith(".fontdata")}
    log("")
    packed_fontdata_total = sum(size for size, _md5 in fontdata.values())
    log(
        f"[verify] {pck.name}: {fmt_mb(pck.stat().st_size)} total,"
        f" {fmt_mb(packed_fontdata_total)} of .fontdata"
    )
    problems = 0
    injected_fontdata = cache / "fontdata"
    for name, item in sorted(expected.items()):
        packed = fontdata.get(name)
        if packed is None:
            warn(f"{name}: not found in pck")
            problems += 1
            continue
        size, packed_md5 = packed
        expected_md5 = item.get("injected_md5", "")
        source = injected_fontdata / name
        if not expected_md5 and source.is_file():
            expected_md5 = hashlib.md5(source.read_bytes()).hexdigest()
        if expected_md5 and packed_md5 != expected_md5:
            warn(f"{name}: pck md5 {packed_md5} != subset md5 {expected_md5} (the full font is still packed)")
            problems += 1
        elif abs(size - item["injected_size"]) > max(64, item["injected_size"] // 100):
            warn(f"{name}: pck has {size} bytes, expected subset {item['injected_size']} (full original was {item['original_size']})")
            problems += 1
        else:
            log(f"  ok {name:<60} {size:>10} bytes (was {item['original_size']})")

    total = sum(size for size, _md5 in fontdata.values())
    if total > expected_total * 1.25 + 1024 * 1024:
        warn(f"pck fontdata total {fmt_mb(total)} is far above the subset total {fmt_mb(expected_total)}")
        problems += 1

    # 不依赖"上一次构建的 pck"当 baseline（很可能是被中断的半截文件）：
    # 直接用本次 pck + 字体原体积与子集体积之差，反推"如果不子集化会有多大"。
    pck_bytes = pck.stat().st_size
    full_equiv = pck_bytes + (injected["total_original"] - injected["total_injected"])
    saved = full_equiv - pck_bytes
    log(
        f"[verify] pck {fmt_mb(pck_bytes)}; with the original full fonts it would be"
        f" {fmt_mb(full_equiv)} (saved {saved / (1024.0 * 1024.0):.1f} MB)"
    )
    (cache / "baseline.json").write_text(
        json.dumps(
            {
                "pck": pck.name,
                "pck_bytes": pck_bytes,
                "full_font_equivalent_bytes": full_equiv,
                "fontdata_saved_bytes": saved,
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )

    if problems:
        warn(f"pck font verification failed with {problems} problem(s)")
        return 1
    log("[verify] ok: the pck ships the subset fonts")
    return 0


# ---------------------------------------------------------------------------
# 6. 子命令
# ---------------------------------------------------------------------------


def acquire_lock(cache: Path):
    cache.mkdir(parents=True, exist_ok=True)
    lock = cache / ".lock"
    if lock.exists():
        age = time.time() - lock.stat().st_mtime
        if age > 3600:
            warn(f"stale lock {lock} ({age / 60:.0f} min old); removing")
            lock.unlink(missing_ok=True)
        else:
            die(f"another subset_fonts.py run holds {lock}; wait for it or delete the lock")
    lock.write_text(str(os.getpid()), encoding="utf-8")
    return lock


def load_extra_chars(cache: Path) -> str:
    extra = os.environ.get("PK_WEB_FONT_SUBSET_EXTRA_CHARS", "")
    extra_file = cache / "extra_chars.txt"
    if extra_file.is_file():
        text = extra_file.read_text(encoding="utf-8", errors="replace")
        extra += "".join(ch for ch in text if ch not in "\r\n")
    return extra


def collect(cache: Path, project: Path) -> tuple[ScanResult, set[str]]:
    log(f"[scan] {project}")
    started = time.time()
    scan = scan_project_text(project)
    extra = load_extra_chars(cache)
    charset, stats = build_charset(scan, extra)
    log(
        f"[scan] {scan.files} files / {scan.bytes_read / 1e6:.1f}M chars; distinct codepoints:"
        f" scanned={stats['scanned_distinct']} +ascii={stats['ascii_added']}"
        f" +redundant={stats['redundant_added']} +extra={stats['extra_added']}"
        f" +gb2312={stats['gb2312_added']}"
        f" => {stats['total']} ({time.time() - started:.1f}s)"
    )
    return scan, charset


def run_subset_stage(
    args: argparse.Namespace, cache: Path, project: Path, quiet: bool = False
) -> tuple[ScanResult, set[str], list[FontPlan], int]:
    """扫描 + 子集化 + 自检 + 写报告。返回 (scan, charset, plans, 致命缺失数)。"""
    ensure_fonttools()
    scan, charset = collect(cache, project)
    plans = build_font_plans(project, cache, charset, args.force)
    missing, check_text = check_plans(plans, charset, scan, args.strict)
    total_orig = sum(plan.original_bytes for plan in plans)
    total_sub = sum(plan.subset_bytes for plan in plans)
    retained = sum(len(plan.charset) for plan in plans)
    if not quiet:
        log(report_table(plans, scan))
        log(check_text)
        log("")
        log(
            f"[result] fonts {total_orig / 1e6:.2f} MB -> {total_sub / 1e6:.2f} MB"
            f" ({100.0 * (1 - total_sub / total_orig):.1f}% smaller); retained {retained} glyph-characters"
        )
    write_report(cache, scan, charset, plans)
    return scan, charset, plans, missing


def cmd_subset(args: argparse.Namespace) -> int:
    cache = Path(args.cache).resolve()
    project = Path(args.project).resolve()
    if os.environ.get("PK_WEB_SKIP_FONT_SUBSET") and not args.force:
        log("[subset] PK_WEB_SKIP_FONT_SUBSET is set -> skipped (full fonts will be exported)")
        return 0

    lock = acquire_lock(cache)
    try:
        if cache_manifest(cache).is_file():
            warn("found a pending restore marker from an earlier run; restoring .godot first")
            restore_fontdata(cache)
        _scan, _charset, _plans, missing = run_subset_stage(args, cache, project)
        if missing:
            die(
                "font subsetting self-check FAILED: "
                f"{missing} missing char(s) (see the [LOST]/[NEW] lines above)",
                code=1,
            )
        log("[result] self-check ok: every char the original fonts could render survived subsetting")
        return 0
    finally:
        lock.unlink(missing_ok=True)


def ensure_fonttools() -> None:
    try:
        import brotli  # noqa: F401
        import fontTools  # noqa: F401
    except ImportError as exc:
        die(
            "web font subsetting needs fonttools + brotli, but "
            f"`import {exc.name}` failed.\n"
            "    Install them, then retry:\n"
            "        python -m pip install fonttools brotli\n"
            "    Or export the web package without subsetting (old 282 MB behaviour):\n"
            "        set PK_WEB_SKIP_FONT_SUBSET=1 && Build-Web.cmd",
            code=1,
        )


def write_report(cache: Path, scan: ScanResult, charset: set[str], plans: list[FontPlan]) -> None:
    cache.mkdir(parents=True, exist_ok=True)
    lines = [
        "Project.Keynes web font subsetting report",
        "generated: " + time.strftime("%Y-%m-%d %H:%M:%S"),
        f"charset: {len(charset)} codepoints ({len(scan.shipped)} appear in files shipped to web)",
        "",
        report_table(plans, scan),
        "",
        "retained per font:",
    ]
    for plan in plans:
        lines.append(
            f"  {plan.entry.rel:<46} chars={len(plan.charset):>5}  cmap {plan.orig_cmap_size} -> {plan.subset_cmap_size}"
        )
    text = "\n".join(lines) + "\n"
    (cache / "report.txt").write_text(text, encoding="utf-8")
    (cache / "summary.json").write_text(
        json.dumps(
            {
                "charset": len(charset),
                "shipped_charset": len(scan.shipped),
                "fonts": [
                    {
                        "font": plan.entry.rel,
                        "keep_full": plan.entry.keep_full,
                        "chars": len(plan.charset),
                        "orig_cmap": plan.orig_cmap_size,
                        "subset_cmap": plan.subset_cmap_size,
                        "orig_bytes": plan.original_bytes,
                        "subset_bytes": plan.subset_bytes,
                    }
                    for plan in plans
                ],
            },
            ensure_ascii=False,
            indent=2,
        ),
        encoding="utf-8",
    )


def cmd_prepare(args: argparse.Namespace) -> int:
    cache = Path(args.cache).resolve()
    project = Path(args.project).resolve()
    if os.environ.get("PK_WEB_SKIP_FONT_SUBSET") and not args.force:
        log("[prepare] PK_WEB_SKIP_FONT_SUBSET is set -> skipped (full fonts will be exported)")
        return 0

    lock = acquire_lock(cache)
    try:
        if cache_manifest(cache).is_file():
            warn("found a pending restore marker; restoring .godot first")
            restore_fontdata(cache, quiet=True)

        _scan, _charset, plans, missing = run_subset_stage(args, cache, project)
        if missing:
            die(
                "font subsetting self-check FAILED: "
                f"{missing} missing char(s); nothing was injected into .godot",
                code=1,
            )

        godot = find_godot(args.godot)
        log(f"[prepare] godot: {godot}")
        staged = import_subsets_with_godot(cache, godot, plans, probe=not args.no_godot_probe)
        payload = inject_fontdata(cache, project, plans, staged)
    except SystemExit:
        restore_fontdata(cache, quiet=True)
        raise
    except Exception:  # noqa: BLE001
        restore_fontdata(cache, quiet=True)
        raise
    finally:
        lock.unlink(missing_ok=True)

    width = max([len(plan.entry.rel) for plan in plans] + [30])
    log("")
    log(f"  {'font':<{width}}  {'original .fontdata':>18}  {'injected .fontdata':>18}")
    log(f"  {'-' * width}  {'-' * 18}  {'-' * 18}")
    for plan in plans:
        if plan.fontdata_original or plan.fontdata_subset:
            note = " (unchanged)" if plan.fontdata_original == plan.fontdata_subset else ""
            log(
                f"  {plan.entry.rel:<{width}}  {fmt_mb(plan.fontdata_original):>18}"
                f"  {fmt_mb(plan.fontdata_subset):>18}{note}"
            )
    total_original = sum(plan.fontdata_original for plan in plans)
    total_subset = sum(plan.fontdata_subset for plan in plans)
    log(f"  {'-' * width}  {'-' * 18}  {'-' * 18}")
    log(f"  {'TOTAL':<{width}}  {fmt_mb(total_original):>18}  {fmt_mb(total_subset):>18}")
    log("")
    log(
        f"[prepare] injected {len(payload['files'])} fontdata file(s) for this export;"
        " the original files are backed up and restored by `restore`"
    )
    return 0


def cmd_restore(args: argparse.Namespace) -> int:
    cache = Path(args.cache).resolve()
    return restore_fontdata(cache)


def cmd_verify(args: argparse.Namespace) -> int:
    cache = Path(args.cache).resolve()
    if os.environ.get("PK_WEB_SKIP_FONT_SUBSET") and not args.force:
        log("[verify] PK_WEB_SKIP_FONT_SUBSET is set -> skipped")
        return 0
    return verify_pck(cache, Path(args.pck).resolve())


def cmd_status(args: argparse.Namespace) -> int:
    cache = Path(args.cache).resolve()
    marker = cache_manifest(cache)
    if marker.is_file():
        payload = json.loads(marker.read_text(encoding="utf-8"))
        log(f"[status] INJECTED at {payload.get('created')}: {len(payload.get('files', []))} fontdata file(s)")
        for item in payload.get("files", []):
            log(f"  {item['font']}: {item['original_size']} -> {item['injected_size']}")
        return 0
    log("[status] clean (no injected fontdata)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="subset_fonts.py",
        description="Project.Keynes web-only font subsetting (desktop builds keep the original fonts).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project", default=str(DEFAULT_PROJECT), help="Godot project dir (default: %(default)s)")
    common.add_argument("--cache", default=str(DEFAULT_CACHE), help="cache dir (default: %(default)s)")
    common.add_argument("--force", action="store_true", help="ignore PK_WEB_SKIP_FONT_SUBSET and the subset cache")
    common.add_argument("--strict", action="store_true", help="fail on chars no font can render, even if allowlisted")

    sub = parser.add_subparsers(dest="command")
    sub.add_parser("subset", parents=[common], help="scan + subset + self-check (default; no .godot changes)")
    prepare = sub.add_parser("prepare", parents=[common], help="subset + import + inject into .godot (web build only)")
    prepare.add_argument("--godot", default=None, help="Godot editor binary (default: $GODOT_BIN or auto-detect)")
    prepare.add_argument("--no-godot-probe", action="store_true", help="skip the Font.has_char() probe")
    restore = sub.add_parser("restore", parents=[common], help="restore the original .fontdata files")
    verify = sub.add_parser("verify", parents=[common], help="check the exported pck ships subset fonts")
    verify.add_argument("--pck", required=True, help="path to ProjectKeynes.pck")
    sub.add_parser("status", parents=[common], help="show whether the .godot cache is currently injected")
    return parser


def main(argv: list[str] | None = None) -> int:
    _reconfigure_stdio()
    logging.getLogger("fontTools").setLevel(logging.ERROR)

    args = build_parser().parse_args(argv)
    if args.command is None:
        # 默认 = subset（安全：只写缓存目录，不动 .godot），方便单独跑。
        args = build_parser().parse_args(["subset"] + (argv if argv is not None else sys.argv[1:]))

    handlers = {
        "subset": cmd_subset,
        "prepare": cmd_prepare,
        "restore": cmd_restore,
        "verify": cmd_verify,
        "status": cmd_status,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())
