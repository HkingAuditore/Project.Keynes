#!/usr/bin/env python3
"""Scan technology_network.json modifier packages for filler, thin, and mix gaps."""

from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "data/technology/technology_network.json"

BROAD_PREFIXES = (
    "country.economy_output_factor",
    "country.production.input_factor",
    "country.household.consumption_factor",
    "country.resource.use_factor",
    "country.output.agriculture_factor",
    "country.output.extractive_factor",
    "country.output.manufacturing_factor",
    "country.output.energy_factor",
    "country.output.knowledge_factor",
    "country.research.",
    "country.trade.",
)
CLIMATE_STATS = {
    "country.climate.drought_loss_factor",
    "country.climate.flood_loss_factor",
    "country.climate.cold_stress_factor",
    "country.climate.heat_stress_factor",
}
CONSTRUCTION_STATS = {
    "country.construction.cost_factor",
    "country.construction.time_factor",
}

# Topic tokens that make a family honest. Order does not matter; any hit is enough.
FAMILY_TOPIC = {
    "paper_making": ("paper", "print", "manuscript", "bark", "rag", "writing", "book"),
    "research_institution": (
        "research", "science", "knowledge", "comput", "software", "algorithm",
        "network", "information", "learning", "neural", "agent", "education",
        "laboratory", "observ", "classif", "philosoph", "scholastic", "cartograph",
        "calendar", "writing", "print", "instrument", "society", "university",
    ),
    "metal_toolmaking": (
        "tool", "machine", "machinery", "precision", "standard", "parts", "flint",
        "bronze", "alloy", "metallurgy", "interchange", "quality", "control",
        "automation", "robot", "timekeeping", "clock", "chronometer",
    ),
    "maritime_operations": (
        "maritime", "ocean", "ship", "port", "navigation", "logistics", "coast",
        "fish", "trade", "merchant", "company", "exchange",
    ),
    "construction_methods": (
        "construction", "masonry", "adobe", "earth", "urban", "canal", "irrigation",
        "hydraulic", "cement", "concrete", "brick", "kiln", "pottery", "stone",
        "waterwork", "sanitation",
    ),
    "field_crop_farming": (
        "maize", "wheat", "rice", "grain", "cereal", "rainfed", "paddy", "crop",
        "farm", "agronom", "horticult", "garden", "seed", "tenant", "manorial",
        "estate", "rotation",
    ),
    "highland_crop_farming": ("potato", "tuber", "terrace", "highland", "frost"),
    "staple_preparation": (
        "food", "storage", "preserv", "granary", "ferment", "canning", "staple",
        "bread", "provision",
    ),
    "bread_baking": ("bread", "wheat", "grain", "cereal"),
    "livestock_husbandry": (
        "pastoral", "livestock", "herd", "animal", "husbandry", "cattle", "sheep",
        "horse",
    ),
    "horse_breeding": ("horse",),
    "dairy_processing": ("dairy",),
    "meat_processing": ("meat", "slaughter"),
    "wool_processing": ("wool", "felt"),
    "leather_processing": ("hide", "leather", "fur", "tann"),
    "cloth_weaving": ("cotton", "flax", "fiber", "weav", "loom", "spin", "textile"),
    "garment_making": ("garment", "cloth", "sewing", "fur", "felt"),
    "chemical_industry": (
        "chemical", "chemistry", "sulfur", "gunpowder", "explosive", "rubber",
        "latex", "plastic", "synthetic", "medicine", "electrochem",
    ),
    "fertilizer_making": ("fertilizer", "phosphate"),
    "specialty_commodity_crops": ("spice", "rubber", "plantation", "commodity"),
    "fine_furniture_making": ("timber", "wood", "lumber", "sawmill", "charcoal", "furniture"),
    "precision_forestry": ("forest", "forestry"),
    "freshwater_fishing": ("fish", "fishing"),
    "fish_canning": ("fish", "canning"),
    "clay_extraction": ("clay", "adobe", "pottery"),
    "glassmaking": ("glass", "silica", "kiln"),
    "silica_extraction": ("silica", "glass", "sand"),
    "copper_extraction": ("copper", "bronze"),
    "tin_extraction": ("tin", "bronze"),
    "iron_extraction": ("iron", "coal", "mine", "mining", "shaft"),
    "steelmaking": ("steel", "coke", "iron"),
    "gold_extraction": ("gold",),
    "jewelry_making": ("silver", "gold", "currency", "jewelry"),
    "salt_extraction": ("salt", "brine"),
    "oil_extraction": ("oil", "petroleum", "fuel", "combustion", "gas", "refining", "drilling"),
    "renewable_power_generation": (
        "wind", "electric", "grid", "nuclear", "power", "motor", "hydro", "steam",
    ),
    "railway_equipment_making": ("rail", "logistics", "ship", "motor", "engine"),
}

FILLER_FAMILIES = {
    "paper_making",
    "metal_toolmaking",
    "research_institution",
    "construction_methods",
    "maritime_operations",
    "jewelry_making",
    "glassmaking",
}

ERA_ORDER = [
    "stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
    "steam", "electrical", "atomic", "information", "intelligent",
]


def is_broad(stat: str) -> bool:
    return any(stat == p or stat.startswith(p) for p in BROAD_PREFIXES)


def tokens(tech_id: str, display_name: str = "") -> set[str]:
    raw = tech_id.removeprefix("tech.").replace("-", "_")
    parts = {p for p in raw.split("_") if p}
    for chunk in re.findall(r"[\w]+", display_name.lower()):
        if chunk:
            parts.add(chunk)
    return parts


def family_from_stat(stat: str) -> str:
    if stat.startswith("country.output.family.") and stat.endswith("_factor"):
        return stat[len("country.output.family."):-len("_factor")]
    return ""


def building_from_stat(stat: str) -> str:
    if stat.startswith("country.output.building.") and stat.endswith("_factor"):
        return stat[len("country.output.building."):-len("_factor")]
    return ""


def good_from_stat(stat: str) -> str:
    if stat.startswith("country.output.good.") and stat.endswith("_factor"):
        return stat[len("country.output.good."):-len("_factor")]
    return ""


def honest_family(family: str, toks: set[str], lane: str, profile: str) -> bool:
    topics = FAMILY_TOPIC.get(family)
    if not topics:
        return True
    for topic in topics:
        for tok in toks:
            if tok == topic or (len(topic) >= 5 and tok.startswith(topic)) or (
                len(tok) >= 5 and topic.startswith(tok)
            ):
                return True
            if topic in tok or tok in topic:
                return True
    # Lane-honest: knowledge backbone may use research_institution.
    if family == "research_institution" and "knowledge" in lane:
        return True
    if family == "paper_making" and "forest" in lane:
        return True
    if family == "metal_toolmaking" and "tools_machinery" in lane:
        return True
    if family == "construction_methods" and (
        "construction" in lane or "water_wind" in lane or "institutions" in lane
    ):
        return True
    if family == "maritime_operations" and (
        "maritime" in lane or "institutions" in lane
    ):
        return True
    if profile in {"research", "knowledge", "observation"} and family == "research_institution":
        return True
    return False


def classify_term(stat: str) -> str:
    if stat.startswith("country.output.good."):
        return "good_output"
    if stat.startswith("country.input.good."):
        return "good_input"
    if stat.startswith("country.consumption.good."):
        return "good_consumption"
    if stat.startswith("country.resource."):
        return "resource"
    if stat.startswith("country.output.terrain.") or stat.startswith("country.output.landform."):
        return "geography"
    if family_from_stat(stat):
        return "family"
    if building_from_stat(stat):
        return "building"
    if is_broad(stat):
        return "broad"
    if stat in CLIMATE_STATS:
        return "climate"
    if stat in CONSTRUCTION_STATS:
        return "construction"
    return "other"


def main() -> None:
    payload = json.loads(NETWORK.read_text(encoding="utf-8"))
    nodes = payload["nodes"]
    family_totals: dict[str, float] = defaultdict(float)
    building_totals: dict[str, float] = defaultdict(float)
    broad_totals: dict[str, float] = defaultdict(float)
    term_hist = Counter()
    mix_hist = Counter()
    role_thin = Counter()
    filler = []
    thin_anchors = []
    no_broad_anchors = []
    unlock_only_numeric = []
    climate_or_construction = 0
    modifier_count = 0
    broad_nodes = 0
    researchable = 0
    semantic_terms = Counter()
    missing_semantics = []

    for node in nodes:
        if node.get("is_starting") or node.get("is_starter_eligible"):
            continue
        researchable += 1
        terms = node.get("modifier_terms") or []
        contents = node.get("content_effects") or []
        modifier_count += len(terms)
        term_hist[len(terms)] += 1
        kinds = set()
        has_broad = False
        has_targeted = False
        toks = tokens(node["id"], node.get("display_name", ""))
        summaries = []
        for term in terms:
            stat = term["stat"]
            value = float(term.get("value", 0))
            kind = classify_term(stat)
            semantic_terms[kind] += 1
            if (not term.get("effect_class") or not term.get("effect_rationale")
                    or term.get("implementation_status") != "runtime_consumed"
                    or not term.get("runtime_consumer")):
                missing_semantics.append((node["id"], stat))
            kinds.add(kind)
            summaries.append(f"{stat}={value:g}")
            if kind == "family":
                has_targeted = True
                fam = family_from_stat(stat)
                family_totals[fam] += value
                if fam in FILLER_FAMILIES and not honest_family(
                    fam, toks, node.get("main_lane", ""), node.get("effect_profile", "")
                ):
                    filler.append(node)
            elif kind == "building":
                has_targeted = True
                building_totals[building_from_stat(stat)] += value
            elif kind == "broad":
                has_broad = True
                broad_totals[stat] += value
            elif kind in {"climate", "construction"}:
                climate_or_construction += 1
        if has_broad:
            broad_nodes += 1
        mix = "+".join(sorted(kinds)) if kinds else "none"
        mix_hist[mix] += 1
        unlocks = [
            c for c in contents
            if c.get("kind") in {"building", "good", "resource"}
            and c.get("attribute", "") in {"", "production_access", "unlock"}
            or c.get("operation") == "unlock"
        ]
        anchor = node.get("anchor_kind")
        if len(terms) == 1 and anchor in {"backbone_anchor", "route_anchor"}:
            thin_anchors.append(node)
        if not has_broad and anchor in {"backbone_anchor", "route_anchor"}:
            no_broad_anchors.append(node)
        if len(terms) == 1 and not unlocks and anchor == "support":
            role_thin[node.get("effect_profile", "?")] += 1
        if len(terms) == 1 and unlocks:
            unlock_only_numeric.append(node)

    print("=== inventory ===")
    print(f"researchable={researchable} modifiers={modifier_count} broad_nodes={broad_nodes}")
    print(f"semantic_term_hist={dict(sorted(semantic_terms.items()))}")
    print(f"missing_runtime_semantics={len(missing_semantics)}")
    print(f"term_count_hist={dict(sorted(term_hist.items()))}")
    print(f"mix_hist={dict(mix_hist)}")
    print(f"climate_or_construction_terms={climate_or_construction}")
    print(f"thin_anchors(1-term)={len(thin_anchors)}  anchors_without_broad={len(no_broad_anchors)}")
    print(f"filler_family_nodes={len(filler)}")
    print(f"unlock_plus_single_numeric={len(unlock_only_numeric)}")
    print(f"support_thin_by_profile={dict(role_thin)}")
    print()
    print("=== family remaining to 4.00 ===")
    for fam, total in sorted(family_totals.items(), key=lambda kv: -kv[1]):
        print(f"  {fam:28s} {total:.3f}  remain={4.00-total:.3f}")
    print()
    print("=== broad remaining to 4.00 ===")
    for stat, total in sorted(broad_totals.items(), key=lambda kv: -kv[1]):
        print(f"  {stat:44s} {total:.3f}  remain={4.00-total:.3f}")
    print()
    print("=== filler mismatches ===")
    by_era = Counter()
    by_family = Counter()
    for node in filler:
        fams = [
            family_from_stat(t["stat"])
            for t in node.get("modifier_terms") or []
            if family_from_stat(t["stat"])
        ]
        fam = fams[0] if fams else "?"
        by_era[node["era_id"]] += 1
        by_family[fam] += 1
        terms = ", ".join(
            f"{t['stat'].split('.')[-1]}={float(t['value']):g}"
            for t in node.get("modifier_terms") or []
        )
        print(
            f"  {node['era_id']:14s} {node['anchor_kind']:16s} "
            f"{node['id']:42s} {node['display_name']:16s} {terms}"
        )
    print()
    print(f"filler_by_family={dict(by_family)}")
    print(f"filler_by_era={dict(by_era)}")
    print()
    print("=== thin backbone anchors ===")
    for node in thin_anchors:
        if node.get("anchor_kind") != "backbone_anchor":
            continue
        terms = ", ".join(
            f"{t.get('subject_display_name') or t['stat'].split('.')[-1]}={float(t['value']):g}"
            for t in node.get("modifier_terms") or []
        )
        unlock_n = len(node.get("content_effects") or [])
        print(f"  {node['era_id']:14s} {node['id']:42s} {node['display_name']:16s} unlocks={unlock_n} {terms}")
    print()
    print("=== thin route anchors sample (first 40) ===")
    n = 0
    for node in thin_anchors:
        if node.get("anchor_kind") != "route_anchor":
            continue
        terms = ", ".join(
            f"{t.get('subject_display_name') or t['stat'].split('.')[-1]}={float(t['value']):g}"
            for t in node.get("modifier_terms") or []
        )
        unlock_n = len(node.get("content_effects") or [])
        print(f"  {node['era_id']:14s} {node['id']:42s} {node['display_name']:16s} unlocks={unlock_n} {terms}")
        n += 1
        if n >= 40:
            break
    print()
    print("=== backbone anchors without broad ===")
    for node in no_broad_anchors:
        if node.get("anchor_kind") != "backbone_anchor":
            continue
        terms = ", ".join(
            f"{t.get('subject_display_name') or t['stat'].split('.')[-1]}={float(t['value']):g}"
            for t in node.get("modifier_terms") or []
        )
        print(f"  {node['era_id']:14s} {node['id']:42s} {node['display_name']:16s} {terms}")


if __name__ == "__main__":
    main()
