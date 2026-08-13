#!/usr/bin/env python3
import json
from pathlib import Path

data = json.loads(Path("Project/project-keynes/data/technology/technology_network.json").read_text(encoding="utf-8"), strict=False)
by = {n["id"]: n for n in data["nodes"]}
hard_of = {n["id"]: list(n.get("hard_prerequisite_ids") or []) for n in data["nodes"]}
lane = {n["id"]: n.get("main_lane") for n in data["nodes"]}

ids = [
    "tech.rubber_working", "tech.wild_latex_tapping", "tech.spice_shade_gardening",
    "tech.latex_smoke_coagulation", "tech.cotton_ginning", "tech.wild_cotton_collection",
    "tech.cotton_identification", "tech.hand_spinning", "tech.fiber_twisting",
    "tech.settled_knowledge", "tech.dairy_processing", "tech.horse_domestication",
    "tech.herd_management", "tech.animal_husbandry", "tech.hide_tanning",
    "tech.hide_scraping", "tech.hunting", "tech.felt_making", "tech.wool_livestock",
    "tech.sheep_wool_husbandry", "tech.early_glassmaking", "tech.kiln_firing",
    "tech.adobe_making", "tech.flint_identification", "tech.earth_building",
    "tech.stone_knapping", "tech.ground_stone_tools", "tech.clay_identification",
    "tech.gold_placer_identification", "tech.gold_panning", "tech.freshwater_fishing",
    "tech.silver_vein_identification", "tech.seasonal_calendar",
    "tech.ridge_tuber_cultivation", "tech.terrace_farming", "tech.tuber_storage",
    "tech.potato_propagation", "tech.highland_tuber_farming",
    "tech.coal_adit_mining", "tech.blast_furnace", "tech.surface_coal_use",
    "tech.surface_coal_collection", "tech.coal_outcrop_identification",
    "tech.tenant_cereal_farming", "tech.fermentation", "tech.crop_rotation",
    "tech.grain_threshing", "tech.bronze_casting", "tech.tin_identification",
    "tech.natural_copper_working", "tech.plough_agriculture", "tech.composite_tools",
    "tech.parchment_making", "tech.manuscript_culture", "tech.academic_institutions",
    "tech.controlled_burning",
]
print("=== lookup ===")
for i in ids:
    n = by.get(i)
    if not n:
        print("MISSING", i)
        continue
    hard = ", ".join(f"{by[h]['display_name']}" for h in (n.get("hard_prerequisite_ids") or [])) or "(empty)"
    print(f"{n['layout_order']:4} {n['era_id']:14} {n.get('anchor_kind',''):14} {n.get('node_role',''):16} {i:42} {n['display_name']:16} lane={n.get('main_lane','')} start={n.get('is_starting')} mile={n.get('is_milestone')} <- {hard}")

# wool / slaughter ids
print("\n=== pastoral agrarian support ===")
for n in data["nodes"]:
    if n.get("main_lane") == "branch.pastoral_livestock" and n["era_id"] in ("stone", "agrarian", "kingdom"):
        hard = ", ".join(by[h]["display_name"] for h in (n.get("hard_prerequisite_ids") or [])) or "(empty)"
        print(f"{n['layout_order']:4} {n['id']:42} {n['display_name']:16} {n.get('anchor_kind'):12} start={n.get('is_starting')} <- {hard}")

print("\n=== starting nodes ===")
for n in data["nodes"]:
    if n.get("is_starting"):
        print(f"{n['layout_order']:4} {n['id']:42} {n['display_name']:16} lane={n.get('main_lane')}")

# hard cross lane
cross = 0
hard = 0
for n in data["nodes"]:
    for hid in n.get("hard_prerequisite_ids") or []:
        hard += 1
        h = by[hid]
        if h.get("is_milestone"):
            continue
        if h.get("main_lane") != n.get("main_lane"):
            cross += 1
print(f"\nhard={hard} cross_lane_non_milestone={cross} cap={int(__import__('math').ceil(hard*0.10))}")

# all remaining support disjoint
print("\n=== later-era SUPPORT nodes ===")
for n in data["nodes"]:
    if n.get("anchor_kind") != "support":
        continue
    if n["era_id"] in ("stone", "agrarian", "kingdom"):
        continue
    if n.get("is_starting") or n.get("is_milestone"):
        continue
    hardn = ", ".join(by[h]["display_name"] for h in (n.get("hard_prerequisite_ids") or [])) or "(empty)"
    print(f"{n['era_id']:14} {n['layout_order']:4} {n['display_name']:20} <- {hardn}  [{n['id']}]")
