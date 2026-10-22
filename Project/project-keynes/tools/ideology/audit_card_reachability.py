#!/usr/bin/env python3
"""Card reachability audit for the ideology design tables.

Why this exists: Doc 02 §5 says to build the audit BEFORE picking a milestone,
because "which capability unlocks the most cards" is the only ordering input
that is not guesswork. The design doc's card tables already carry the answer in
their 实现 column (`C（X2）`, `A（L3 C）`), so the script only has to parse it and
intersect with the capability status in Doc 02 §2.

Read-only by default. `--write` appends a generated section to the design doc;
that is the only mode that touches any file.

Usage:
    python tools/ideology/audit_card_reachability.py
    python tools/ideology/audit_card_reachability.py --write
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from collections import Counter, OrderedDict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
DESIGN_DOC = REPO_ROOT / "docs/plans/ideology-build-redesign.md"
REVIEW_DOC = REPO_ROOT / "docs/plans/ideology-review/02-capability-gap-and-solutions.md"
# The runtime capability switch lives in the generator, so `requires=` and this
# audit can never disagree about what is shippable.
GENERATOR_PATH = Path(__file__).resolve().parent / "generate_ideology_catalog.py"

# Fallback only: Doc 02 §2 is parsed when present, and a mismatch is reported.
# Keeping the letters here means the script still runs if the doc is renamed.
FALLBACK_STATUS = {
    "X1": "partial", "X2": "partial", "X3": "partial", "X4": "missing",
    "X5": "partial", "X6": "partial", "X7": "partial", "X8": "missing",
    "X9": "missing", "X10": "missing", "X11": "partial", "X12": "missing",
    "X13": "missing", "X14": "missing", "X15": "supported",
}

# A/B/C/D is the difficulty class from design doc §3, and it implies a floor:
# every B and C card needs X1 (per-cell evaluation), A needs nothing.
# D cards almost always name their mechanism in parentheses; when they do not,
# the class itself says "one of X4/X5/X6", which is an alternative, not three
# separate requirements.
LETTER_BASE = {"A": set(), "B": {"X1"}, "C": {"X1"}, "D": set()}
D_ALTERNATIVES = ("X4", "X5", "X6")
ALT_LABEL = "X4|X5|X6"
BARE_C_LABEL = "新 metric（未注明）"

EMOJI_STATUS = {"✅": "supported", "🟡": "partial", "❌": "missing"}
STATUS_ORDER = {"supported": 0, "partial": 1, "missing": 2}
STATUS_TEXT = {"supported": "可用", "partial": "部分", "missing": "缺失"}


def load_runtime_capabilities() -> tuple[frozenset[str], list[str]]:
    """Read `AVAILABLE_CAPABILITIES` from the generator.

    Why the audit consults the generator and not just Doc 02: Doc 02 records the
    DESIGN status ("X1 is partially there"), while the generator records what card
    authoring is actually allowed to publish (`requires=`). The two disagree on
    purpose -- X16 is designed (47.3) but not implemented, so it is `missing` here
    even though the document describes it in full.

    Parsed with `ast` rather than imported: the generator is a script with side
    effects at import (dataclasses, table building), and the audit must not depend
    on it importing cleanly just to read one constant.

    Returns (capabilities the runtime has, warnings).
    """
    warnings: list[str] = []
    if not GENERATOR_PATH.exists():
        return frozenset(), [f"生成器未找到，能力开关不可读：{GENERATOR_PATH}"]
    try:
        tree = ast.parse(GENERATOR_PATH.read_text(encoding="utf-8"))
    except SyntaxError as error:
        return frozenset(), [f"生成器语法错误，能力开关不可读：{error}"]
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if "AVAILABLE_CAPABILITIES" not in targets:
            continue
        # The generator writes `AVAILABLE_CAPABILITIES = frozenset({...})`, so the
        # value is a Call wrapping a Set literal (or a bare Set/Tuple/list).
        value = node.value
        if isinstance(value, ast.Call) and value.args:
            value = value.args[0]
        try:
            parsed = ast.literal_eval(value)
        except (ValueError, SyntaxError) as error:
            return frozenset(), [f"AVAILABLE_CAPABILITIES 无法解析：{error}"]
        return frozenset(parsed), warnings
    return frozenset(), ["生成器没有 AVAILABLE_CAPABILITIES，能力开关按空处理"]


# Capability names that exist only in content (`requires=`), with no Doc 02 §2 row.
# The matrix has no column for them, so they are reported here whenever they are
# not yet available -- otherwise "缺 1 项" silently means "缺 X16" for the tax
# cards while the table shows nothing.
CONTENT_ONLY_CAPABILITIES = {
    "X1b": "每源叠加 + 半径 N（10-roadmap §4.2）",
    "X16": "按职业的税负容忍度 / 满意度 stat（§47.3）",
    "metric68": "cell.net_tax_burden_q16，逐地块实测净税负（§47.9）",
    "reserve_ratio": "国库储备率 = 国库现金 ÷ 上一年全国人口总收入（§47.4）",
}


def apply_capability_switch(status: dict[str, str],
                            caps: frozenset[str]) -> list[str]:
    """Downgrade every designed-but-unimplemented capability to `missing`.

    `status` comes from Doc 02 and describes the design; `caps` describes the
    runtime. A capability in the doc but not in `caps` cannot ship a card, so the
    audit must count it as blocking -- otherwise the matrix says "9 张可直接做" for
    cards the generator is staging.
    """
    warnings: list[str] = []
    for codename, value in sorted(status.items()):
        if STATUS_ORDER.get(value, 2) == 2:
            continue  # already missing
        if codename in caps:
            continue
        status[codename] = "missing"
        warnings.append(
            f"{codename}: 设计表写的是「{STATUS_TEXT.get(value, value)}」，"
            f"但生成器 AVAILABLE_CAPABILITIES 里没有 -> 按缺失计")
    for name, description in CONTENT_ONLY_CAPABILITIES.items():
        if name not in caps:
            warnings.append(f"{name} 未实现：{description}")
    return warnings


def parse_status(review_path: Path) -> tuple[dict[str, str], list[str]]:
    """Read Doc 02 §2's 现状 column. Returns (status, warnings)."""
    warnings: list[str] = []
    status: dict[str, str] = {}
    if not review_path.exists():
        return dict(FALLBACK_STATUS), [f"状态表未找到：{review_path}"]
    in_table = False
    for line in review_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("|") and "现状" in stripped:
            in_table = True
            continue
        if not in_table:
            continue
        if not stripped.startswith("|"):
            in_table = False
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if len(cells) < 3:
            continue
        match = re.match(r"^(X\d{1,2})\b", cells[0])
        if not match:
            continue
        codename = match.group(1)
        word = next((c for c in cells if c and c[0] in EMOJI_STATUS), "")
        if not word:
            warnings.append(f"{codename}: 状态列没有 emoji，按缺失处理")
            status[codename] = "missing"
            continue
        status[codename] = EMOJI_STATUS[word[0]]
    if not status:
        return dict(FALLBACK_STATUS), [f"{review_path} 里没解析出状态表"]
    for codename, value in FALLBACK_STATUS.items():
        if codename not in status:
            warnings.append(f"{codename}: 文档状态表里没有，沿用内置值 {value}")
            status[codename] = value
    return status, warnings


def parse_implementation(cell: str) -> tuple[set[str], set[str], list[str]]:
    """Split an 实现 cell into (required-at-L1, required-only-at-L3, notes)."""
    text = cell.strip()
    required: set[str] = set()
    l3_only: set[str] = set()
    notes: list[str] = []

    letter_match = re.match(r"^([ABCD])\b", text)
    letter = letter_match.group(1) if letter_match else ""
    if letter:
        required |= LETTER_BASE[letter]
    elif not re.search(r"X\d", text):
        notes.append("实现列没有级别字母")

    paren = re.search(r"[（(]([^）)]*)[）)]", text)
    body = paren.group(1) if paren else ""
    # `A（L3 C）`: the escalation is "L3 needs class C", i.e. X2-style work that
    # is NOT needed to ship the card at L1. Counting it would double-count every
    # engine card as blocked.
    l3_gated = bool(re.search(r"L3", body, flags=re.IGNORECASE))
    target = l3_only if l3_gated else required
    for codename in sorted(set(re.findall(r"X\d{1,2}", body))):
        target.add(codename)

    if letter == "D" and not set(re.findall(r"X\d{1,2}", body)):
        required.add(ALT_LABEL)
        notes.append("D 级未注明机制，按 X4/X5/X6 任一处理")
    # A bare `C` means "B + one new per-cell metric" but does not say which one.
    # Counting those as "only X1 missing" would overstate X1's leverage: with X1
    # done they still cannot ship until the metric is named and built.
    if letter == "C" and not set(re.findall(r"X\d{1,2}", body)):
        required.add(BARE_C_LABEL)
        notes.append("C 级未注明新增 metric")
    if "X1" in body and "X1" in l3_only:
        l3_only.discard("X1")
    return required, l3_only, notes


def parse_cards(design_path: Path) -> tuple[list[dict], list[str]]:
    """Parse every card table that has an 实现 column."""
    warnings: list[str] = []
    cards: list[dict] = []
    lines = design_path.read_text(encoding="utf-8").splitlines()
    section = ""
    column_map: dict[str, int] | None = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("## "):
            section = stripped[3:].split(".")[0].strip()
            column_map = None
            continue
        if not stripped.startswith("|"):
            column_map = None
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if "实现" in cells:
            column_map = {name: i for i, name in enumerate(cells)}
            continue
        if column_map is None or set("".join(cells)) <= set("-: "):
            continue
        impl_index = column_map.get("实现")
        if impl_index is None or impl_index >= len(cells):
            continue
        name_cell = cells[0]
        key_match = re.search(r"`([^`]+)`", name_cell)
        # Cards always carry their catalog key in backticks; the 命名协同 table
        # also has an 实现 column but its rows are synergies ("田垄 | ... | X5 / X2"),
        # and counting those as cards inflated the total by a dozen.
        if key_match is None:
            continue
        display = re.sub(r"`[^`]*`", "", name_cell).strip()
        if not display:
            continue
        required, l3_only, notes = parse_implementation(cells[impl_index])
        cards.append(
            {
                "section": section,
                "name": display,
                "key": key_match.group(1) if key_match else "",
                "required": required,
                "l3_only": l3_only,
                "notes": notes,
                "raw": cells[impl_index],
            }
        )
    if not cards:
        warnings.append("一张卡都没解析到，检查表格是否还有 实现 列")
    return cards, warnings


def blocking(card: dict, status: dict[str, str]) -> list[tuple[str, str]]:
    """Capabilities this card needs but does not have, as (name, status)."""
    out: list[tuple[str, str]] = []
    for codename in sorted(card["required"]):
        if codename in (ALT_LABEL, BARE_C_LABEL):
            worst = max((status.get(c, "missing") for c in D_ALTERNATIVES),
                        key=lambda s: STATUS_ORDER.get(s, 2))
            if STATUS_ORDER.get(worst, 2) > 0:
                out.append((codename, worst))
            continue
        value = status.get(codename, "missing")
        if STATUS_ORDER.get(value, 2) > 0:
            out.append((codename, value))
    return out


def render(design_path: Path, status: dict[str, str], cards: list[dict]) -> str:
    out = []
    for card in cards:
        card["missing"] = blocking(card, status)
    ready = [c for c in cards if not c["missing"]]
    one = [c for c in cards if len(c["missing"]) == 1]
    many = [c for c in cards if len(c["missing"]) >= 2]

    out.append("## 可达性矩阵（脚本生成，勿手改）")
    out.append("")
    out.append(f"数据源：`{design_path.name}` 的卡表 + Doc 02 §2 的能力状态。")
    out.append(f"共 **{len(cards)}** 张卡。")
    out.append("")
    out.append("| 分档 | 卡数 | 说明 |")
    out.append("|---|---|---|")
    out.append(f"| 可直接做 | {len(ready)} | 所需能力全部 ✅ |")
    out.append(f"| 缺 1 项 | {len(one)} | 补一项即可解锁 |")
    out.append(f"| 缺 2 项及以上 | {len(many)} | 依赖多个里程碑 |")
    out.append("")

    solo = Counter()
    for card in one:
        solo[card["missing"][0][0]] += 1
    mentioned = Counter()
    for card in cards:
        for codename, _ in card["missing"]:
            mentioned[codename] += 1
    if solo or mentioned:
        out.append("### 补哪一项最划算")
        out.append("")
        out.append("| 能力 | 状态 | 单独卡住多少张（缺 1 项） | 涉及多少张 |")
        out.append("|---|---|---|---|")
        for codename, count in sorted(
                solo.items(), key=lambda kv: (-kv[1], kv[0])):
            value = status.get(codename.split("|")[0], "missing")
            out.append(f"| {codename} | {STATUS_TEXT.get(value, '?')} | {count} | "
                       f"{mentioned.get(codename, 0)} |")
        for codename, count in sorted(
                ((c, n) for c, n in mentioned.items() if c not in solo),
                key=lambda kv: (-kv[1], kv[0])):
            value = status.get(codename.split("|")[0], "missing")
            out.append(f"| {codename} | {STATUS_TEXT.get(value, '?')} | 0 | {count} |")
        out.append("")

    if ready:
        out.append("### 可直接做")
        out.append("")
        for card in ready:
            out.append(f"- {card['name']}`{card['key']}` — {card['raw']}")
        out.append("")
    if one:
        out.append("### 缺 1 项")
        out.append("")
        out.append("| 卡 | 卡住它的一项 | 状态 | 附录 |")
        out.append("|---|---|---|---|")
        for card in sorted(one, key=lambda c: c["missing"][0][0]):
            codename, value = card["missing"][0]
            appendix = "；".join(card["notes"]) if card["notes"] else card["raw"]
            out.append(f"| {card['name']}`{card['key']}` | {codename} | "
                       f"{STATUS_TEXT.get(value, '?')} | {appendix} |")
        out.append("")
    if many:
        # A 91-line list answers nothing; the pair distribution does. "X1+X7
        # blocks 25 cards" says where to cut, "these 91 cards are blocked" does
        # not.
        out.append("### 缺 2 项及以上：按阻塞组合分布")
        out.append("")
        pairs = Counter()
        for card in many:
            pairs[" + ".join(c for c, _ in card["missing"])] += 1
        out.append("| 组合 | 卡数 |")
        out.append("|---|---|")
        for combo, count in sorted(pairs.items(), key=lambda kv: (-kv[1], kv[0]))[:15]:
            out.append(f"| {combo} | {count} |")
        if len(pairs) > 15:
            out.append(f"| （其余 {len(pairs) - 15} 种组合） | "
                       f"{sum(n for _, n in sorted(pairs.items(), key=lambda kv: -kv[1])[15:])} |")
        out.append("")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--design", type=Path, default=DESIGN_DOC)
    parser.add_argument("--review", type=Path, default=REVIEW_DOC)
    parser.add_argument("--write", action="store_true",
                        help="把生成结果追加到设计文档（默认只打印）")
    args = parser.parse_args()

    status, warnings = parse_status(args.review)
    # The runtime switch decides what a card may actually ship, so it overrides
    # Doc 02's design status for any capability the engine does not have yet.
    caps, cap_warnings = load_runtime_capabilities()
    warnings.extend(cap_warnings)
    warnings.extend(apply_capability_switch(status, caps))
    cards, card_warnings = parse_cards(args.design)
    warnings.extend(card_warnings)
    if not cards:
        for warning in warnings:
            print(f"[warn] {warning}", file=sys.stderr)
        return 1

    report = render(args.design, status, cards)
    print(report)

    unknown = sorted({c for card in cards for c in card["required"]
                      if c not in (ALT_LABEL, BARE_C_LABEL) and c not in status})
    if unknown:
        print(f"[warn] 卡表引用了状态表里没有的能力：{', '.join(unknown)}",
              file=sys.stderr)
    for warning in warnings:
        print(f"[warn] {warning}", file=sys.stderr)

    if args.write:
        text = args.design.read_text(encoding="utf-8")
        marker = "## 可达性矩阵（脚本生成，勿手改）"
        if marker in text:
            print("[warn] 设计文档里已有该节，跳过 --write", file=sys.stderr)
            return 0
        with args.design.open("a", encoding="utf-8") as handle:
            # The renderer ends with a blank line; adding another one trips
            # `git diff --check` ("new blank line at EOF") on every run.
            handle.write("\n---\n\n" + report.rstrip("\n") + "\n")
        print(f"[ok] 已追加到 {args.design}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
