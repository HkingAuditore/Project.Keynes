"""Widen construction recipes onto era-scoped substitution categories.

Every building used to name one exact good per construction group, so a single
unobtainable material could stall a whole technology era: no bast fibre meant no
gathering camp, no silica meant no glass and therefore no modern building at all.

This rewrites the authored `.tres` content so each structural group points at a
pool of interchangeable materials. The pools are scoped by era rather than
gated by a minimum quality, because a quality gate is only a lower bound and
would let aluminium substitute into a stone-age hut.

Run with --check to report what would change without touching any file.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Project" / "project-keynes" / "data"
GOODS = ROOT / "goods"
BUILDINGS = ROOT / "economy" / "buildings"

PRIMITIVE = "primitive_construction"
LASHING = "primitive_lashing"
CLASSICAL = "classical_construction"
INDUSTRIAL = "industrial_construction"
METAL = "structural_metal"
CONDUCTOR = "conductor_metal"
TOOLS = "tools"

# Pool membership. Members of one pool are near enough in price that the
# cheapest-effective-cost planner will not permanently ignore the others.
POOL_MEMBERS = {
    PRIMITIVE: ["turf_block", "reed_bundle", "adobe_brick", "logs", "raw_stone", "clay"],
    LASHING: ["bast_fiber", "reed_bundle"],
    CLASSICAL: ["lumber", "bricks", "raw_stone"],
    INDUSTRIAL: ["construction_components", "concrete", "bricks", "glass"],
    METAL: ["steel", "stainless_steel", "aluminum"],
    CONDUCTOR: ["copper", "aluminum"],
}

# A recipe's era is read off the materials it names, so a group can pick the
# pool that matches the building rather than a single global pool.
INDUSTRIAL_MARKERS = {"concrete", "construction_components", "steel"}
CLASSICAL_MARKERS = {"lumber", "bricks"}

# Materials whose pool never depends on the era of the recipe, as
# (category, minimum production quality).
ERA_INDEPENDENT = {
    "turf_block": (PRIMITIVE, 0),
    "reed_bundle": (PRIMITIVE, 0),
    "adobe_brick": (PRIMITIVE, 0),
    "logs": (PRIMITIVE, 0),
    "clay": (PRIMITIVE, 0),
    "bast_fiber": (LASHING, 0),
    "lumber": (CLASSICAL, 0),
    "concrete": (INDUSTRIAL, 0),
    "construction_components": (INDUSTRIAL, 0),
    "glass": (INDUSTRIAL, 0),
    "steel": (METAL, 0),
    "copper": (CONDUCTOR, 0),
    # The tools pool already carries five tiers with authored efficiencies;
    # bronze is the floor at which a workshop can be fitted out.
    "tools": (TOOLS, 2),
}


def era_of(groups: list[str]) -> str:
    if INDUSTRIAL_MARKERS.intersection(groups):
        return "industrial"
    if CLASSICAL_MARKERS.intersection(groups):
        return "classical"
    return "primitive"


def pool_for(good: str, era: str) -> tuple[str, int]:
    if good in ERA_INDEPENDENT:
        return ERA_INDEPENDENT[good]
    if good == "raw_stone":
        return (PRIMITIVE if era == "primitive" else CLASSICAL, 0)
    if good == "bricks":
        return (INDUSTRIAL if era == "industrial" else CLASSICAL, 0)
    # Functional equipment (chips, rolling stock, hulls) has no meaningful
    # substitute; leave those groups naming the exact good.
    return ("", 0)


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: pathlib.Path, text: str) -> None:
    # Godot rejects a BOM here, and PowerShell's default encoding adds one.
    path.write_text(text, encoding="utf-8", newline="\n")


def parse_string_array(text: str, field: str) -> list[str] | None:
    match = re.search(rf"^{field} = PackedStringArray\((.*)\)$", text, re.M)
    if match is None:
        return None
    body = match.group(1).strip()
    if not body:
        return []
    return [item.strip().strip('"') for item in body.split(",")]


def format_string_array(field: str, values: list[str]) -> str:
    return f"{field} = PackedStringArray({', '.join(f'\"{v}\"' for v in values)})"


def format_int_array(field: str, values: list[int]) -> str:
    return f"{field} = PackedInt32Array({', '.join(str(v) for v in values)})"


def replace_line(text: str, field: str, kind: str, line: str) -> str:
    return re.sub(rf"^{field} = {kind}\(.*\)$", line, text, count=1, flags=re.M)


pending_writes: list[tuple[pathlib.Path, str]] = []


def migrate_good(path: pathlib.Path) -> list[str]:
    good_id = path.stem
    wanted = [pool for pool, members in POOL_MEMBERS.items() if good_id in members]
    if not wanted:
        return []
    text = read(path)
    categories = parse_string_array(text, "substitution_category_ids")
    if categories is None:
        raise SystemExit(f"{good_id}: missing substitution_category_ids")
    added = [pool for pool in wanted if pool not in categories]
    if not added:
        return []
    categories.extend(added)
    text = replace_line(text, "substitution_category_ids", "PackedStringArray",
                        format_string_array("substitution_category_ids", categories))
    pending_writes.append((path, text))
    return [f"+{pool}" for pool in added]


def migrate_building(path: pathlib.Path) -> list[str]:
    text = read(path)
    groups = parse_string_array(text, "construction_good_ids")
    if not groups:
        return []

    era = era_of(groups)
    resolved = [pool_for(good, era) for good in groups]
    categories = [category for category, _ in resolved]
    min_levels = [level for _, level in resolved]
    if not any(categories):
        return []

    # The authored explicit lists only ever restated the preferred good, so they
    # offered no substitute at all and merely block the category branch.
    had_explicit = bool(parse_string_array(text, "construction_candidate_good_ids"))
    if had_explicit:
        text = replace_line(text, "construction_candidate_offsets", "PackedInt32Array",
                            "construction_candidate_offsets = PackedInt32Array(0)")
        text = replace_line(text, "construction_candidate_good_ids", "PackedStringArray",
                            "construction_candidate_good_ids = PackedStringArray()")
        text = replace_line(text, "construction_candidate_efficiency_q16", "PackedInt32Array",
                            "construction_candidate_efficiency_q16 = PackedInt32Array()")

    existing = parse_string_array(text, "construction_category_ids")
    if existing == categories and not had_explicit:
        return []

    category_line = format_string_array("construction_category_ids", categories)
    quality_line = format_int_array("construction_min_quality_levels", min_levels)

    if existing is None:
        anchor = re.search(r"^construction_quantities = PackedInt64Array\(.*\)$", text, re.M)
        if anchor is None:
            raise SystemExit(f"{path.stem}: missing construction_quantities anchor")
        text = text[: anchor.end()] + "\n" + category_line + "\n" + quality_line + text[anchor.end():]
    else:
        text = replace_line(text, "construction_category_ids", "PackedStringArray", category_line)
        if re.search(r"^construction_min_quality_levels = PackedInt32Array\(.*\)$", text, re.M):
            text = replace_line(text, "construction_min_quality_levels", "PackedInt32Array", quality_line)
        else:
            text = re.sub(r"^(construction_category_ids = PackedStringArray\(.*\))$",
                          r"\1\n" + quality_line, text, count=1, flags=re.M)

    pending_writes.append((path, text))
    return [f"{era}: " + ", ".join(f"{g}->{c or 'exact'}" for g, c in zip(groups, categories))]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    for path in sorted(GOODS.glob("*.tres")):
        changes = migrate_good(path)
        if changes:
            print(f"good {path.stem}: {', '.join(changes)}")

    eras = {"primitive": 0, "classical": 0, "industrial": 0}
    buildings = 0
    for path in sorted(BUILDINGS.glob("*.tres")):
        changes = migrate_building(path)
        if changes:
            buildings += 1
            eras[changes[0].split(":")[0]] += 1

    print(f"\nbuildings to update: {buildings} {eras}")
    if args.check:
        print("check only, nothing written")
        return 0
    for path, text in pending_writes:
        write(path, text)
    print(f"wrote {len(pending_writes)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
