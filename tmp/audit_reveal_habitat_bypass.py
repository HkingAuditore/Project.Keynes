# -*- coding: utf-8 -*-
"""Audit reveal ANY_OF packs for felt-making-class habitat/object bypass."""
from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(r"D:/Godot/ProjectKeynes/Project.Keynes/Project/project-keynes")
NET = json.loads((ROOT / "data/technology/technology_network.json").read_text(encoding="utf-8"))

HABITAT = {
    "resource.pasture",
    "resource.arable_land",
    "resource.fertile_soil",
    "resource.plantation_land",
    "resource.paddy_land",
}
LANDFORM_PREFIX = "landform."
WEATHER_PREFIX = "weather."
BIO_PREFIX = "bio."
CONTACT_PREFIX = "contact."
RESOURCE_PREFIX = "resource."
BREAKTHROUGH_PREFIX = "breakthrough."

# Land-capacity resources that ARE the object for some techs.
LAND_OBJECT_TECH_TOKENS = {
    "pasture": {"resource.pasture"},
    "turf": {"resource.pasture"},
    "pastoral_route": {"resource.pasture"},
    "arable": {"resource.arable_land"},
    "dryland": {"resource.arable_land"},
    "rainfed": {"resource.arable_land"},
    "paddy": {"resource.paddy_land"},
    "plantation": {"resource.plantation_land"},
    "fertile": {"resource.fertile_soil"},
    "gathering": {"resource.fertile_soil"},
}

# Tech-id tokens -> expected object signals. Habitat must not OR-bypass these.
OBJECT_BY_TOKEN = {
    "sheep": {"bio.sheep"},
    "felt": {"bio.sheep"},
    "wool": {"bio.sheep"},
    "horse": {"bio.horse"},
    "cattle": {"bio.cattle"},
    "dairy": {"bio.cattle"},
    "goat": {"bio.goat"},
    "camel": {"bio.camel"},
    "pig": {"bio.pig"},
    "maize": {"bio.maize", "contact.maize"},
    "wheat": {"bio.wheat", "contact.wheat"},
    "rice": {"bio.rice", "contact.rice"},
    "potato": {"bio.potato", "contact.potato"},
    "tuber": {"bio.potato", "contact.potato"},
    "cotton": {"bio.cotton", "contact.cotton"},
    "flax": {"bio.flax", "bio.bast_fiber", "contact.flax"},
    "spice": {"bio.spice", "contact.spice"},
    "rubber": {"bio.rubber", "contact.rubber"},
    "latex": {"bio.rubber", "contact.rubber"},
    "reed": {"bio.reed"},
    "hunting": {"resource.wild_game"},
    "hide": {"resource.wild_game"},
    "fur": {"resource.wild_game"},
    "leather": {"resource.wild_game", "bio.sheep"},
    "game": {"resource.wild_game"},
    "fish": {"resource.freshwater_fish", "resource.marine_fish"},
    "fishing": {"resource.freshwater_fish", "resource.marine_fish"},
    "coastal_fishing": {"resource.marine_fish"},
    "freshwater_fishing": {"resource.freshwater_fish"},
    "copper": {"resource.copper_ore"},
    "tin": {"resource.tin_ore", "contact.tin"},
    "bronze": {"resource.copper_ore", "resource.tin_ore", "contact.tin"},
    "iron": {"resource.iron_ore"},
    "coal": {"resource.coal"},
    "gold": {"resource.gold_ore"},
    "silver": {"resource.silver_ore"},
    "clay": {"resource.clay"},
    "flint": {"resource.flint"},
    "salt": {"resource.salt"},
    "sulfur": {"resource.sulfur"},
    "oil": {"resource.oil"},
    "gas": {"resource.natural_gas"},
    "timber": {"resource.timber"},
    "wood": {"resource.timber"},
    "bark": {"resource.timber"},
    "charcoal": {"resource.timber"},
    "lumber": {"resource.timber"},
}

# Tokens that are generic enough that multi-object ANY_OF is OK.
GENERIC_TOKENS = {
    "fiber", "weaving", "loom", "spinning", "textile", "garment", "sewing",
    "grain", "cereal", "threshing", "baking",
    "metallurgy", "alloy", "steel", "coke",
    "mine", "mining", "shaft",
    "livestock", "herd", "pastoral", "animal",
    "forest", "paper", "printing",
    "navigation", "maritime", "ship", "port",
    "irrigation", "hydraulic", "canal", "water",
}


def kind_of(sig: str) -> str:
    if sig.startswith(BIO_PREFIX) or sig.startswith(CONTACT_PREFIX):
        return "object"
    if sig.startswith(LANDFORM_PREFIX):
        return "habitat"
    if sig.startswith(WEATHER_PREFIX):
        return "weather"
    if sig in HABITAT:
        return "habitat"
    if sig.startswith(RESOURCE_PREFIX):
        return "object"
    if sig.startswith(BREAKTHROUGH_PREFIX):
        return "practice"
    return "other"


def walk_anyof_packs(cond, packs: list) -> None:
    if not isinstance(cond, dict) or not cond:
        return
    op = cond.get("operator")
    children = cond.get("children") or []
    if op == 2:
        leaves = []
        nested = False
        for ch in children:
            if not isinstance(ch, dict):
                continue
            if ch.get("kind") == 1 and ch.get("id"):
                leaves.append(str(ch["id"]))
            elif "operator" in ch or ch.get("children"):
                nested = True
                walk_anyof_packs(ch, packs)
        if leaves and not nested:
            packs.append(leaves)
        elif leaves and nested:
            packs.append(leaves)
            for ch in children:
                if isinstance(ch, dict) and ("operator" in ch or ch.get("children")):
                    walk_anyof_packs(ch, packs)
        return
    for ch in children:
        walk_anyof_packs(ch, packs)


def all_leaf_signals(cond) -> list[str]:
    out = []
    if not isinstance(cond, dict) or not cond:
        return out
    if cond.get("kind") == 1 and cond.get("id"):
        out.append(str(cond["id"]))
    for ch in cond.get("children") or []:
        out.extend(all_leaf_signals(ch))
    return out


def expected_objects(tech_id: str) -> set[str]:
    stem = tech_id.replace("tech.", "")
    expected: set[str] = set()
    # longer tokens first
    for token, objs in sorted(OBJECT_BY_TOKEN.items(), key=lambda kv: -len(kv[0])):
        if token in stem:
            expected |= objs
    return expected


def is_generic_tech(tech_id: str) -> bool:
    stem = tech_id.replace("tech.", "")
    if any(tok in stem for tok in OBJECT_BY_TOKEN):
        return False
    return any(tok in stem for tok in GENERIC_TOKENS)


nodes = NET["nodes"]
bypass = []
cross_species = []
empty_prereq_habitat = []
cloned = Counter()
pack_users = defaultdict(list)

for node in nodes:
    tech_id = node["id"]
    name = node.get("display_name", "")
    era = node.get("era_id", "")
    role = node.get("node_role", "")
    starting = bool(node.get("is_starting") or node.get("is_starter_eligible"))
    hard = list(node.get("hard_prerequisite_ids") or [])
    packs = []
    walk_anyof_packs(node.get("reveal_condition") or {}, packs)
    leaves = all_leaf_signals(node.get("reveal_condition") or {})
    expected = expected_objects(tech_id)

    for pack in packs:
        key = tuple(sorted(pack))
        cloned[key] += 1
        pack_users[key].append(tech_id)
        kinds = {s: kind_of(s) for s in pack}
        objects = [s for s in pack if kinds[s] == "object"]
        habitats = [s for s in pack if kinds[s] == "habitat"]
        weather = [s for s in pack if kinds[s] == "weather"]
        if objects and habitats:
            # Definitional exception: reed identification/harvest with marsh/freshwater
            if tech_id in ("tech.reed_identification", "tech.reed_harvesting") and set(objects) <= {"bio.reed"}:
                continue
            # gold placer identification with freshwater
            if tech_id == "tech.gold_placer_identification" and set(objects) <= {"resource.gold_ore"}:
                continue
            bypass.append({
                "id": tech_id,
                "name": name,
                "era": era,
                "role": role,
                "starting": starting,
                "hard": hard,
                "objects": objects,
                "habitats": habitats,
                "pack": pack,
                "expected": sorted(expected),
            })
        # weather as OR with object (drought revealing maize without maize)
        if objects and weather and not habitats:
            bypass.append({
                "id": tech_id,
                "name": name,
                "era": era,
                "role": role,
                "starting": starting,
                "hard": hard,
                "objects": objects,
                "habitats": weather,
                "pack": pack,
                "expected": sorted(expected),
                "via": "weather",
            })

    # Cross-species: expected object exists but ANY_OF can fire without any expected
    if expected and packs:
        for pack in packs:
            if any(s in expected for s in pack):
                extras = [s for s in pack if s not in expected and kind_of(s) == "object"]
                if extras:
                    cross_species.append({
                        "id": tech_id,
                        "name": name,
                        "era": era,
                        "expected": sorted(expected),
                        "extras": extras,
                        "pack": pack,
                        "starting": starting,
                        "hard": hard,
                    })
            elif any(kind_of(s) == "object" for s in pack):
                # pack has objects but none are the expected ones
                cross_species.append({
                    "id": tech_id,
                    "name": name,
                    "era": era,
                    "expected": sorted(expected),
                    "extras": [s for s in pack if kind_of(s) == "object"],
                    "pack": pack,
                    "starting": starting,
                    "hard": hard,
                    "missing_expected": True,
                })

    if not hard and not node.get("is_milestone"):
        habitat_only_or = False
        for pack in packs:
            if any(kind_of(s) == "habitat" for s in pack) and len(pack) >= 2:
                habitat_only_or = True
        if habitat_only_or:
            empty_prereq_habitat.append({
                "id": tech_id,
                "name": name,
                "era": era,
                "starting": starting,
                "role": role,
                "leaves": leaves,
            })

# Dedup bypass by id+pack
seen = set()
uniq_bypass = []
for row in bypass:
    k = (row["id"], tuple(row["pack"]))
    if k in seen:
        continue
    seen.add(k)
    uniq_bypass.append(row)

cloned_rows = [
    {"n": n, "pack": list(pack), "users": pack_users[pack][:8], "user_count": n}
    for pack, n in cloned.most_common(25)
    if n >= 5
]

# Pastoral horse pack specifically
horse_pack_users = []
for node in nodes:
    packs = []
    walk_anyof_packs(node.get("reveal_condition") or {}, packs)
    for pack in packs:
        s = set(pack)
        if "bio.horse" in s and ("resource.pasture" in s or "landform.grassland" in s):
            horse_pack_users.append({
                "id": node["id"],
                "name": node.get("display_name"),
                "era": node.get("era_id"),
                "pack": pack,
                "hard": list(node.get("hard_prerequisite_ids") or []),
            })

# Hide/sheep/grassland pack
hide_pack_users = []
for node in nodes:
    packs = []
    walk_anyof_packs(node.get("reveal_condition") or {}, packs)
    for pack in packs:
        s = set(pack)
        if "bio.sheep" in s and "resource.wild_game" in s:
            hide_pack_users.append({
                "id": node["id"],
                "name": node.get("display_name"),
                "era": node.get("era_id"),
                "pack": pack,
            })

report = {
    "bypass_count": len(uniq_bypass),
    "bypass": uniq_bypass,
    "cross_species_count": len(cross_species),
    "cross_species": cross_species,
    "empty_prereq_habitat_count": len(empty_prereq_habitat),
    "empty_prereq_habitat": empty_prereq_habitat,
    "cloned": cloned_rows,
    "horse_pack": horse_pack_users,
    "hide_sheep_pack": hide_pack_users,
}

out_path = Path(r"D:/Godot/ProjectKeynes/Project.Keynes/tmp/reveal_habitat_audit.json")
out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print("bypass", len(uniq_bypass))
print("cross_species", len(cross_species))
print("empty_prereq_habitat", len(empty_prereq_habitat))
print("horse_pack", len(horse_pack_users))
print("hide_sheep_pack", len(hide_pack_users))
print("cloned_ge5", len(cloned_rows))
print("--- bypass sample ---")
for row in uniq_bypass[:40]:
    via = row.get("via", "habitat")
    print(f"{row['era']:12} {row['id']:40} {row['name']:16} hard={len(row['hard'])} start={int(row['starting'])} {via}")
    print(f"    objects={row['objects']}  proxy={row['habitats']}")
