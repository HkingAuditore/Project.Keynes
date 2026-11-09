#!/usr/bin/env python3
"""Audit adjacent technology building unlocks that produce the same goods."""

from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "data" / "technology" / "technology_network.json"
BUILDINGS_DIR = ROOT / "data" / "economy" / "buildings"
REPORT = ROOT / "tools" / "technology_tree" / "technology_unlock_progression_audit.md"

# Every same-output relationship requires a semantic review. New relationships
# deliberately fail until an author classifies them here.
REVIEWED_RELATIONS = {
    ("tech.agricultural_improvement", "tech.mechanized_agriculture"): "upgrade",
    ("tech.atmospheric_engine", "tech.steam_power"): "upgrade",
    ("tech.automated_logistics", "tech.autonomous_logistics"): "upgrade",
    ("tech.canning", "tech.industrial_canning"): "upgrade",
    ("tech.coal_adit_mining", "tech.coal_mining"): "upgrade",
    ("tech.deep_geophysics", "tech.mineral_spectral_survey"): "upgrade",
    ("tech.digital_computing", "tech.software_engineering"): "upgrade",
    ("tech.digital_control", "tech.robotic_manufacturing"): "upgrade",
    ("tech.early_knowledge_institution", "tech.flood_calendar_practice"): "specialization",
    ("tech.early_knowledge_institution", "tech.oral_memory_practice"): "specialization",
    ("tech.early_knowledge_institution", "tech.pastoral_route_memory"): "specialization",
    ("tech.early_knowledge_institution", "tech.phenology_observation"): "specialization",
    ("tech.early_knowledge_institution", "tech.tide_observation"): "specialization",
    ("tech.electric_generation", "tech.nuclear_energy"): "specialization",
    ("tech.fiber_twisting", "tech.fur_sewing"): "specialization",
    ("tech.flood_recession_wheat", "tech.dryland_wheat_cultivation"): "specialization",
    ("tech.ground_stone_tools", "tech.masonry"): "upgrade",
    ("tech.guild_apprenticeship", "tech.manufactory_system"): "upgrade",
    ("tech.gunpowder_formulation", "tech.military.corned_powder"): "upgrade",
    ("tech.gunpowder_formulation", "tech.military.nitre_beds"): "specialization",
    ("tech.hand_spinning", "tech.weaving"): "upgrade",
    ("tech.hide_scraping", "tech.fur_sewing"): "specialization",
    ("tech.hunting", "tech.animal_tracking"): "specialization",
    ("tech.industrial_agronomy", "tech.precision_agriculture"): "upgrade",
    ("tech.industrial_chemistry", "tech.electrochemistry"): "specialization",
    ("tech.kiln_firing", "tech.masonry"): "upgrade",
    ("tech.maize_garden_horticulture", "tech.swidden_maize_cultivation"): "specialization",
    ("tech.masonry", "tech.canal_engineering"): "upgrade",
    ("tech.masonry", "tech.urban_waterworks"): "upgrade",
    ("tech.mechanized_mining", "tech.autonomous_mining"): "upgrade",
    ("tech.military.corned_powder", "tech.military.powder_milling"): "upgrade",
    ("tech.military.smokeless_powder", "tech.military.continuous_nitration"): "upgrade",
    ("tech.modern_medicine", "tech.biotechnology"): "specialization",
    ("tech.movable_type_printing", "tech.screw_press_printing"): "upgrade",
    ("tech.petroleum_extraction", "tech.petroleum_drilling"): "upgrade",
    ("tech.plant_fiber_papermaking", "tech.rag_paper_making"): "alternative_method",
    ("tech.potato_propagation", "tech.ridge_tuber_cultivation"): "specialization",
    ("tech.precision_agriculture", "tech.automated_agriculture"): "upgrade",
    ("tech.precision_irrigation", "tech.adaptive_irrigation"): "upgrade",
    ("tech.rainfed_maize_cultivation", "tech.flood_recession_maize"): "specialization",
    ("tech.rainfed_wheat_cultivation", "tech.flood_recession_wheat"): "specialization",
    ("tech.ridge_tuber_cultivation", "tech.highland_tuber_farming"): "specialization",
    ("tech.salt_preservation", "tech.solar_evaporation"): "alternative_method",
    ("tech.satellite_observation", "tech.autonomous_forestry_operations"): "upgrade",
    ("tech.scholarly_academies", "tech.chartered_universities"): "upgrade",
    ("tech.spice_shade_gardening", "tech.spice_cultivation"): "upgrade",
    ("tech.surface_coal_collection", "tech.coal_adit_mining"): "upgrade",
    ("tech.swidden_maize_cultivation", "tech.rainfed_maize_cultivation"): "alternative_method",
    ("tech.tenant_paddy_management", "tech.estate_paddy_management"): "alternative_method",
    ("tech.textile_machinery", "tech.synthetic_fiber_engineering"): "specialization",
    ("tech.timber_sawing", "tech.forest_management"): "specialization",
    ("tech.timber_sawing", "tech.steam_sawmilling"): "upgrade",
    ("tech.timber_sawing", "tech.water_power"): "upgrade",
    ("tech.upland_rice_propagation", "tech.wetland_rice_gardening"): "specialization",
    ("tech.weaving", "tech.textile_machinery"): "upgrade",
    ("tech.wetland_rice_gardening", "tech.rice_water_control"): "upgrade",
    ("tech.wild_cotton_collection", "tech.cotton_gardening"): "specialization",
    ("tech.wild_spice_collection", "tech.spice_shade_gardening"): "specialization",
    ("tech.woodblock_printing", "tech.movable_type_printing"): "upgrade",
}
ALLOWED_CLASSIFICATIONS = {"upgrade", "specialization", "alternative_method"}
IDENTIFICATION_STARTER_BUILDINGS = {
    # Initial shallow tin prospecting is an intentionally primitive first
    # extractor; the mine is still gated by the completed tool-foundation chain.
    ("tech.tin_identification", "early_tin_mine"),
}


def packed_strings(text: str, field: str) -> list[str]:
    match = re.search(rf"^{re.escape(field)}\s*=\s*PackedStringArray\((.*?)\)$", text,
                      re.MULTILINE | re.DOTALL)
    return re.findall(r'"([^"]+)"', match.group(1)) if match else []


def scalar(text: str, field: str, default: str = "") -> str:
    match = re.search(rf"^{re.escape(field)}\s*=\s*(?:&)?\"([^\"]*)\"$", text, re.MULTILINE)
    return match.group(1) if match else default


def integer(text: str, field: str) -> int:
    match = re.search(rf"^{re.escape(field)}\s*=\s*(-?\d+)$", text, re.MULTILINE)
    return int(match.group(1)) if match else 0


def load_buildings() -> dict[str, dict]:
    buildings: dict[str, dict] = {}
    for path in sorted(BUILDINGS_DIR.glob("*.tres")):
        text = path.read_text(encoding="utf-8")
        technology_ids = [tag for tag in packed_strings(text, "technology_tags")
                          if tag.startswith("tech.")]
        buildings[path.stem] = {
            "id": path.stem,
            "name": scalar(text, "display_name", path.stem),
            "technology_ids": technology_ids,
            "required_technology_ids": [tag for tag in packed_strings(
                text, "required_technology_tags") if tag.startswith("tech.")],
            "outputs": set(packed_strings(text, "output_good_ids")),
            "family": scalar(text, "upgrade_family_id"),
            "tier": integer(text, "upgrade_tier"),
        }
    return buildings


def main() -> int:
    payload = json.loads(NETWORK.read_text(encoding="utf-8"))
    nodes = payload["nodes"]
    node_by_id = {node["id"]: node for node in nodes}
    buildings = load_buildings()
    direct_by_technology: dict[str, list[dict]] = defaultdict(list)
    for building in buildings.values():
        for technology_id in building["technology_ids"]:
            direct_by_technology[technology_id].append(building)

    errors: list[str] = []
    identification_violations: list[str] = []
    seen_identification_starters: set[tuple[str, str]] = set()
    for node in nodes:
        if node.get("node_role") != "identification":
            continue
        for building in direct_by_technology[node["id"]]:
            if (node["id"], building["id"]) in IDENTIFICATION_STARTER_BUILDINGS:
                seen_identification_starters.add((node["id"], building["id"]))
                continue
            ancestry = set()
            frontier = list(node.get("hard_prerequisite_ids", []))
            while frontier:
                prerequisite = frontier.pop()
                if prerequisite in ancestry:
                    continue
                ancestry.add(prerequisite)
                frontier.extend(node_by_id[prerequisite].get("hard_prerequisite_ids", []))
            independent_support = set(building["required_technology_ids"]) - ancestry
            if not independent_support:
                identification_violations.append(f"{node['id']} -> {building['id']}")
    if identification_violations:
        errors.extend(f"identification directly unlocks building: {row}"
                      for row in identification_violations)
    for relation in sorted(IDENTIFICATION_STARTER_BUILDINGS - seen_identification_starters):
        errors.append(f"reviewed identification starter no longer exists: {relation[0]} -> {relation[1]}")

    relations: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for target in nodes:
        target_buildings = direct_by_technology[target["id"]]
        if not target_buildings:
            continue
        for source_id in target.get("hard_prerequisite_ids", []):
            for source_building in direct_by_technology[source_id]:
                for target_building in target_buildings:
                    shared = sorted(source_building["outputs"] & target_building["outputs"])
                    if shared:
                        relations[(source_id, target["id"])].append({
                            "source": source_building, "target": target_building,
                            "outputs": shared,
                        })

    actual = set(relations)
    reviewed = set(REVIEWED_RELATIONS)
    for edge in sorted(actual - reviewed):
        errors.append(f"unreviewed same-output relationship: {edge[0]} -> {edge[1]}")
    for edge in sorted(reviewed - actual):
        errors.append(f"reviewed relationship no longer exists: {edge[0]} -> {edge[1]}")
    for edge, classification in REVIEWED_RELATIONS.items():
        if classification not in ALLOWED_CLASSIFICATIONS:
            errors.append(f"invalid classification {classification}: {edge[0]} -> {edge[1]}")

    tier_violations: list[str] = []
    for edge, pairs in relations.items():
        for pair in pairs:
            source, target = pair["source"], pair["target"]
            if not source["family"] or source["family"] != target["family"]:
                continue
            if target["tier"] <= source["tier"]:
                row = (f"{edge[0]}:{source['id']} T{source['tier']} -> "
                       f"{edge[1]}:{target['id']} T{target['tier']} "
                       f"({source['family']})")
                tier_violations.append(row)
    errors.extend(f"upgrade tier does not increase: {row}" for row in tier_violations)

    names = {node_id: node["display_name"] for node_id, node in node_by_id.items()}
    lines = [
        "# Technology Unlock Progression Audit", "",
        f"- Reviewed same-output technology edges: `{len(relations)}`",
        f"- Reviewed building pairs: `{sum(len(rows) for rows in relations.values())}`",
        f"- Identification nodes with direct building unlocks: `{len(identification_violations)}`",
        f"- Non-increasing same-family upgrade pairs: `{len(tier_violations)}`",
        f"- Result: `{'FAIL' if errors else 'PASS'}`", "",
        "## Reviewed Relations", "",
        "| Source | Target | Classification | Shared output building pairs |", 
        "|---|---|---|---|",
    ]
    for edge in sorted(relations):
        pair_text = "; ".join(
            f"{row['source']['name']} -> {row['target']['name']} ({', '.join(row['outputs'])})"
            for row in relations[edge])
        lines.append(
            f"| {names.get(edge[0], edge[0])} (`{edge[0]}`) | "
            f"{names.get(edge[1], edge[1])} (`{edge[1]}`) | "
            f"`{REVIEWED_RELATIONS.get(edge, 'UNREVIEWED')}` | {pair_text} |")
    lines.extend(["", "## Violations", ""])
    lines.extend(f"- {error}" for error in errors)
    if not errors:
        lines.append("- None.")
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")

    if errors:
        for error in errors:
            print(f"[FAIL] {error}")
        print(f"[FAIL] wrote {REPORT}")
        return 1
    print(f"[PASS] reviewed {len(relations)} same-output technology edges "
          f"({sum(len(rows) for rows in relations.values())} building pairs)")
    print(f"[PASS] wrote {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
