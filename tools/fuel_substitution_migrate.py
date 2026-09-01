"""Let heat-source input slots accept any solid fuel of their era.

`solid_fuel` and `smelting_fuel` already existed as categories but had charcoal
as their only member and were referenced by no building at all, so a smelter
without charcoal simply could not run. This adds coal, coke and logs to those
pools and points the fuel slots at them.

Only slots that burn the good are converted. Where the good is the feedstock
being transformed -- logs into charcoal, coal into coke, logs into lumber --
the slot keeps naming the exact good.

Quality tiers keep the coal revolution meaningful: an industrial boiler may not
fall back to charcoal, and a coke blast furnace may not fall back to coal.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1] / "Project" / "project-keynes" / "data"
GOODS = ROOT / "goods"
BUILDINGS = ROOT / "economy" / "buildings"

SOLID = "solid_fuel"
SMELT = "smelting_fuel"

# Fuel rank doubles as the era gate. Charcoal and firewood stay at 0, coal is
# the industrial tier, coke the metallurgical one.
FUEL_TIERS = {"logs": 0, "charcoal": 0, "coal": 1, "coke": 2}
POOL_MEMBERS = {
    SOLID: ["logs", "charcoal", "coal", "coke"],
    SMELT: ["charcoal", "coal", "coke"],
}

# building -> (fuel good in that slot, pool, minimum tier)
SLOTS: dict[str, tuple[str, str, int]] = {}
for _b in ["bloomery", "early_copper_smelter", "copper_tool_workshop",
           "iron_tool_workshop", "ore_bronzesmith_camp"]:
    SLOTS[_b] = ("charcoal", SMELT, 0)
for _b in ["copper_plant", "lead_plant", "method_lead_plant_r9", "tin_plant",
           "zinc_plant", "method_zinc_plant_r9"]:
    SLOTS[_b] = ("coal", SMELT, 1)
SLOTS["steam_steel_works"] = ("coke", SMELT, 2)
for _b in ["fired_brick_kiln", "pottery_kiln", "open_pottery_hearth"]:
    SLOTS[_b] = ("charcoal", SOLID, 0)
for _b in ["method_pottery_kiln_r3", "classical_glass_kiln", "brine_boiling_hearth",
           "latex_smoking_shelter", "communal_hearth", "early_tin_smelter"]:
    SLOTS[_b] = ("logs", SOLID, 0)
for _b in ["atmospheric_engine_workshop", "electricity_plant", "glassware_factory",
           "leather_goods_factory", "metal_housewares_factory", "textile_mill",
           "method_lumber_plant_r6", "method_steam_shipping", "fertilizer_plant",
           "polytechnic_institute"]:
    SLOTS[_b] = ("coal", SOLID, 1)

pending: list[tuple[pathlib.Path, str]] = []


def parse_array(text: str, field: str, kind: str) -> list[str] | None:
    m = re.search(rf"^{field} = {kind}\((.*)\)$", text, re.M)
    if m is None:
        return None
    body = m.group(1).strip()
    return [] if not body else [v.strip().strip('"') for v in body.split(",")]


def set_line(text: str, field: str, kind: str, values: list[str], quote: bool) -> str:
    body = ", ".join(f'"{v}"' if quote else str(v) for v in values)
    line = f"{field} = {kind}({body})"
    if re.search(rf"^{field} = {kind}\(.*\)$", text, re.M):
        return re.sub(rf"^{field} = {kind}\(.*\)$", line, text, count=1, flags=re.M)
    anchor = re.search(r"^input_quantities_per_day = PackedInt64Array\(.*\)$", text, re.M)
    if anchor is None:
        raise SystemExit(f"missing input anchor for {field}")
    return text[: anchor.end()] + "\n" + line + text[anchor.end():]


def migrate_good(path: pathlib.Path) -> list[str]:
    good = path.stem
    wanted = [p for p, members in POOL_MEMBERS.items() if good in members]
    if not wanted:
        return []
    text = path.read_text(encoding="utf-8")
    cats = parse_array(text, "substitution_category_ids", "PackedStringArray")
    if cats is None:
        raise SystemExit(f"{good}: no substitution_category_ids")
    added = [p for p in wanted if p not in cats]
    changes = [f"+{p}" for p in added]
    if added:
        text = set_line(text, "substitution_category_ids", "PackedStringArray",
                        cats + added, True)

    tier = FUEL_TIERS[good]
    m = re.search(r"^production_quality_level = (-?\d+)$", text, re.M)
    if m is None:
        # Absent means the exported default of 0, which is already correct for
        # the firewood and charcoal tier.
        if tier != 0:
            anchor = re.search(r"^substitution_category_ids = PackedStringArray\(.*\)$", text, re.M)
            text = text[: anchor.end()] + f"\nproduction_quality_level = {tier}" + text[anchor.end():]
            changes.append(f"quality ->{tier}")
    elif int(m.group(1)) != tier:
        if int(m.group(1)) > tier:
            raise SystemExit(f"{good}: refusing to lower quality")
        text = re.sub(r"^production_quality_level = -?\d+$",
                      f"production_quality_level = {tier}", text, count=1, flags=re.M)
        changes.append(f"quality {m.group(1)}->{tier}")

    if changes:
        pending.append((path, text))
    return changes


def migrate_building(path: pathlib.Path) -> str | None:
    rule = SLOTS.get(path.stem)
    if rule is None:
        return None
    fuel, pool, min_tier = rule
    text = path.read_text(encoding="utf-8")
    inputs = parse_array(text, "input_good_ids", "PackedStringArray")
    if not inputs or fuel not in inputs:
        raise SystemExit(f"{path.stem}: expected input {fuel}, found {inputs}")
    slot = inputs.index(fuel)

    # Some recipes already carry a hand-tuned explicit candidate list with
    # per-slot efficiencies, which is strictly better than a category because a
    # good's global efficiency cannot vary by use. Leave those alone.
    offsets = [int(v) for v in (parse_array(text, "input_candidate_offsets", "PackedInt32Array") or [])]
    if len(offsets) == len(inputs) + 1 and offsets[slot + 1] - offsets[slot] > 1:
        return None

    cats = parse_array(text, "input_category_ids", "PackedStringArray") or []
    levels = parse_array(text, "input_min_quality_levels", "PackedInt32Array") or []
    cats = (cats + [""] * len(inputs))[: len(inputs)]
    levels = [int(v) for v in (levels + ["0"] * len(inputs))[: len(inputs)]]
    if cats[slot] == pool and levels[slot] == min_tier:
        return None
    if cats[slot]:
        raise SystemExit(f"{path.stem}: slot {fuel} already uses {cats[slot]}")
    cats[slot] = pool
    levels[slot] = min_tier

    text = set_line(text, "input_category_ids", "PackedStringArray", cats, True)
    text = set_line(text, "input_min_quality_levels", "PackedInt32Array", levels, False)
    pending.append((path, text))
    return f"{path.stem}: {fuel} -> {pool}@{min_tier}"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    for path in sorted(GOODS.glob("*.tres")):
        changes = migrate_good(path)
        if changes:
            print(f"good {path.stem}: {', '.join(changes)}")
    print()
    count = 0
    for path in sorted(BUILDINGS.glob("*.tres")):
        line = migrate_building(path)
        if line:
            count += 1
            print(f"  {line}")
    missing = set(SLOTS) - {p.stem for p in BUILDINGS.glob("*.tres")}
    if missing:
        raise SystemExit(f"unknown buildings in rule table: {sorted(missing)}")
    print(f"\nfuel slots converted: {count}")
    if args.check:
        print("check only, nothing written")
        return 0
    for path, text in pending:
        path.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {len(pending)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
