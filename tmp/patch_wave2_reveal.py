#!/usr/bin/env python3
"""Patch wave-2 handling/production reveal conditions in technology_network.json."""
from __future__ import annotations

import json
from pathlib import Path

PATH = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\technology\technology_network.json")

EVIDENCE = {
    "tech.wild_maize_collection": ["bio.maize", "contact.maize"],
    "tech.maize_seed_saving": ["bio.maize", "contact.maize"],
    "tech.maize_propagation": ["bio.maize", "contact.maize"],
    "tech.maize_selection": ["bio.maize", "contact.maize", "breakthrough.maize_selection"],
    "tech.maize_garden_horticulture": ["bio.maize", "contact.maize", "resource.fertile_soil"],
    "tech.wild_wheat_collection": ["bio.wheat", "contact.wheat"],
    "tech.wheat_seed_saving": ["bio.wheat", "contact.wheat"],
    "tech.wheat_propagation": ["bio.wheat", "contact.wheat"],
    "tech.wild_rice_collection": ["bio.rice", "contact.rice"],
    "tech.rice_seed_saving": ["bio.rice", "contact.rice"],
    "tech.rice_paddy_cultivation": ["bio.rice", "resource.paddy_land", "breakthrough.paddy_control"],
    "tech.tuber_storage": ["bio.potato", "contact.potato"],
    "tech.potato_propagation": ["bio.potato", "contact.potato"],
    "tech.frost_protected_storage": ["bio.potato", "contact.potato"],
    "tech.ridge_tuber_cultivation": ["bio.potato", "landform.high_plateau", "breakthrough.terrace_maintenance"],
    "tech.wild_spice_collection": ["bio.spice", "contact.spice"],
    "tech.spice_cultivation": ["bio.spice", "contact.spice", "resource.plantation_land"],
    "tech.spice_shade_gardening": ["bio.spice", "contact.spice", "resource.plantation_land"],
    "tech.wild_latex_tapping": ["bio.rubber", "contact.rubber"],
    "tech.rubber_working": ["bio.rubber", "contact.rubber"],
    "tech.latex_smoke_coagulation": ["bio.rubber", "contact.rubber"],
    "tech.flax_retting": ["bio.flax", "bio.bast_fiber", "contact.flax"],
    "tech.fiber_twisting": ["bio.flax", "bio.cotton", "bio.bast_fiber"],
    "tech.weaving": ["bio.flax", "bio.cotton", "bio.bast_fiber"],
    "tech.loom_weaving": ["bio.flax", "bio.cotton", "bio.bast_fiber"],
    "tech.hand_spinning": ["bio.flax", "bio.cotton", "bio.bast_fiber"],
    "tech.plant_fiber_papermaking": ["bio.flax", "bio.cotton", "bio.bast_fiber"],
    "tech.textile_machinery": ["bio.cotton", "bio.flax", "breakthrough.industrial_organization"],
    "tech.synthetic_fiber_engineering": ["resource.oil", "breakthrough.chemical_process_control"],
    "tech.grain_threshing": ["bio.wheat", "bio.maize", "bio.rice"],
    "tech.grain_baking": ["bio.wheat", "contact.wheat"],
    "tech.tenant_cereal_farming": ["bio.wheat", "resource.arable_land", "breakthrough.rainfed_adaptation"],
    "tech.manorial_cereal_farming": ["bio.wheat", "resource.arable_land", "breakthrough.rainfed_adaptation"],
    "tech.estate_cereal_management": ["bio.wheat", "resource.arable_land", "breakthrough.rainfed_adaptation"],
    "tech.clay_preparation": ["resource.clay"],
    "tech.hand_pottery": ["resource.clay"],
    "tech.pottery": ["resource.clay", "breakthrough.kiln_temperature"],
    "tech.adobe_making": ["resource.clay", "landform.arid_basin", "weather.drought"],
    "tech.natural_copper_working": ["resource.copper_ore"],
    "tech.copper_annealing": ["resource.copper_ore", "breakthrough.metalworking"],
    "tech.copper_ore_roasting": ["resource.copper_ore", "breakthrough.metalworking"],
    "tech.copper_metallurgy": ["resource.copper_ore", "breakthrough.metalworking"],
    "tech.bronze_casting": ["resource.copper_ore", "resource.tin_ore", "contact.tin"],
    "tech.iron_smelting": ["resource.iron_ore", "resource.coal"],
    "tech.crucible_steel": ["resource.iron_ore", "resource.coal"],
    "tech.blast_furnace": ["resource.iron_ore", "resource.coal", "breakthrough.metalworking"],
    "tech.coke_smelting": ["resource.iron_ore", "resource.coal", "breakthrough.metalworking"],
    "tech.advanced_metallurgy": ["resource.iron_ore", "resource.copper_ore", "breakthrough.metalworking"],
    "tech.specialty_alloys": ["resource.iron_ore", "resource.copper_ore", "breakthrough.metalworking"],
    "tech.surface_iron_collection": ["resource.iron_ore"],
    "tech.surface_coal_use": ["resource.coal"],
    "tech.surface_coal_collection": ["resource.coal"],
    "tech.coal_mining": ["resource.coal"],
    "tech.coal_adit_mining": ["resource.coal"],
    "tech.industrial_coal_mining": ["resource.coal"],
    "tech.mine_ventilation": ["breakthrough.mine_support"],
    "tech.mine_drainage": ["breakthrough.mine_support", "landform.freshwater_access"],
    "tech.shaft_sinking": ["breakthrough.mine_support"],
    "tech.deep_mining": ["breakthrough.mine_support"],
    "tech.corporate_mining": ["breakthrough.mine_support"],
    "tech.mechanized_mining": ["breakthrough.mine_support", "breakthrough.industrial_organization"],
    "tech.autonomous_mining": ["breakthrough.mine_support", "breakthrough.automation"],
    "tech.magnetic_navigation": ["landform.coast", "breakthrough.maritime_operations"],
    "tech.celestial_navigation": ["landform.coast", "breakthrough.maritime_operations"],
    "tech.oceanic_navigation": ["landform.coast", "landform.coastal_estuary", "breakthrough.maritime_operations"],
    "tech.oceanic_ship_design": ["landform.coast", "breakthrough.maritime_operations"],
    "tech.coastal_shipyards": ["landform.coast", "breakthrough.maritime_operations"],
    "tech.oceanic_provisioning": ["landform.coast", "breakthrough.maritime_operations"],
    "tech.rail_logistics": ["breakthrough.steam_power", "breakthrough.industrial_organization"],
    "tech.global_logistics": ["breakthrough.industrial_organization", "breakthrough.assembly_line"],
    "tech.automated_logistics": ["breakthrough.automation", "breakthrough.digital_control"],
    "tech.autonomous_logistics": ["breakthrough.automation", "breakthrough.digital_control"],
}


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


def main() -> None:
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
    data = json.loads(PATH.read_text(encoding="utf-8"))
    ids = {n["id"] for n in data["nodes"]}
    for tech_id in EVIDENCE:
        if tech_id not in ids:
            raise SystemExit(f"lost {tech_id}")
    print("ok", PATH, "count", len(EVIDENCE))


if __name__ == "__main__":
    main()
