#!/usr/bin/env python3
"""Restore outputs for former-empty soft-tool buildings that still show 2x HEAD."""
from __future__ import annotations

import re
import subprocess
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
    fixed = []
    for path in sorted(ROOT.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        goods_m = re.search(
            r"^input_good_ids = PackedStringArray\((.*)\)\s*$", text, re.M
        )
        if not goods_m:
            continue
        good_ids = re.findall(r'"([^"]+)"', goods_m.group(1))
        if good_ids != ["tools"]:
            continue
        out_m = re.search(
            r"^output_quantities_per_day = PackedInt64Array\((.*)\)\s*$", text, re.M
        )
        if not out_m or not out_m.group(1).strip():
            continue
        outs = [int(x.strip()) for x in out_m.group(1).split(",") if x.strip()]
        try:
            head = subprocess.check_output(
                [
                    "git",
                    "show",
                    f"HEAD:Project/project-keynes/data/economy/buildings/{path.name}",
                ],
                stderr=subprocess.DEVNULL,
            ).decode("utf-8", errors="replace")
        except subprocess.CalledProcessError:
            continue
        head_goods_m = re.search(
            r"^input_good_ids = PackedStringArray\((.*)\)\s*$", head, re.M
        )
        head_good_ids = (
            re.findall(r'"([^"]+)"', head_goods_m.group(1)) if head_goods_m else []
        )
        if head_good_ids:
            continue
        head_out_m = re.search(
            r"^output_quantities_per_day = PackedInt64Array\((.*)\)\s*$", head, re.M
        )
        if not head_out_m or not head_out_m.group(1).strip():
            continue
        head_vals = [
            int(x.strip()) for x in head_out_m.group(1).split(",") if x.strip()
        ]
        if outs == head_vals:
            continue
        if len(outs) == len(head_vals) and all(
            a == 2 * b for a, b in zip(outs, head_vals)
        ):
            line = (
                "output_quantities_per_day = PackedInt64Array("
                + ", ".join(str(v) for v in head_vals)
                + ")"
            )
            text2 = re.sub(
                r"^output_quantities_per_day = PackedInt64Array\(.*\)$",
                line,
                text,
                count=1,
                flags=re.M,
            )
            # Also restore extract resources if exactly doubled.
            head_res_m = re.search(
                r"^resource_quantities_per_day = PackedInt64Array\((.*)\)\s*$",
                head,
                re.M,
            )
            res_m = re.search(
                r"^resource_quantities_per_day = PackedInt64Array\((.*)\)\s*$",
                text2,
                re.M,
            )
            modes_m = re.search(
                r"^resource_interaction_modes = PackedStringArray\((.*)\)\s*$",
                text2,
                re.M,
            )
            if head_res_m and res_m and modes_m:
                modes = re.findall(r'"([^"]*)"', modes_m.group(1))
                head_res = [
                    int(x.strip())
                    for x in head_res_m.group(1).split(",")
                    if x.strip()
                ]
                cur_res = [
                    int(x.strip()) for x in res_m.group(1).split(",") if x.strip()
                ]
                if len(head_res) == len(cur_res) == len(modes):
                    restored = []
                    for mode, cur, head_v in zip(modes, cur_res, head_res):
                        if mode != "capacity" and cur == 2 * head_v:
                            restored.append(head_v)
                        else:
                            restored.append(cur)
                    rline = (
                        "resource_quantities_per_day = PackedInt64Array("
                        + ", ".join(str(v) for v in restored)
                        + ")"
                    )
                    text2 = re.sub(
                        r"^resource_quantities_per_day = PackedInt64Array\(.*\)$",
                        rline,
                        text2,
                        count=1,
                        flags=re.M,
                    )
            path.write_text(text2, encoding="utf-8", newline="\n")
            fixed.append(f"{path.stem}: {outs}->{head_vals}")
    print(f"fixed {len(fixed)}")
    for row in fixed:
        print(row)


if __name__ == "__main__":
    main()
