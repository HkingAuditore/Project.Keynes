# -*- coding: utf-8 -*-
"""v5 内容：为两个"身份节点"补上真实建筑。

  * tech.terrace_farming  梯田农业   → terrace_farm      （山地/高原/丘陵的梯田农场）
  * tech.blast_furnace    高炉      → blast_furnace_works（王国代的生铁批量冶炼）

两者原先都只给百分比、没有任何建筑（评审里"里程碑候选零内容"的典型）。
新增建筑复用既有物资与职业，不引入新链、不新增物资、不改需要结构。
幂等：文件已存在则跳过写入，但科技节点的绑定会补齐。
"""
from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")

HEADER = """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
"""

TERRACE_FARM = """id = &"terrace_farm"
display_name = "梯田农场"
building_kind = "collector"
economic_sector_id = "agriculture"
semantic_tags = PackedStringArray("activity.farming", "industry.food")
technology_tags = PackedStringArray("tech.terrace_farming")
required_technology_tags = PackedStringArray("tech.plough_agriculture")
industry_chain_id = &"production.potatoes"
progression_step = 4
maturity_rank = 4
maturity_display_name = "专业生产"
progression_role = "specialization"
predecessor_building_ids = PackedStringArray("highland_tuber_plot")
production_climate_profile_id = &"dryland_crop"
construction_good_ids = PackedStringArray("logs", "raw_stone", "turf_block")
construction_quantities = PackedInt64Array(52110, 38844, 61220)
construction_category_ids = PackedStringArray("primitive_construction", "primitive_construction", "primitive_construction")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray()
maintenance_quantities_per_day = PackedInt64Array()
owner_profession_id = &"household_farmer"
owner_slots_per_building = 2
employee_profession_ids = PackedStringArray("agricultural_worker")
employee_slots_per_building = PackedInt64Array(4)
employee_wage_policy_ids = PackedStringArray("adaptive")
input_good_ids = PackedStringArray("tools")
input_quantities_per_day = PackedInt64Array(240)
input_required_q16 = PackedInt32Array(32768)
input_category_ids = PackedStringArray("tools")
input_min_quality_levels = PackedInt32Array(2)
input_candidate_offsets = PackedInt32Array(0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("potatoes")
output_quantities_per_day = PackedInt64Array(12480)
output_cost_shares_q16 = PackedInt32Array()
resource_ids = PackedStringArray("arable_land")
resource_quantities_per_day = PackedInt64Array(340)
resource_interaction_modes = PackedStringArray("capacity")
resource_access_modes = PackedStringArray("local")
resource_generation_ids = PackedStringArray()
resource_generation_quantities_per_day = PackedInt64Array()
behavior_id = "consume_local_resources"
condition_opcodes = PackedInt32Array(1, 1, 3, 1, 3)
condition_signals = PackedInt32Array(6, 6, 0, 6, 0)
condition_compares = PackedInt32Array(0, 0, 0, 0, 0)
condition_reference_ids = PackedStringArray("", "", "", "", "")
condition_values = PackedInt64Array(6, 7, 0, 13, 0)
"""

BLAST_FURNACE = """id = &"blast_furnace_works"
display_name = "高炉厂"
building_kind = "industrial"
economic_sector_id = "manufacturing"
semantic_tags = PackedStringArray("activity.metalworking", "industry.metals")
technology_tags = PackedStringArray("tech.blast_furnace")
required_technology_tags = PackedStringArray("tech.iron_smelting")
industry_chain_id = &"production.wrought_iron"
progression_step = 2
maturity_rank = 4
maturity_display_name = "规模化生产"
progression_role = "mainline"
predecessor_building_ids = PackedStringArray("bloomery")
construction_good_ids = PackedStringArray("bricks", "wrought_iron", "raw_stone")
construction_quantities = PackedInt64Array(96000, 42000, 88000)
construction_category_ids = PackedStringArray("classical_construction", "ferrous_stock", "classical_construction")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray("bricks")
maintenance_quantities_per_day = PackedInt64Array(1800)
owner_profession_id = &"industrialist"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("metallurgist", "artisan")
employee_slots_per_building = PackedInt64Array(3, 12)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive")
input_good_ids = PackedStringArray("iron_ore", "coke", "tools")
input_quantities_per_day = PackedInt64Array(48600, 12600, 900)
input_required_q16 = PackedInt32Array(65536, 65536, 32768)
input_category_ids = PackedStringArray("", "smelting_fuel", "tools")
input_min_quality_levels = PackedInt32Array(0, 0, 1)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("wrought_iron")
output_quantities_per_day = PackedInt64Array(18600)
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

NEW_BUILDINGS = [
    ("terrace_farm", "梯田农场", TERRACE_FARM, "tech.terrace_farming"),
    ("blast_furnace_works", "高炉厂", BLAST_FURNACE, "tech.blast_furnace"),
]


def bind_technology(data, tech_id, building_id, building_name):
    by_id = {node["id"]: node for node in data["nodes"]}
    node = by_id.get(tech_id)
    if node is None:
        return False
    changed = False
    effects = node.setdefault("content_effects", [])
    if not any(effect.get("kind") == "building" and effect.get("id") == building_id
               for effect in effects):
        effects.append({
            "kind": "building",
            "id": building_id,
            "binding_kind": 2.0,
            "subject": "building.%s" % building_id,
            "attribute": "construction_and_production_access",
            "operation": "unlock",
            "value": 1.0,
            "implementation": "BuildingProfile.technology_tags",
            "status": "existing_binding",
            "display_name": building_name,
        })
        changed = True
    bindings = node.setdefault("expected_bindings", [])
    if not any(int(b.get("kind") or 0) == 2 and b.get("id") == building_id
               for b in bindings):
        bindings.append({"kind": 2.0, "id": building_id})
        changed = True
    review = node.get("building_unlock_review")
    if isinstance(review, dict) and review.get("policy") == "support_only":
        review["policy"] = "single"
        review["rationale"] = "本科技直接解锁「%s」，作为该路线的生产方式落点。" % building_name
        changed = True
    return changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    log = []
    for building_id, building_name, body, tech_id in NEW_BUILDINGS:
        path = os.path.join(BUILDINGS, building_id + ".tres")
        if os.path.exists(path):
            log.append("SKIP 建筑已存在 %s" % building_id)
        else:
            log.append("新增建筑 %-24s ← %s" % (building_id, tech_id))
            if not arguments.dry_run:
                with open(path, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(HEADER + body)
    data = json.load(open(NETWORK, encoding="utf-8"))
    for building_id, building_name, _body, tech_id in NEW_BUILDINGS:
        if bind_technology(data, tech_id, building_id, building_name):
            log.append("绑定 %s → %s" % (tech_id, building_id))
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
