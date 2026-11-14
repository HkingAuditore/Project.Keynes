# -*- coding: utf-8 -*-
"""v5 内容：养鱼场 + 养殖员。

配套 `tech.aquaculture`（在 apply_v5_nodes.py 的 NODES_F 里新增）：
  * 建筑 `fish_farm`：海岸或湖泊上的水产养殖场，产 `fish`
  * 职业 `aquaculturist`：养殖员，挂在养鱼场的雇工槽
地形条件用 postfix 字节码：`terrain == COAST(1) || terrain == LAKE(18)`。
注意：`building_kind = collector` 会强制要求 `resource_ids`，养殖是生产不是采集，用 industrial。
"""
from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
PROFESSIONS = os.path.join(ROOT, "data", "economy", "professions")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")

PROFESSION_BODY = """[gd_resource type="Resource" script_class="ProfessionProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/profession_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"aquaculturist"
satisfaction_dimension_weights_q16 = PackedInt32Array(58982, 45875, 26214, 9830, 26214, 26214, 22938, 16384)
display_name = "养殖员"
semantic_tags = PackedStringArray("activity.fishing")
default_consumption_plan_id = &"extractive_household"
technology_tags = PackedStringArray()
"""

BUILDING_BODY = """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"fish_farm"
display_name = "养鱼场"
building_kind = "industrial"
economic_sector_id = "agriculture"
semantic_tags = PackedStringArray("activity.fishing", "industry.food")
technology_tags = PackedStringArray("tech.aquaculture")
required_technology_tags = PackedStringArray("tech.refrigeration")
industry_chain_id = &"production.fish"
progression_step = 2
maturity_rank = 5
maturity_display_name = "机械化"
progression_role = "mainline"
predecessor_building_ids = PackedStringArray("marine_fish_collector")
construction_good_ids = PackedStringArray("lumber", "bricks", "steel")
construction_quantities = PackedInt64Array(320000, 180000, 96000)
construction_category_ids = PackedStringArray("classical_construction", "industrial_construction", "structural_metal")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray("tools")
maintenance_quantities_per_day = PackedInt64Array(900)
owner_profession_id = &"fisher"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("aquaculturist", "technician")
employee_slots_per_building = PackedInt64Array(6, 2)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive")
input_good_ids = PackedStringArray("gathered_plants", "electricity", "tools")
input_quantities_per_day = PackedInt64Array(3600, 2100, 320)
input_required_q16 = PackedInt32Array(49152, 49152, 32768)
input_category_ids = PackedStringArray("", "", "tools")
input_min_quality_levels = PackedInt32Array(0, 0, 1)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("fish")
output_quantities_per_day = PackedInt64Array(10800)
output_cost_shares_q16 = PackedInt32Array()
resource_ids = PackedStringArray()
resource_quantities_per_day = PackedInt64Array()
resource_interaction_modes = PackedStringArray()
resource_access_modes = PackedStringArray()
resource_generation_ids = PackedStringArray()
resource_generation_quantities_per_day = PackedInt64Array()
behavior_id = "none"
condition_opcodes = PackedInt32Array(1, 1, 3)
condition_signals = PackedInt32Array(5, 5, 0)
condition_compares = PackedInt32Array(0, 0, 0)
condition_reference_ids = PackedStringArray("", "", "")
condition_values = PackedInt64Array(1, 18, 0)
"""


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write(path, text):
    temporary = path + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temporary, path)


def bind(log, dry_run):
    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    node = by_id.get("tech.aquaculture")
    if node is None:
        log.append("SKIP 找不到 tech.aquaculture")
        return 0
    changed = 0
    effects = node.setdefault("content_effects", [])
    if not any(effect.get("kind") == "building" and effect.get("id") == "fish_farm"
               for effect in effects):
        effects.append({
            "kind": "building", "id": "fish_farm", "binding_kind": 2.0,
            "subject": "building.fish_farm",
            "attribute": "construction_and_production_access",
            "operation": "unlock", "value": 1.0,
            "implementation": "BuildingProfile.technology_tags",
            "status": "existing_binding", "display_name": "养鱼场",
        })
        changed += 1
    bindings = node.setdefault("expected_bindings", [])
    if not any(int(b.get("kind") or 0) == 2 and b.get("id") == "fish_farm"
               for b in bindings):
        bindings.append({"kind": 2.0, "id": "fish_farm"})
        changed += 1
    if changed:
        log.append("FIX tech.aquaculture 绑定 fish_farm")
        if not dry_run:
            temporary = NETWORK + ".v5tmp"
            with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(data, handle, ensure_ascii=False, indent="\t")
                handle.write("\n")
            os.replace(temporary, NETWORK)
    return changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    log = []
    profession_path = os.path.join(PROFESSIONS, "aquaculturist.tres")
    if os.path.exists(profession_path) and os.path.getsize(profession_path) > 0:
        log.append("SKIP 职业 aquaculturist 已存在")
    else:
        log.append("新增职业 aquaculturist 养殖员")
        if not arguments.dry_run:
            write(profession_path, PROFESSION_BODY)
    building_path = os.path.join(BUILDINGS, "fish_farm.tres")
    if os.path.exists(building_path) and os.path.getsize(building_path) > 0:
        log.append("SKIP 建筑 fish_farm 已存在")
    else:
        log.append("新增建筑 fish_farm 养鱼场（terrain ∈ {海岸, 湖泊}）")
        if not arguments.dry_run:
            write(building_path, BUILDING_BODY)
    bind(log, arguments.dry_run)
    for line in log:
        print(line)
    print("--- %s ---" % ("dry-run" if arguments.dry_run else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
