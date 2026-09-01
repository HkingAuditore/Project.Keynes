"""Report how many production input slots actually have a substitute.

A slot is covered when it names a substitution category or lists more than one
explicit candidate. Counting only `input_category_ids` understates coverage,
because several recipes already carry hand-tuned explicit candidate lists with
per-slot efficiencies.
"""

from __future__ import annotations

import collections
import pathlib
import re

BUILDINGS = pathlib.Path(__file__).resolve().parents[1] / "Project" / "project-keynes" / "data" / "economy" / "buildings"


def arr(text: str, field: str, kind: str) -> list[str] | None:
    match = re.search(rf"^{field} = {kind}\((.*)\)$", text, re.M)
    if match is None:
        return None
    body = match.group(1).strip()
    return [] if not body else [v.strip().strip('"') for v in body.split(",")]


def main() -> None:
    bare: collections.Counter[str] = collections.Counter()
    by_category: collections.Counter[str] = collections.Counter()
    by_explicit: collections.Counter[str] = collections.Counter()
    bare_buildings: dict[str, list[str]] = {}

    for path in sorted(BUILDINGS.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        inputs = arr(text, "input_good_ids", "PackedStringArray")
        if not inputs:
            continue
        categories = (arr(text, "input_category_ids", "PackedStringArray") or []) + [""] * len(inputs)
        offsets = [int(v) for v in (arr(text, "input_candidate_offsets", "PackedInt32Array") or [])]
        has_offsets = len(offsets) == len(inputs) + 1
        for index, good in enumerate(inputs):
            candidates = offsets[index + 1] - offsets[index] if has_offsets else 0
            if categories[index]:
                by_category[good] += 1
            elif candidates > 1:
                by_explicit[good] += 1
            else:
                bare[good] += 1
                bare_buildings.setdefault(good, []).append(path.stem)

    print(f"slots covered by category : {sum(by_category.values())}")
    print(f"slots covered by explicit : {sum(by_explicit.values())}")
    print(f"slots with NO substitute  : {sum(bare.values())}")
    print("\ntop goods with no substitute:")
    for good, count in bare.most_common(30):
        print(f"  {good:<26} {count}")


if __name__ == "__main__":
    main()
