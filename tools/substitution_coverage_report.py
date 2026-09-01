"""Report how many alternatives each construction group and fuel slot has.

A group with a single candidate is a hard dependency: if that one good is
unreachable on a cell, every building needing it is permanently unbuildable.
"""

from __future__ import annotations

import collections
import pathlib
import re

DATA = pathlib.Path(__file__).resolve().parents[1] / "Project" / "project-keynes" / "data"
GOODS = DATA / "goods"
BUILDINGS = DATA / "economy" / "buildings"


def arr(text: str, field: str, kind: str) -> list[str] | None:
    match = re.search(rf"^{field} = {kind}\((.*)\)$", text, re.M)
    if match is None:
        return None
    body = match.group(1).strip()
    return [] if not body else [v.strip().strip('"') for v in body.split(",")]


def load_pools() -> tuple[dict[str, list[str]], dict[str, int]]:
    pools: dict[str, list[str]] = collections.defaultdict(list)
    quality: dict[str, int] = {}
    for path in sorted(GOODS.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        match = re.search(r"^production_quality_level = (-?\d+)$", text, re.M)
        quality[path.stem] = int(match.group(1)) if match else 0
        for category in arr(text, "substitution_category_ids", "PackedStringArray") or []:
            pools[category].append(path.stem)
    return pools, quality


def main() -> None:
    pools, quality = load_pools()
    hist: collections.Counter[int] = collections.Counter()
    single: list[str] = []

    for path in sorted(BUILDINGS.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        groups = arr(text, "construction_good_ids", "PackedStringArray")
        if not groups:
            continue
        categories = (arr(text, "construction_category_ids", "PackedStringArray") or []) + [""] * len(groups)
        levels = [int(v) for v in (arr(text, "construction_min_quality_levels", "PackedInt32Array") or [])] + [0] * len(groups)
        offsets = [int(v) for v in (arr(text, "construction_candidate_offsets", "PackedInt32Array") or [])]
        has_offsets = len(offsets) == len(groups) + 1
        for index, good in enumerate(groups):
            if categories[index]:
                count = sum(1 for m in pools[categories[index]] if quality[m] >= levels[index])
            elif has_offsets and offsets[index + 1] - offsets[index] > 0:
                count = offsets[index + 1] - offsets[index]
            else:
                count = 1
            hist[count] += 1
            if count == 1:
                single.append(f"{path.stem}:{good}")

    total = sum(hist.values())
    print("construction groups by number of candidates")
    for count in sorted(hist):
        share = 100.0 * hist[count] / total
        print(f"  {count} candidate(s): {hist[count]:>4}  ({share:.1f}%)")
    print(f"\ntotal construction groups: {total}")
    print(f"still single-candidate:    {len(single)}")
    remaining: collections.Counter[str] = collections.Counter(s.split(":")[1] for s in single)
    print("\nremaining hard dependencies by good:")
    for good, count in remaining.most_common():
        print(f"  {good:<26} {count}")


if __name__ == "__main__":
    main()
