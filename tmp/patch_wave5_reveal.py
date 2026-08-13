#!/usr/bin/env python3
"""Patch habitat-OR bypass reveal conditions (felt-making class)."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(r"d:\Godot\ProjectKeynes\Project.Keynes")
AUTHORING = ROOT / "Project/project-keynes/tools/build_technology_network_authoring.gd"
PATH = ROOT / "Project/project-keynes/data/technology/technology_network.json"

LIVESTOCK = ["bio.sheep", "bio.horse", "bio.cattle"]
CEREAL = ["bio.wheat", "bio.maize", "bio.rice"]

EVIDENCE: dict[str, list[str]] = {
    "tech.hunting": ["resource.wild_game"],
    "tech.gathering": ["resource.fertile_soil"],
    "tech.stone_knapping": ["resource.flint", "resource.stone"],
    "tech.fire_control": ["resource.timber"],
    "tech.freshwater_fishing": ["resource.freshwater_fish"],
    "tech.coastal_fishing": ["resource.marine_fish"],
    "tech.earth_building": ["resource.clay"],
    "tech.wild_tuber_collection": ["bio.potato", "contact.potato"],
    "tech.wild_flax_collection": ["bio.flax", "bio.bast_fiber", "contact.flax"],
    "tech.gold_panning": ["resource.gold_ore"],
    "tech.surface_silver_collection": ["resource.silver_ore"],
    "tech.deadwood_collection": ["resource.timber"],
    "tech.hide_scraping": ["resource.wild_game"],
    "tech.fur_sewing": ["resource.wild_game"],
    "tech.fishing_boats": ["resource.freshwater_fish", "resource.marine_fish"],
    "tech.herd_management": LIVESTOCK,
    "tech.charcoal_burning": ["resource.timber"],
    "tech.animal_husbandry": ["resource.wild_game", *LIVESTOCK],
    "tech.animal_tracking": ["resource.wild_game"],
    "tech.animal_traction": ["bio.horse", "bio.cattle"],
    "tech.hide_tanning": ["resource.wild_game", "bio.sheep"],
    "tech.pastoralism": LIVESTOCK,
    "tech.horse_domestication": ["bio.horse"],
    "tech.dairy_processing": ["bio.cattle"],
    "tech.wool_husbandry": ["bio.sheep"],
    "tech.meat_processing": ["resource.wild_game", "bio.cattle", "bio.sheep", "bio.pig"],
    "tech.spice_cultivation": ["bio.spice", "contact.spice"],
    "tech.spice_shade_gardening": ["bio.spice", "contact.spice"],
    "tech.cotton_gardening": ["bio.cotton", "contact.cotton"],
    "tech.maize_garden_horticulture": ["bio.maize", "contact.maize"],
    "tech.swidden_maize_cultivation": ["bio.maize", "contact.maize"],
    "tech.rainfed_maize_cultivation": ["bio.maize", "contact.maize"],
    "tech.flood_recession_maize": ["bio.maize", "contact.maize"],
    "tech.rainfed_wheat_cultivation": ["bio.wheat", "contact.wheat"],
    "tech.flood_recession_wheat": ["bio.wheat", "contact.wheat"],
    "tech.dryland_wheat_cultivation": ["bio.wheat", "contact.wheat"],
    "tech.upland_rice_propagation": ["bio.rice", "contact.rice"],
    "tech.wetland_rice_gardening": ["bio.rice", "contact.rice"],
    "tech.rice_paddy_cultivation": ["bio.rice", "contact.rice"],
    "tech.ridge_tuber_cultivation": ["bio.potato", "contact.potato"],
    "tech.highland_tuber_farming": ["bio.potato", "contact.potato"],
    "tech.adobe_making": ["resource.clay"],
    "tech.timber_sawing": ["resource.timber"],
    "tech.bark_paper_making": ["resource.timber"],
    "tech.turf_cutting": ["resource.pasture"],
    "tech.pastoral_route_memory": ["resource.pasture"],
    "tech.tenant_cereal_farming": CEREAL,
    "tech.manorial_cereal_farming": CEREAL,
    "tech.estate_cereal_management": CEREAL,
    "tech.forest_management": ["resource.timber", "breakthrough.forest_management"],
    "tech.estate_plantation_management": ["bio.spice", "bio.cotton"],
    "tech.pastoral_networks": LIVESTOCK,
    "tech.livestock_breeding": LIVESTOCK,
    "tech.modern_husbandry": LIVESTOCK,
    "tech.precision_instruments": [
        "breakthrough.metalworking",
        "breakthrough.kiln_temperature",
    ],
}


def gd_array(signals: list[str]) -> str:
    return "[" + ", ".join('"%s"' % s for s in signals) + "]"


def update_authoring() -> None:
    text = AUTHORING.read_text(encoding="utf-8")
    text = text.replace(
        '"branch.pastoral_livestock": ["resource.pasture", "landform.grassland", "bio.horse"],',
        '"branch.pastoral_livestock": ["bio.sheep", "bio.horse", "bio.cattle"],',
    )
    text = text.replace(
        '"branch.forest_biomass": ["resource.timber", "landform.forest", "breakthrough.forest_management"],',
        '"branch.forest_biomass": ["resource.timber", "breakthrough.forest_management"],',
    )
    text = text.replace(
        '{"tokens": ["horse", "pastoral", "livestock", "herd", "wool", "dairy", "meat"], "signals": ["resource.pasture", "landform.grassland", "bio.horse"]},',
        '{"tokens": ["horse"], "signals": ["bio.horse"]},\n'
        '\t{"tokens": ["wool"], "signals": ["bio.sheep"]},\n'
        '\t{"tokens": ["dairy"], "signals": ["bio.cattle"]},\n'
        '\t{"tokens": ["meat"], "signals": ["resource.wild_game", "bio.cattle", "bio.sheep", "bio.pig"]},\n'
        '\t{"tokens": ["pastoral", "livestock", "herd"], "signals": ["bio.sheep", "bio.horse", "bio.cattle"]},',
    )
    text = text.replace(
        '{"tokens": ["hide", "leather", "fur", "hunting", "animal"], "signals": ["resource.wild_game", "bio.sheep", "landform.grassland"]},',
        '{"tokens": ["hide", "leather", "fur", "hunting"], "signals": ["resource.wild_game"]},',
    )
    text = text.replace(
        '{"tokens": ["fish", "fishing"], "signals": ["resource.freshwater_fish", "resource.marine_fish", "landform.coast"]},',
        '{"tokens": ["fish", "fishing"], "signals": ["resource.freshwater_fish", "resource.marine_fish"]},',
    )
    text = text.replace(
        '{"tokens": ["forest", "timber", "wood", "woodblock", "lumber", "paper", "bark", "charcoal"], "signals": ["resource.timber", "landform.forest", "breakthrough.forest_management"]},',
        '{"tokens": ["timber", "wood", "woodblock", "lumber", "bark", "charcoal"], "signals": ["resource.timber"]},\n'
        '\t{"tokens": ["forest"], "signals": ["resource.timber", "breakthrough.forest_management"]},',
    )

    start = text.find("const EXPLICIT_EVIDENCE_BY_TECH :=")
    end = text.find("\n}", start)
    if start < 0 or end < 0:
        raise SystemExit("EXPLICIT_EVIDENCE_BY_TECH block missing")
    block = text[start:end]
    missing: list[str] = []
    for tech_id, signals in EVIDENCE.items():
        pattern = r'"%s": \[[^\]]*\]' % re.escape(tech_id)
        replacement = '"%s": %s' % (tech_id, gd_array(signals))
        new_block, n = re.subn(pattern, replacement, block, count=1)
        if n == 0:
            missing.append('\t"%s": %s,' % (tech_id, gd_array(signals)))
        else:
            block = new_block
    if missing:
        block = block.rstrip() + "\n" + "\n".join(missing)
    text = text[:start] + block + text[end:]
    AUTHORING.write_text(text, encoding="utf-8", newline="\n")
    print("authoring updated", len(EVIDENCE), "missing_inserted", len(missing))


def any_of(signals: list[str]) -> dict:
    return {
        "operator": 2,
        "children": [{"kind": 1, "id": sid, "value": 1} for sid in signals],
    }


def dump_block(spec: dict, indent: str) -> str:
    dumped = json.dumps(spec, ensure_ascii=False, indent="\t")
    lines = dumped.split("\n")
    return lines[0] + "\n" + "\n".join(indent + line for line in lines[1:])


def replace_object_after(text: str, key_idx: int) -> tuple[int, int]:
    brace = text.find("{", key_idx)
    depth = 0
    for i in range(brace, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return brace, i + 1
    raise RuntimeError("unbalanced braces")


def patch_json() -> None:
    text = PATH.read_text(encoding="utf-8")
    for tech_id, signals in EVIDENCE.items():
        needle = f'"id": "{tech_id}"'
        idx = text.find(needle)
        if idx < 0:
            raise SystemExit(f"missing {tech_id}")
        key = '"reveal_condition":'
        ridx = text.find(key, idx)
        next_id = text.find('\n\t\t{\n\t\t\t"id":', idx + len(needle))
        if next_id != -1 and ridx > next_id:
            raise SystemExit(f"reveal_condition not in {tech_id}")
        brace, end = replace_object_after(text, ridx)
        old = json.loads(text[brace:end])
        if int(old.get("operator", -1)) == 1:
            new_children = []
            replaced = False
            for child in old.get("children", []):
                if int(child.get("kind", -1)) == 0:
                    new_children.append(child)
                else:
                    new_children.append(any_of(signals))
                    replaced = True
            if not replaced:
                new_children.append(any_of(signals))
            new_spec = {"operator": 1, "children": new_children}
        else:
            new_spec = any_of(signals)
        line_start = text.rfind("\n", 0, ridx) + 1
        indent = text[line_start:ridx]
        text = text[:brace] + dump_block(new_spec, indent) + text[end:]
        print(f"patched {tech_id} -> {signals}")
    PATH.write_text(text, encoding="utf-8", newline="\n")
    print("json ok", PATH, "count", len(EVIDENCE))


def main() -> None:
    update_authoring()
    patch_json()


if __name__ == "__main__":
    main()
