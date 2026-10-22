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
    block counts comments, which is how `land_reclamation` was once misreported.
    """
    text = GENERATOR.read_text(encoding="utf-8")
    out: dict[str, str] = {}
    for block in re.split(r"\nLEVEL_ROWS\[", text)[1:]:
        match = re.match(r'"([a-z_0-9]+)"\]', block)
        if not match:
            continue
        key = match.group(1)
        body = re.split(r"\n(?:LEVEL_ROWS|LEVEL_TERMS|CARD_META)\[", block)[0]
        assigned = re.findall(r"selector=([A-Z_][A-Z0-9_]*)", body)
        out[key] = "union" if any(s in UNION_SELECTORS for s in assigned) else "self"
    return out


def main() -> int:
    blocked = x1_blocked_cards()
    authored = authored_cards()

    self_done = [k for k in blocked if authored.get(k) == "self"]
    union_in_blocked = [k for k in blocked if authored.get(k) == "union"]
    todo = [k for k in blocked if k not in authored]
    union_all = sorted(k for k, v in authored.items() if v == "union")

    print(f"X1-blocked total: {len(blocked)}")
    print(f"  already implemented, SELF/COUNTRY: {len(self_done)}")
    print(f"  already implemented, kind 14/15 union: {len(union_in_blocked)}")
    print(f"  not written yet: {len(todo)}")
    print()

    print(f"=== all cards using kind 14/15 (T12 roster): {len(union_all)} ===")
    for index, key in enumerate(union_all, 1):
        inside = "yes" if key in blocked else "no (already published)"
        print(f"  {index:2d}. {key:32s} in-54: {inside}")
    print()

    print("=== SELF/COUNTRY among the 54 (no X1-b needed) ===")
    print("  " + ", ".join(self_done))
    print()
    print("=== not written yet (C-c body) ===")
    print("  " + ", ".join(todo))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
