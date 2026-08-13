#!/usr/bin/env python3
import json
from pathlib import Path

p = Path("Project/project-keynes/data/technology/technology_network.json")
data = json.loads(p.read_text(encoding="utf-8"), strict=False)
by = {n["id"]: n for n in data["nodes"]}
nodes = data["nodes"]

ids = [
    "tech.maize_garden_horticulture",
    "tech.maize_seed_saving",
    "tech.maize_propagation",
    "tech.wild_maize_collection",
    "tech.wheat_seed_saving",
    "tech.wheat_propagation",
    "tech.wild_wheat_collection",
    "tech.rainfed_wheat_cultivation",
    "tech.rice_seed_saving",
    "tech.rice_paddy_cultivation",
    "tech.wild_rice_collection",
    "tech.wetland_rice_gardening",
    "tech.spice_cultivation",
    "tech.spice_shade_gardening",
    "tech.wild_spice_collection",
    "tech.rubber_working",
    "tech.latex_smoke_coagulation",
    "tech.wild_latex_tapping",
    "tech.cotton_identification",
    "tech.wild_cotton_collection",
    "tech.cotton_gardening",
    "tech.cotton_ginning",
    "tech.hand_spinning",
    "tech.flax_identification",
    "tech.wild_flax_collection",
    "tech.flax_retting",
    "tech.fiber_twisting",
    "tech.potato_propagation",
    "tech.ridge_tuber_cultivation",
    "tech.highland_tuber_farming",
    "tech.frost_protected_storage",
    "tech.tuber_storage",
    "tech.dairy_processing",
    "tech.horse_domestication",
    "tech.hide_tanning",
    "tech.felt_making",
    "tech.animal_husbandry",
    "tech.herd_management",
    "tech.early_glassmaking",
    "tech.adobe_making",
    "tech.kiln_firing",
    "tech.pottery",
    "tech.hand_pottery",
    "tech.flint_identification",
    "tech.gold_placer_identification",
    "tech.freshwater_fishing",
    "tech.earth_building",
    "tech.tin_identification",
    "tech.bronze_casting",
    "tech.copper_metallurgy",
    "tech.manuscript_culture",
    "tech.parchment_making",
    "tech.academic_institutions",
    "tech.surface_iron_collection",
    "tech.surface_coal_collection",
    "tech.coal_adit_mining",
    "tech.iron_smelting",
    "tech.wool_processing",
    "tech.sheep_herding",
    "tech.cattle_herding",
]

print("=== named family nodes ===")
for i in ids:
    n = by.get(i)
    if not n:
        print("MISSING", i)
        continue
    hard = ", ".join(by[h]["display_name"] for h in (n.get("hard_prerequisite_ids") or [])) or "(empty)"
    print(
        f"{n['era_id']:14} {n.get('anchor_kind',''):14} {n.get('node_role',''):18} "
        f"{n['display_name']:18} <- {hard}"
    )

print("\n=== all agrarian/stone/kingdom SUPPORT nodes ===")
for n in nodes:
    if n.get("is_starting") or n.get("is_milestone"):
        continue
    if n.get("anchor_kind") != "support":
        continue
    if n["era_id"] not in ("stone", "agrarian", "kingdom", "empire"):
        continue
    hard_ids = n.get("hard_prerequisite_ids") or []
    hard = ", ".join(by[h]["display_name"] for h in hard_ids) or "(empty)"
    print(
        f"{n['era_id']:14} {n.get('node_role',''):18} {n['layout_order']:4} "
        f"{n['display_name']:20} lane={n.get('main_lane','')[7:]:28} <- {hard}"
    )
