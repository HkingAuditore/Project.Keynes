#!/usr/bin/env python3
"""Restore input candidate CSR columns from HEAD; keep soft-input edits."""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REL = Path("Project/project-keynes/data/economy/buildings")
RE_STR_ARR = re.compile(r"^(\w+) = PackedStringArray\((.*)\)\s*$", re.M)
RE_I32_ARR = re.compile(r"^(\w+) = PackedInt32Array\((.*)\)\s*$", re.M)


def parse_str_list(raw: str) -> list[str]:
    raw = raw.strip()
    if not raw:
        return []
    return [m.group(1) for m in re.finditer(r'"([^"]*)"', raw)]


def parse_int_list(raw: str) -> list[int]:
    raw = raw.strip()
    if not raw:
        return []
    return [int(x.strip()) for x in raw.split(",") if x.strip()]


def fmt_str(values: list[str]) -> str:
    if not values:
        return "PackedStringArray()"
    return "PackedStringArray(" + ", ".join(f'"{v}"' for v in values) + ")"


def fmt_i32(values: list[int]) -> str:
    if not values:
        return "PackedInt32Array()"
    return "PackedInt32Array(" + ", ".join(str(v) for v in values) + ")"


def fields(text: str) -> dict:
    out: dict = {}
    for m in RE_STR_ARR.finditer(text):
        out[m.group(1)] = parse_str_list(m.group(2))
    for m in RE_I32_ARR.finditer(text):
        out[m.group(1)] = parse_int_list(m.group(2))
    return out


def set_line(text: str, key: str, formatted: str) -> str:
    pattern = re.compile(rf"^{re.escape(key)} = .*$", re.M)
    replacement = f"{key} = {formatted}"
    if pattern.search(text):
        return pattern.sub(replacement, text, count=1)
    return text


def extend_offsets(old: list[int], old_n: int, new_n: int) -> list[int]:
    if new_n <= 0:
        return [0]
    if old_n <= 0 or len(old) != old_n + 1:
        return [0] * (new_n + 1)
    last = old[-1]
    return list(old) + [last] * (new_n - old_n)


def head_text(rel_posix: str) -> str | None:
    result = subprocess.run(
        ["git", "show", f"HEAD:{rel_posix}"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        return None
    return result.stdout


def main() -> None:
    restored = 0
    for path in sorted((ROOT / REL).glob("*.tres")):
        rel = (REL / path.name).as_posix()
        current = path.read_text(encoding="utf-8")
        previous = head_text(rel)
        if previous is None:
            continue
        cur = fields(current)
        prev = fields(previous)
        goods_now = list(cur.get("input_good_ids") or [])
        goods_prev = list(prev.get("input_good_ids") or [])
        cand_now = list(cur.get("input_candidate_good_ids") or [])
        cand_prev = list(prev.get("input_candidate_good_ids") or [])
        eff_now = list(cur.get("input_candidate_efficiency_q16") or [])
        eff_prev = list(prev.get("input_candidate_efficiency_q16") or [])
        off_now = list(cur.get("input_candidate_offsets") or [0])
        off_prev = list(prev.get("input_candidate_offsets") or [0])
        expected_off = extend_offsets(off_prev, len(goods_prev), len(goods_now))
        changed = False
        if cand_now != cand_prev:
            current = set_line(current, "input_candidate_good_ids", fmt_str(cand_prev))
            changed = True
        if eff_now != eff_prev:
            current = set_line(current, "input_candidate_efficiency_q16", fmt_i32(eff_prev))
            changed = True
        if off_now != expected_off:
            current = set_line(current, "input_candidate_offsets", fmt_i32(expected_off))
            changed = True
        if changed:
            path.write_text(current, encoding="utf-8", newline="\n")
            restored += 1
            print(path.name)
    print(f"restored candidate CSR on {restored} buildings")


if __name__ == "__main__":
    main()
