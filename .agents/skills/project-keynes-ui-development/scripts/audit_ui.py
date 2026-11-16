#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Project.Keynes UI 反模式扫描器（对应 references/antipatterns.md）。

用法：
    PYTHONPATH= python audit_ui.py --root <工程根> --out <输出目录>

输出：
    pattern_hits.csv        逐行命中（含原文与可见性判定）
    pattern_stats.md        每模式命中数 / 文件数 / Top 文件
    player_visible_hits.md  玩家可见命中，按模式分组

只读游戏工程。机械命中不等于问题数（本项目实测误报率 61.2%），
必须逐条打开源码确认赋值链后再下结论。
"""
import argparse
import csv
import os
import re
from collections import Counter, defaultdict

CJK = re.compile(r"[\u4e00-\u9fff]")
PATH_RE = re.compile(
    r"((?:scripts|scenes|data|assets|tests)/[A-Za-z0-9_./-]+\.(?:gd|tscn|json|tres))")
PLAYER_TARGET = re.compile(
    r"(?:\.text\s*=|tooltip_text\s*=|\btext\s*[:=]|\btitle\s*[:=]|"
    r"\bsubtitle\s*[:=]|\bhint\s*[:=]|\bcaption\s*[:=]|\blabel\s*[:=]|"
    r'\b"text"\s*:|\b"tooltip"\s*:|\blines\.append)')
BLOCK_START = re.compile(r"^\s*(?:static\s+)?func\s+\w+\s*\(")

INTERNAL_UNITS = [
    "百人日", "每百人日", "每百人", "/百人", "万人日", "千人日",
    "1/10000", "1/1000", "1/65536", "65536", "Q16", "定点",
    "缩放因子", "原始单位", "量纲",
]
INTERNAL_TERMS = [
    "Q16", "定点", "原生", "runtime", "fast_tick", "p95", "SUS", "worker",
    "POD", "snapshot", "探针", "冻结", "中性环境", "修订", "揭示证据",
    "硬前置", "安全边界", "运行时尚未就绪", "autoload", "SoA", "MarketStore",
]
TEMP_TERMS = [
    "TODO", "FIXME", "测试", "临时", "占位", "placeholder", "dummy", "mock",
    "示例数据", "样例", "尚未开放", "尚未就绪", "暂不可用",
]
EMPTY_TERMS = ["无需", "不计", "暂无", "尚未", "待结算", "暂不可用", "未就绪"]
FOOTNOTE_TERMS = [
    "归一", "口径", "长按", "按当前", "计算方式", "注：", "说明：",
    "仅供参考", "示意", "示例", "基准为", "相对…", "此处显示",
]
SYMBOLS = re.compile("[🔒🔍⚙⚔🛡✨⭐📌📎💡⚠❗✅❌🗡🏹🐎💰📜🧭]"
                     "|[△☼♣◆▲▼◀▶›—·★☆♠♥♦●■□]")

LINE_RULES = [
    ("P02", "风格", re.compile(r"StyleBoxFlat\.new\(\)|set_corner_radius_all\("), False),
    ("P03", "风格", re.compile(r"(?<!\w)(?:Color8?\(|Color\(\"|#[0-9a-fA-F]{6}\b)"), False),
    ("P04", "风格", re.compile(r"add_theme_[a-z_]+_override\("), False),
    ("P05", "风格", SYMBOLS, True),
    ("P10", "术语", re.compile(r"%\.\d+f?\s*[kKmMbB]\b|\"[kKmMbB]\""), False),
    ("P13", "排版", re.compile(r"add_theme_constant_override\(\"separation\",\s*\d+|theme_override_constants/separation\s*=\s*\d+"), False),
    ("P14", "排版", re.compile(r"\bposition\s*=\s*Vector2|\boffset_(?:left|top|right|bottom)\s*=\s*-?\d|set_position\(Vector2"), False),
    ("P15", "排版", re.compile(r"add_theme_font_size_override\([^,]+,\s*\d+|theme_override_font_sizes/font_size\s*=\s*\d+"), False),
    ("P19", "交互", re.compile(r"FOCUS_NONE|focus_mode\s*=\s*0"), False),
    ("P20", "交互", re.compile(r"\.visible\s*=\s*(?:true|false)|\bvisible\s*=\s*(?:true|false)|set_visible\("), False),
    ("P21", "交互", re.compile(r"func _process\(|func _physics_process\("), False),
]
WORD_RULES = [
    ("P06", "术语", INTERNAL_UNITS),
    ("P07", "术语", INTERNAL_TERMS),
    ("P08", "术语", TEMP_TERMS),
    ("P09", "术语", ["pk_", "PK_", "gm_", "perf_"]),
    ("P16", "信息", EMPTY_TERMS),
    ("P22", "内容", FOOTNOTE_TERMS),
    ("P23", "内容", ["无需", "暂无", "不计", "读取中", "—", "暂不可用"]),
]
NAMES = {
    "P01": "PK* variation 被 panel stylebox 覆盖",
    "P02": "自造圆角纯色 StyleBoxFlat",
    "P03": "硬编码颜色绕过 UITokens",
    "P04": "运行时 theme override 架空集中 Theme",
    "P05": "Unicode/emoji 占位图标",
    "P06": "内部量纲单位外泄",
    "P07": "实现术语进入玩家文案",
    "P08": "测试/临时/占位文案",
    "P09": "内部标识前缀出现在展示文本",
    "P10": "英文数字后缀单位",
    "P11": "显式 WORD_SMART + HBox 短标签折行风险",
    "P12": "固定数值最小宽 + 右对齐",
    "P13": "硬编码 separation 字面量",
    "P14": "硬编码绝对坐标/offset",
    "P15": "硬编码字号",
    "P16": "空态/占位文案",
    "P17": "同函数多处百分比格式化（疑似同值重复）",
    "P19": "FOCUS_NONE / focus_mode=0",
    "P20": "布尔 visible 显隐",
    "P21": "_process / _physics_process 逐帧",
    "P22": "自证性/脚注式说明",
    "P23": "空态套话与空容器",
}


def files_under(root, prefixes, suffixes):
    out = []
    for base, _dirs, names in os.walk(root):
        for fn in names:
            if not fn.endswith(suffixes):
                continue
            rel = os.path.relpath(os.path.join(base, fn), root).replace("\\", "/")
            if prefixes and not any(rel.startswith(p) for p in prefixes):
                continue
            out.append(rel)
    return sorted(out)


def scope(root):
    core, ext = [], []
    for rel in files_under(root, ("scripts/ui/", "scenes/ui/", "scenes/"),
                           (".gd", ".tscn")):
        if rel.startswith("scenes/") and rel.count("/") > 1 and not rel.startswith("scenes/ui/"):
            continue
        core.append(rel)
    all_scripts = files_under(root, ("scripts/",), (".gd",))
    for rel in all_scripts:
        if rel in core:
            continue
        if any(k in rel for k in ("view_model", "presenter", "catalog", "narrative")):
            ext.append(rel)
    return core, ext


def visibility(line):
    s = line.lstrip()
    if s.startswith("#") or s.startswith(";"):
        return "comment"
    if not CJK.search(line) and not SYMBOLS.search(line):
        return "code_only"
    return "likely" if PLAYER_TARGET.search(line) else "possible"


def function_blocks(lines):
    blocks, cur = [], None
    for i, line in enumerate(lines, 1):
        if BLOCK_START.match(line):
            cur = {"start": i, "lines": []}
            blocks.append(cur)
        if cur is not None:
            cur["lines"].append((i, line))
    return blocks


def scan_file(root, rel):
    path = os.path.join(root, rel.replace("/", os.sep))
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    hits = []

    # .tscn 同节点覆盖（P01 最重要的形态）
    if rel.endswith(".tscn"):
        block, start = [], 0

        def flush():
            if not block:
                return
            j = "\n".join(block)
            if "theme_type_variation" in j and "theme_override_styles/panel" in j:
                ln = next((i for i, l in enumerate(block, start)
                           if "theme_override_styles/panel" in l), start)
                raw = next((l.strip() for l in block
                            if "theme_override_styles/panel" in l), "")
                hits.append(("P01", rel, ln, raw, "possible",
                             "tscn 同节点 PK* variation 被 panel stylebox 覆盖"))

        for i, line in enumerate(lines, 1):
            if line.startswith("[node "):
                flush()
                block, start = [line], i
            elif block:
                block.append(line)
        flush()

    for b in function_blocks(lines):
        text = "\n".join(l for _, l in b["lines"])
        nums = b["lines"]
        if "theme_type_variation" in text and re.search(
                r"add_theme_stylebox_override\(\s*\"panel\"", text):
            ln = next((i for i, l in nums if "add_theme_stylebox_override" in l
                       and "panel" in l), b["start"])
            hits.append(("P01", rel, ln, lines[ln - 1].strip(), "possible",
                         "同函数内 PK* variation 被 panel stylebox 覆盖"))
        # Godot Label 默认 AUTOWRAP_OFF，只有显式 WORD_SMART 才有折行风险
        if "HBoxContainer.new()" in text and "AUTOWRAP_WORD_SMART" in text:
            ln = next((i for i, l in nums if "AUTOWRAP_WORD_SMART" in l), b["start"])
            hits.append(("P11", rel, ln, lines[ln - 1].strip(), "possible",
                         "HBox 内 Label 显式开了自动换行"))
        if "HORIZONTAL_ALIGNMENT_RIGHT" in text and "custom_minimum_size.x" in text:
            ln = next((i for i, l in nums if "custom_minimum_size.x" in l), b["start"])
            hits.append(("P12", rel, ln, lines[ln - 1].strip(), "possible",
                         "固定数值最小宽 + 右对齐"))
        pct = [i for i, l in nums if "%%" in l]
        if len(pct) >= 3 and "text" in text.lower():
            hits.append(("P17", rel, pct[0], lines[pct[0] - 1].strip(), "possible",
                         "同函数多处百分比格式化"))

    for i, line in enumerate(lines, 1):
        vis = visibility(line)
        for pid, _cat, rx, need_visible in LINE_RULES:
            if not rx.search(line):
                continue
            if need_visible and vis in ("comment", "code_only"):
                continue
            hits.append((pid, rel, i, line.strip(), vis, ""))
        if vis in ("comment", "code_only"):
            continue
        for pid, _cat, words in WORD_RULES:
            for w in words:
                if w in line:
                    hits.append((pid, rel, i, line.strip(), vis, "命中词：%s" % w))
                    break
    return hits


def main():
    ap = argparse.ArgumentParser(description="Project.Keynes UI 反模式扫描")
    ap.add_argument("--root", required=True, help="工程根（含 project.godot 的目录）")
    ap.add_argument("--out", required=True, help="输出目录")
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    core, ext = scope(root)
    hits = []
    for rel in core + ext:
        hits.extend(scan_file(root, rel))
    uniq = {}
    for h in hits:
        uniq.setdefault((h[0], h[1], h[2]), h)
    hits = sorted(uniq.values(), key=lambda h: (h[0], h[1], h[2]))

    with open(os.path.join(out, "pattern_hits.csv"), "w",
              encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["pattern_id", "file", "line", "visibility", "raw", "note"])
        for pid, rel, ln, raw, vis, note in hits:
            w.writerow([pid, rel, ln, vis, raw[:300], note])

    by = defaultdict(list)
    for h in hits:
        by[h[0]].append(h)
    with open(os.path.join(out, "pattern_stats.md"), "w", encoding="utf-8") as fh:
        fh.write("# UI 反模式扫描统计\n\n")
        fh.write("范围：core %d + ext %d 文件；只读，未修改工程。\n\n" % (len(core), len(ext)))
        fh.write("| 模式 | 说明 | 命中行 | 文件数 | 玩家可见 | Top 3 文件 |\n")
        fh.write("|---|---|---:|---:|---:|---|\n")
        for pid in sorted(NAMES):
            g = by.get(pid, [])
            c = Counter(h[1] for h in g)
            vis = sum(1 for h in g if h[4] in ("likely", "possible"))
            top = "、".join("%s(%d)" % (f.split("/")[-1], n)
                           for f, n in c.most_common(3)) or "—"
            fh.write("| %s | %s | %d | %d | %d | %s |\n" %
                     (pid, NAMES[pid], len(g), len(c), vis, top))
        fh.write("\n合计 %d 条 / %d 文件。\n\n" %
                 (len(hits), len({h[1] for h in hits})))
        fh.write("> **机械命中不等于问题数**：本项目实测逐条复核误报率 61.2%。"
                 "必须确认中文字符串真的赋给 text/tooltip_text/label/title/hint，"
                 "排除注释、日志、纯代码标识符、内部字典 key。\n")

    with open(os.path.join(out, "player_visible_hits.md"), "w", encoding="utf-8") as fh:
        fh.write("# 玩家可见命中（供人工复核）\n\n")
        for pid in ["P06", "P07", "P08", "P16", "P22", "P23", "P05", "P01", "P11", "P12"]:
            g = [h for h in by.get(pid, []) if h[4] in ("likely", "possible")]
            if not g:
                continue
            fh.write("## %s %s（%d 条）\n\n| 文件:行 | 可见性 | 原文 |\n|---|---|---|\n" %
                     (pid, NAMES[pid], len(g)))
            for _pid, rel, ln, raw, vis, _note in g[:200]:
                fh.write("| `%s:%d` | %s | %s |\n" %
                         (rel, ln, vis, raw.replace("|", "\\|")[:220]))
            if len(g) > 200:
                fh.write("\n（另有 %d 条见 CSV）\n" % (len(g) - 200))
            fh.write("\n")
    print("scope core=%d ext=%d" % (len(core), len(ext)))
    print("hits=%d files=%d" % (len(hits), len({h[1] for h in hits})))
    print("outputs ->", out)


if __name__ == "__main__":
    main()
