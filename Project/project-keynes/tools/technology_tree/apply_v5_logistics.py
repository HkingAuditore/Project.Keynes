# -*- coding: utf-8 -*-
"""v5 内容：物流枢纽（给 `railway_equipment` 第一个消费者，并给 `tech.global_logistics` 一个落点）。

`railway_equipment` 一直是"有两个生产者、零个消费者"的孤儿物资；
`tech.global_logistics`（原子代）也只有一个百分比效果。
一座物流枢纽同时解决这两件事：它吃掉铁路设备做装卸线，产出包装材料。

注意：不加新物资、不加新产业链（复用 `production.packaging`），只加一座建筑。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")

BODY = """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"logistics_hub"
display_name = "物流枢纽"
building_kind = "industrial"
economic_sector_id = "manufacturing"
semantic_tags = PackedStringArray("activity.logistics", "industry.packaging")
technology_tags = PackedStringArray("tech.global_logistics")
required_technology_tags = PackedStringArray("tech.rail_logistics")
industry_chain_id = &"production.packaging"
progression_step = 3
maturity_rank = 6
maturity_display_name = "规模化生产"
progression_role = "mainline"
predecessor_building_ids = PackedStringArray("method_packaging_plant_r7")
construction_good_ids = PackedStringArray("construction_components", "steel", "railway_equipment")
construction_quantities = PackedInt64Array(9200000, 6800000, 1400000)
construction_category_ids = PackedStringArray("industrial_construction", "structural_metal", "railway_equipment")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray("railway_equipment")
maintenance_quantities_per_day = PackedInt64Array(2600)
owner_profession_id = &"industrialist"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("industrial_worker", "technician", "manager")
employee_slots_per_building = PackedInt64Array(26, 6, 2)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive", "adaptive")
input_good_ids = PackedStringArray("lumber", "tools", "electricity")
input_quantities_per_day = PackedInt64Array(22000, 900, 7200)
input_required_q16 = PackedInt32Array(65536, 32768, 49152)
input_category_ids = PackedStringArray("", "tools", "")
input_min_quality_levels = PackedInt32Array(0, 1, 0)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("packaging")
output_quantities_per_day = PackedInt64Array(24600)
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
    path = os.path.join(BUILDINGS, "logistics_hub.tres")
    if os.path.exists(path) and os.path.getsize(path) > 0:
        log.append("SKIP 建筑 logistics_hub 已存在")
    else:
        log.append("新增建筑 logistics_hub 物流枢纽 ← tech.global_logistics")
        if not arguments.dry_run:
            temporary = path + ".v5tmp"
            with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(BODY)
            os.replace(temporary, path)

    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    node = by_id.get("tech.global_logistics")
    if node is None:
        log.append("SKIP 找不到 tech.global_logistics")
    else:
        changed = 0
        effects = node.setdefault("content_effects", [])
        if not any(effect.get("kind") == "building" and effect.get("id") == "logistics_hub"
                   for effect in effects):
            effects.append({
                "kind": "building", "id": "logistics_hub", "binding_kind": 2.0,
                "subject": "building.logistics_hub",
                "attribute": "construction_and_production_access",
                "operation": "unlock", "value": 1.0,
                "implementation": "BuildingProfile.technology_tags",
                "status": "existing_binding", "display_name": "物流枢纽",
            })
            changed += 1
        bindings = node.setdefault("expected_bindings", [])
        if not any(int(b.get("kind") or 0) == 2 and b.get("id") == "logistics_hub"
                   for b in bindings):
            bindings.append({"kind": 2.0, "id": "logistics_hub"})
            changed += 1
        if changed:
            log.append("FIX tech.global_logistics 绑定 logistics_hub（%d 处）" % changed)
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
