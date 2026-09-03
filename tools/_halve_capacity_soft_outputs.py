#!/usr/bin/env python3
"""Halve outputs for capacity-only soft-tool collectors that were doubled."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = (
    Path(__file__).resolve().parent.parent
    / "Project"
    / "project-keynes"
    / "data"
    / "economy"
    / "buildings"
)


def main() -> None:
    count = 0
    for path in sorted(ROOT.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        modes_m = re.search(
            r"^resource_interaction_modes = PackedStringArray\((.*)\)\s*$", text, re.M
        )
        if not modes_m:
            continue
        mode_list = re.findall(r'"([^"]*)"', modes_m.group(1))
        if not mode_list or any(mode != "capacity" for mode in mode_list):
            continue
        goods_m = re.search(
            r"^input_good_ids = PackedStringArray\((.*)\)\s*$", text, re.M
        )
        req_m = re.search(
            r"^input_required_q16 = PackedInt32Array\((.*)\)\s*$", text, re.M
        )
        if not goods_m or not req_m:
            continue
        good_ids = re.findall(r'"([^"]+)"', goods_m.group(1))
        if good_ids != ["tools"]:
            continue
        if "32768" not in req_m.group(1):
            continue
        out_m = re.search(
            r"^output_quantities_per_day = PackedInt64Array\((.*)\)\s*$", text, re.M
        )
        if not out_m or not out_m.group(1).strip():
            continue
        outs = [int(x.strip()) for x in out_m.group(1).split(",") if x.strip()]
        new_outs = [max(1, v // 2) for v in outs]
        new_line = (
            "output_quantities_per_day = PackedInt64Array("
            + ", ".join(str(v) for v in new_outs)
            + ")"
        )
        text2 = re.sub(
            r"^output_quantities_per_day = PackedInt64Array\(.*\)$",
            new_line,
            text,
            count=1,
            flags=re.M,
        )
        if text2 == text:
            continue
        path.write_text(text2, encoding="utf-8", newline="\n")
        count += 1
        print(f"{path.stem}: {outs} -> {new_outs}")
    print(f"halved {count}")


if __name__ == "__main__":
    main()
