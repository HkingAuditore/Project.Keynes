#!/usr/bin/env python3
"""Extract economy vocabulary from Project.Keynes .tres files."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "Project" / "project-keynes"
OUT = Path(__file__).resolve().parent / "economy_vocab.json"


def parse_tres(path: Path) -> dict:
    data = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("[") or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip()
    return data


def strip_godot_string(s: str) -> str:
    s = s.strip()
    if s.startswith("&"):
        s = s[1:]
    return s.strip('"').strip("'")


def strip_plain_value(s: str) -> str:
    return strip_godot_string(s)


def parse_string_array(s: str) -> list:
    s = s.strip()
    if s in ("PackedStringArray()", "Array()"):
        return []
    m = re.match(r"(?:PackedString)?Array\((.*)\)", s, re.DOTALL)
    if not m:
        return [strip_godot_string(s)] if s else []
    inner = m.group(1).strip()
    if not inner:
        return []
    parts = []
    for item in inner.split(","):
        item = item.strip()
        if item:
            parts.append(strip_godot_string(item))
    return parts


TIER_MAP = {0: "subsistence", 1: "basic", 2: "comfort", 3: "luxury"}


def load_goods():
    items = []
    for f in sorted((ROOT / "data/goods").glob("*.tres")):
        d = parse_tres(f)
        items.append({
            "id": strip_godot_string(d.get("id", f.stem)),
            "file": str(f.relative_to(ROOT)).replace("\\", "/"),
            "category_id": strip_godot_string(d.get("category_id", "")),
            "substitution_category_ids": parse_string_array(
                d.get("substitution_category_ids", "PackedStringArray()")
            ),
            "semantic_tags": parse_string_array(d.get("semantic_tags", "PackedStringArray()")),
            "technology_tags": parse_string_array(d.get("technology_tags", "PackedStringArray()")),
        })
    return items


def load_needs():
    items = []
    for f in sorted((ROOT / "data/economy/needs").glob("*.tres")):
        d = parse_tres(f)
        tier_raw = int(d.get("satisfaction_tier", "1"))
        items.append({
            "id": strip_godot_string(d.get("id", f.stem)),
            "file": str(f.relative_to(ROOT)).replace("\\", "/"),
            "satisfaction_tier": TIER_MAP.get(tier_raw, str(tier_raw)),
            "use_tags": parse_string_array(d.get("use_tags", "PackedStringArray()")),
            "semantic_tags": parse_string_array(d.get("semantic_tags", "PackedStringArray()")),
        })
    return items


def load_professions():
    items = []
    for f in sorted((ROOT / "data/economy/professions").glob("*.tres")):
        d = parse_tres(f)
        items.append({
            "id": strip_godot_string(d.get("id", f.stem)),
            "file": str(f.relative_to(ROOT)).replace("\\", "/"),
            "profession_class_id": strip_godot_string(d.get("profession_class_id", "general")),
            "semantic_tags": parse_string_array(d.get("semantic_tags", "PackedStringArray()")),
            "technology_tags": parse_string_array(d.get("technology_tags", "PackedStringArray()")),
        })
    return items


def load_buildings():
    items = []
    for f in sorted((ROOT / "data/economy/buildings").glob("*.tres")):
        d = parse_tres(f)
        items.append({
            "id": strip_godot_string(d.get("id", f.stem)),
            "file": str(f.relative_to(ROOT)).replace("\\", "/"),
            "building_kind": strip_plain_value(d.get("building_kind", "industrial")),
            "economic_sector_id": strip_plain_value(d.get("economic_sector_id", "")),
            "semantic_tags": parse_string_array(d.get("semantic_tags", "PackedStringArray()")),
            "technology_tags": parse_string_array(d.get("technology_tags", "PackedStringArray()")),
            "required_technology_tags": parse_string_array(
                d.get("required_technology_tags", "PackedStringArray()")
            ),
            "input_good_ids": parse_string_array(d.get("input_good_ids", "PackedStringArray()")),
            "input_category_ids": parse_string_array(
                d.get("input_category_ids", "PackedStringArray()")
            ),
            "output_good_ids": parse_string_array(d.get("output_good_ids", "PackedStringArray()")),
            "resource_ids": parse_string_array(d.get("resource_ids", "PackedStringArray()")),
        })
    return items


def load_resources_from_registry():
    reg = (ROOT / "scripts/data/resource_profile_registry.gd").read_text(encoding="utf-8")
    paths = re.findall(r'"res://data/resources/([^"]+\.tres)"', reg)
    items = []
    for rel in paths:
        f = ROOT / "data/resources" / rel
        d = parse_tres(f)
        items.append({
            "id": strip_godot_string(d.get("id", rel.replace(".tres", ""))),
            "file": f"data/resources/{rel}",
            "reserve_component": strip_godot_string(d.get("reserve_component", "")),
            "habitat_mode": d.get("habitat_mode", "legacy"),
            "semantic_tags": parse_string_array(d.get("semantic_tags", "PackedStringArray()")),
            "discovery_technology_tags": parse_string_array(
                d.get("discovery_technology_tags", "PackedStringArray()")
            ),
        })
    return items


def build_resource_extractors(buildings):
    mapping = {}
    for b in buildings:
        for rid in b["resource_ids"]:
            mapping.setdefault(rid, []).append(b["id"])
    for rid in mapping:
        mapping[rid] = sorted(set(mapping[rid]))
    return mapping


def load_settlement_tiers():
    sp = ROOT / "scripts/data/settlement_profile.gd"
    text = sp.read_text(encoding="utf-8")
    tier_ids = parse_string_array(re.search(r'tier_ids := PackedStringArray\(\[(.*?)\]\)', text, re.S).group(1))
    tier_names = parse_string_array(re.search(r'tier_names := PackedStringArray\(\[(.*?)\]\)', text, re.S).group(1))
    thresholds_raw = re.search(r'population_thresholds := PackedInt64Array\(\[(.*?)\]\)', text, re.S).group(1)
    thresholds = [int(x.strip()) for x in thresholds_raw.split(",") if x.strip()]
    named_tier = int(re.search(r"named_tier: int = (\d+)", text).group(1))
    return {
        "schema_file": "scripts/data/settlement_profile.gd",
        "tier_ids": tier_ids,
        "tier_names": tier_names,
        "population_thresholds": thresholds,
        "named_tier_index": named_tier,
    }


def collect_unique_categories(goods):
    cats = set()
    sub_cats = set()
    for g in goods:
        if g["category_id"]:
            cats.add(g["category_id"])
        sub_cats.update(g["substitution_category_ids"])
    return sorted(cats), sorted(sub_cats)


def main():
    goods = load_goods()
    needs = load_needs()
    professions = load_professions()
    buildings = load_buildings()
    resources = load_resources_from_registry()
    settlement = load_settlement_tiers()
    resource_extractors = build_resource_extractors(buildings)
    good_categories, substitution_categories = collect_unique_categories(goods)
    profession_classes = sorted({p["profession_class_id"] for p in professions})

    out = {
        "schema_files": {
            "good_profile": "scripts/data/good_profile.gd",
            "good_registry": "scripts/data/good_profile_registry.gd",
            "building_profile": "scripts/data/building_profile.gd",
            "profession_profile": "scripts/data/profession_profile.gd",
            "need_profile": "scripts/data/need_profile.gd",
            "resource_profile": "scripts/data/resource_profile.gd",
            "resource_registry": "scripts/data/resource_profile_registry.gd",
            "economy_profile": "scripts/data/economy_profile.gd",
            "settlement_profile": "scripts/data/settlement_profile.gd",
        },
        "data_paths": {
            "goods": "data/goods/*.tres",
            "buildings": "data/economy/buildings/*.tres",
            "professions": "data/economy/professions/*.tres",
            "needs": "data/economy/needs/*.tres",
            "resources": "data/resources/*.tres",
            "default_economy": "data/economy/default_economy.tres",
        },
        "counts": {
            "goods": len(goods),
            "buildings": len(buildings),
            "professions": len(professions),
            "needs": len(needs),
            "natural_resources": len(resources),
            "good_category_ids": len(good_categories),
            "substitution_category_ids": len(substitution_categories),
            "profession_class_ids": len(profession_classes),
        },
        "good_category_ids": good_categories,
        "substitution_category_ids": substitution_categories,
        "profession_class_ids": profession_classes,
        "goods": goods,
        "needs": needs,
        "professions": professions,
        "buildings": buildings,
        "natural_resources": resources,
        "resource_extractors": resource_extractors,
        "settlement_tiers": settlement,
    }
    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")

    goods_table = OUT.parent / "goods_table.txt"
    with goods_table.open("w", encoding="utf-8") as fh:
        for g in goods:
            subs = g["substitution_category_ids"] or [g["category_id"]]
            tags = ", ".join(g["semantic_tags"]) if g["semantic_tags"] else "-"
            fh.write(
                f"{g['id']}\t{g['category_id']}\t{';'.join(subs)}\t{tags}\n"
            )

    buildings_table = OUT.parent / "buildings_table.txt"
    with buildings_table.open("w", encoding="utf-8") as fh:
        for b in buildings:
            ins = ";".join(
                b["input_good_ids"]
                + [f"cat:{c}" for c in b["input_category_ids"] if c]
            )
            fh.write(
                "\t".join([
                    b["id"],
                    b["economic_sector_id"],
                    b["building_kind"],
                    ins or "-",
                    ";".join(b["output_good_ids"]) or "-",
                    ";".join(b["resource_ids"]) or "-",
                    ";".join(b["technology_tags"]) or "-",
                    ";".join(b["required_technology_tags"]) or "-",
                    ";".join(b["semantic_tags"]) or "-",
                ])
                + "\n"
            )

    print(json.dumps(out["counts"], indent=2))


if __name__ == "__main__":
    main()
