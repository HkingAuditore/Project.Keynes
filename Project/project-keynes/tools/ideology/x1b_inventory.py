#!/usr/bin/env python3
"""X1-b inventory: reproduce the numbers in `09-content-status.md` §7.7.

Why a script: the 54 / 12 / 9 / 33 split and the "12 cards to switch" roster are
quoted in the spec, and hand-counting them drifted once already (a card was
reported as using kind 14/15 because its *comment* mentioned `cell.frontier`).
Everything below is derived from the generator and the design doc so it cannot
drift again.

Read-only. Prints three tables; no file is written.
"""
from __future__ import annotations

import pathlib
import re

REPO_ROOT = pathlib.Path(__file__).resolve().parents[4]
GENERATOR = REPO_ROOT / "Project/project-keynes/tools/ideology/generate_ideology_catalog.py"
DESIGN_DOC = REPO_ROOT / "docs/plans/ideology-build-redesign.md"

# Selector constants as authored in the generator.
UNION_SELECTORS = ("SEL_TAG_SOURCE_R1", "SEL_TAG_SOURCE_R2")


def x1_blocked_cards() -> list[str]:
    """Cards whose ONLY blocker is X1, from the generated reachability matrix."""
    doc = DESIGN_DOC.read_text(encoding="utf-8")
    start = doc.index("### 缺 1 项")
    end = doc.index("### 缺 2 项及以上")
    out: list[str] = []
    for line in doc[start:end].splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 3 or cells[1] != "X1":
            continue
        match = re.search(r"`([^`]+)`", cells[0])
        if match:
            out.append(match.group(1))
    return out


def authored_cards() -> dict[str, str]:
    """card -> "union" | "self", by which selector its programs actually assign.

    Matches `selector=SEL_TAG_SOURCE_R*` only. A substring search over the whole
    block counts comments and unrelated helper code, which misreported
    `land_reclamation` twice: once via a comment, once via the block splitter
    running past the card into the validator code below it (its block came out
    85 KB long). Both are fixed by bounding the block at ANY following
    module-level statement, not just the three that were listed before.
    """
    text = GENERATOR.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    for block in re.split(r"\nLEVEL_ROWS\[", text)[1:]:
        match = re.match(r'"([a-z_0-9]+)"\]', block)
        if not match:
            continue
        key = match.group(1)
        # The block ends at the next module-level construct of any kind.
        body = re.split(r"\n(?:[A-Za-z_][A-Za-z_0-9]*\s*=|[A-Za-z_][A-Za-z_0-9\[\]]*\[|"
                        r"def |class |@|_x1\(|if |for |try:|# ──)",
                        block)[0]
        assigned = re.findall(r"selector=([A-Z_][A-Z0-9_]*)", body)
        out[key] = "union" if any(s in UNION_SELECTORS for s in assigned) else "self"
    return out


def x1_target_cards() -> tuple[set[str], set[str]]:
    """(cards with an X1 target, cards listed as brand new this round).

    Read from the generator's own `X1_TARGETS` / `X1_NATIONAL_TERMS` /
    `X1_BRAND_NEW` rosters so this script cannot disagree with what the generator
    actually stages.
    """
    text = GENERATOR.read_text(encoding="utf-8")
    targeted = set(re.findall(r'_x1\("([a-z_0-9]+)"', text))
    # `double_entry` lives in `X1_NATIONAL_TERMS` because a national card cannot be
    # a cell program. Scan ONLY that dict's body -- a bare `"key": [` regex over the
    # whole file also matches `LEVEL_ROWS[...]`-adjacent lines and invented a
    # phantom 13th union card once already.
    start = text.index("X1_NATIONAL_TERMS: dict[str, list] = {")
    end = text.index("\n}", start)
    targeted |= set(re.findall(r'^    "([a-z_0-9]+)": \[', text[start:end], re.M))
    start = text.index("X1_BRAND_NEW = frozenset({")
    end = text.index("})", start)
    brand_new = set(re.findall(r'"([a-z_0-9]+)"', text[start:end]))
    return targeted, brand_new


def main() -> int:
    blocked = x1_blocked_cards()
    authored = authored_cards()
    targeted, brand_new = x1_target_cards()

    self_done = [k for k in blocked if authored.get(k) == "self"]
    union_in_blocked = [k for k in blocked if authored.get(k) == "union"]
    todo = [k for k in blocked if k not in authored]
    union_all = sorted(k for k, v in authored.items() if v == "union")

    print(f"X1-blocked total: {len(blocked)}")
    print(f"  already implemented, SELF/COUNTRY: {len(self_done)}")
    print(f"  already implemented, kind 14/15 union: {len(union_in_blocked)}")
    print(f"  not written yet: {len(todo)}")
    print()

    # The 33 split the reviewer asked for: cards that already had a CARDS entry
    # (written with an old national effect) vs cards that were entirely absent.
    rewritten = [k for k in todo if k not in brand_new]
    fresh = [k for k in todo if k in brand_new]
    print(f"=== 这 {len(todo)} 张的两种来历 ===")
    print(f"  已有条目、改写为 X1 形态（旧版继续发布）: {len(rewritten)}")
    print("    " + ", ".join(rewritten))
    print()
    print(f"  生成器里原本完全没有条目、本轮新写: {len(fresh)}")
    print("    " + ", ".join(fresh))
    print()
    # Anything in `todo` that has no X1 target at all would be an authoring hole.
    no_target = [k for k in todo if k not in targeted]
    print(f"  其中已写好 X1 形态: {len(todo) - len(no_target)} / {len(todo)}")
    if no_target:
        print(f"  !! 尚未写: {', '.join(no_target)}")
    print()

    print(f"=== all cards using kind 14/15 (T12 roster): {len(union_all)} ===")
    for index, key in enumerate(union_all, 1):
        inside = "yes" if key in blocked else "no (already published)"
        print(f"  {index:2d}. {key:32s} in-54: {inside}")
    print()

    print("=== SELF/COUNTRY among the 54 (no X1-b needed) ===")
    print("  " + ", ".join(self_done))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
