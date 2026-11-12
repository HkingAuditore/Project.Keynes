# -*- coding: utf-8 -*-
"""v5 内容：抗生素（现代药物那一层）。

`tech.molecular_biology`（原子代）此前只有一条 +4.4% 的研究效率，没有任何内容。
本批给它一座抗生素厂与一种新物资，并把抗生素接进 `healthcare` 需求。
"""
from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
GOODS = os.path.join(ROOT, "data", "goods")
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")

GOOD_BODY = """[gd_resource type="Resource" script_class="GoodProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/good_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"antibiotics"
display_name = "抗生素"
semantic_tags = PackedStringArray()
category_id = &"pharmaceuticals"
substitution_category_ids = PackedStringArray("pharmaceuticals")
technology_tags = PackedStringArray("industry.chemicals", "tech.molecular_biology")
default_price = 132000
reference_max_price = 6600000
price_adjust_q16 = 1434
demand_price_elasticity_q16 = 45875
"""

BUILDING_BODY = """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"antibiotics_plant"
display_name = "抗生素厂"
building_kind = "industrial"
economic_sector_id = "manufacturing"
semantic_tags = PackedStringArray("activity.chemical", "industry.chemicals")
technology_tags = PackedStringArray("tech.molecular_biology")
required_technology_tags = PackedStringArray("tech.public_health_systems")
industry_chain_id = &"production.pharmaceuticals"
progression_step = 3
maturity_rank = 7
maturity_display_name = "高度集成"
progression_role = "mainline"
predecessor_building_ids = PackedStringArray("public_health_center")
construction_good_ids = PackedStringArray("construction_components", "steel", "bricks")
construction_quantities = PackedInt64Array(8600000, 5400000, 3200000)
construction_category_ids = PackedStringArray("industrial_construction", "structural_metal", "industrial_construction")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray("tools")
maintenance_quantities_per_day = PackedInt64Array(1800)
owner_profession_id = &"industrialist"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("chemist", "engineer", "technician", "industrial_worker")
employee_slots_per_building = PackedInt64Array(14, 6, 8, 20)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive", "adaptive", "adaptive")
input_good_ids = PackedStringArray("industrial_chemicals", "glassware", "electricity", "tools")
input_quantities_per_day = PackedInt64Array(14600, 2600, 6800, 1100)
input_required_q16 = PackedInt32Array(65536, 49152, 58982, 32768)
input_category_ids = PackedStringArray("", "", "", "tools")
input_min_quality_levels = PackedInt32Array(0, 0, 0, 1)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("antibiotics")
output_quantities_per_day = PackedInt64Array(9800)
output_cost_shares_q16 = PackedInt32Array()
resource_ids = PackedStringArray()
resource_quantities_per_day = PackedInt64Array()
resource_interaction_modes = PackedStringArray()
resource_access_modes = PackedStringArray()
resource_generation_ids = PackedStringArray()
resource_generation_quantities_per_day = PackedInt64Array()
behavior_id = "none"
condition_opcodes = PackedInt32Array()
condition_signals = PackedInt32Array()
condition_compares = PackedInt32Array()
condition_reference_ids = PackedStringArray()
condition_values = PackedInt64Array()
"""


def write(path, text):
    temporary = path + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    dry = arguments.dry_run
    log = []

    good_path = os.path.join(GOODS, "antibiotics.tres")
    if os.path.exists(good_path) and os.path.getsize(good_path) > 0:
        log.append("SKIP 物资 antibiotics 已存在")
    else:
        log.append("新增物资 antibiotics 抗生素（pharmaceuticals 类别）")
        if not dry:
            write(good_path, GOOD_BODY)

    building_path = os.path.join(BUILDINGS, "antibiotics_plant.tres")
    if os.path.exists(building_path) and os.path.getsize(building_path) > 0:
        log.append("SKIP 建筑 antibiotics_plant 已存在")
    else:
        log.append("新增建筑 antibiotics_plant 抗生素厂 ← tech.molecular_biology")
        if not dry:
            write(building_path, BUILDING_BODY)

    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    node = by_id.get("tech.molecular_biology")
    if node is None:
        log.append("SKIP 找不到 tech.molecular_biology")
    else:
        effects = node.setdefault("content_effects", [])
        bindings = node.setdefault("expected_bindings", [])
        changed = 0
        for kind, identifier, label in ((2.0, "antibiotics_plant", "抗生素厂"),
                                        (1.0, "antibiotics", "抗生素")):
            if not any(effect.get("kind") == ("building" if kind == 2.0 else "good")
                       and effect.get("id") == identifier for effect in effects):
                effects.append({
                    "kind": "building" if kind == 2.0 else "good",
                    "id": identifier, "binding_kind": kind,
                    "subject": ("building." if kind == 2.0 else "good.") + identifier,
                    "attribute": "construction_and_production_access" if kind == 2.0
                    else "production_access",
                    "operation": "unlock", "value": 1.0,
                    "implementation": ("BuildingProfile.technology_tags" if kind == 2.0
                                       else "GoodProfile.technology_tags"),
                    "status": "existing_binding", "display_name": label,
                    "summary_visible": True,
                })
                changed += 1
            if not any(int(b.get("kind") or 0) == int(kind) and b.get("id") == identifier
                       for b in bindings):
                bindings.append({"kind": kind, "id": identifier})
                changed += 1
        if changed:
            log.append("FIX tech.molecular_biology 绑定抗生素厂与抗生素（%d 处）" % changed)
            if not dry:
                temporary = NETWORK + ".v5tmp"
                with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
                    json.dump(data, handle, ensure_ascii=False, indent="\t")
                    handle.write("\n")
                os.replace(temporary, NETWORK)

    for line in log:
        print(line)
    print("--- %s ---" % ("dry-run" if dry else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
