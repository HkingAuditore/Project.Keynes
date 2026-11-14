# -*- coding: utf-8 -*-
"""v5 内容：公共卫生中心（给 `tech.public_health_systems` 一个落点）。

`tech.public_health_systems`（原子代）目前只有一个百分比效果，而设计稿说要补"高阶医疗"。
公共卫生中心把草药与化工原料转成大众可及的药品，是"制药厂 → 公共卫生体系"的下一步。

不加新物资、不加新产业链：复用 `production.pharmaceuticals`。
"""
from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")

BODY = """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"public_health_center"
display_name = "公共卫生中心"
building_kind = "industrial"
economic_sector_id = "manufacturing"
semantic_tags = PackedStringArray("activity.healthcare", "industry.chemicals")
technology_tags = PackedStringArray("tech.public_health_systems")
required_technology_tags = PackedStringArray("tech.modern_medicine")
industry_chain_id = &"production.pharmaceuticals"
progression_step = 2
maturity_rank = 6
maturity_display_name = "规模化生产"
progression_role = "mainline"
predecessor_building_ids = PackedStringArray("pharmaceuticals_plant")
construction_good_ids = PackedStringArray("construction_components", "steel", "bricks")
construction_quantities = PackedInt64Array(7400000, 5200000, 900000)
construction_category_ids = PackedStringArray("industrial_construction", "structural_metal", "classical_construction")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray("pharmaceuticals")
maintenance_quantities_per_day = PackedInt64Array(420)
owner_profession_id = &"industrialist"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("chemist", "technician", "industrial_worker")
employee_slots_per_building = PackedInt64Array(8, 6, 16)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive", "adaptive")
input_good_ids = PackedStringArray("medicinal_herbs", "industrial_chemicals", "electricity", "tools")
input_quantities_per_day = PackedInt64Array(9600, 5400, 4200, 800)
input_required_q16 = PackedInt32Array(65536, 65536, 49152, 32768)
input_category_ids = PackedStringArray("", "", "", "tools")
input_min_quality_levels = PackedInt32Array(0, 0, 0, 1)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("pharmaceuticals")
output_quantities_per_day = PackedInt64Array(16400)
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    log = []
    path = os.path.join(BUILDINGS, "public_health_center.tres")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        log.append("SKIP 建筑 public_health_center 已存在")
    else:
        log.append("新增建筑 public_health_center 公共卫生中心 ← tech.public_health_systems")
        if not arguments.dry_run:
            temporary = path + ".v5tmp"
            with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(BODY)
            os.replace(temporary, path)

    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    node = by_id.get("tech.public_health_systems")
    if node is None:
        log.append("SKIP 找不到 tech.public_health_systems")
    else:
        changed = 0
        effects = node.setdefault("content_effects", [])
        if not any(effect.get("kind") == "building"
                   and effect.get("id") == "public_health_center" for effect in effects):
            effects.append({
                "kind": "building", "id": "public_health_center", "binding_kind": 2.0,
                "subject": "building.public_health_center",
                "attribute": "construction_and_production_access",
                "operation": "unlock", "value": 1.0,
                "implementation": "BuildingProfile.technology_tags",
                "status": "existing_binding", "display_name": "公共卫生中心",
            })
            changed += 1
        bindings = node.setdefault("expected_bindings", [])
        if not any(int(b.get("kind") or 0) == 2 and b.get("id") == "public_health_center"
                   for b in bindings):
            bindings.append({"kind": 2.0, "id": "public_health_center"})
            changed += 1
        if changed:
            log.append("FIX tech.public_health_systems 绑定 public_health_center（%d 处）" % changed)
            if not arguments.dry_run:
                temporary = NETWORK + ".v5tmp"
                with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
                    json.dump(data, handle, ensure_ascii=False, indent="\t")
                    handle.write("\n")
                os.replace(temporary, NETWORK)
    for line in log:
        print(line)
    print("--- %s ---" % ("dry-run" if arguments.dry_run else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
