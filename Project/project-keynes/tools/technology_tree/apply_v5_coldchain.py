# -*- coding: utf-8 -*-
"""v5 内容：冷冻食品（冷链的下游产物）。

`tech.refrigeration`（电气代）此前只有百分比效果，冷链没有实体产出。
本批补一座冷库与一种冷冻食品，并把它接进 `protein` 需求（见 apply_v5_needs.py 的插入表）。
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
id = &"frozen_food"
display_name = "冷冻食品"
semantic_tags = PackedStringArray()
category_id = &"processed_food"
substitution_category_ids = PackedStringArray("processed_food")
technology_tags = PackedStringArray("industry.food", "tech.refrigeration")
default_price = 58000
reference_max_price = 2900000
price_adjust_q16 = 1434
demand_price_elasticity_q16 = 45875
"""

BUILDING_BODY = """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"cold_storage"
display_name = "冷库"
building_kind = "industrial"
economic_sector_id = "manufacturing"
semantic_tags = PackedStringArray("activity.food", "industry.food")
technology_tags = PackedStringArray("tech.refrigeration")
required_technology_tags = PackedStringArray("tech.electrification")
industry_chain_id = &"production.frozen_food"
progression_step = 1
maturity_rank = 5
maturity_display_name = "机械化"
progression_role = "entry"
predecessor_building_ids = PackedStringArray()
construction_good_ids = PackedStringArray("bricks", "steel", "tools")
construction_quantities = PackedInt64Array(186000, 92000, 24000)
construction_category_ids = PackedStringArray("industrial_construction", "structural_metal", "tools")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray("tools")
maintenance_quantities_per_day = PackedInt64Array(700)
owner_profession_id = &"industrialist"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("industrial_worker", "technician")
employee_slots_per_building = PackedInt64Array(14, 3)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive")
input_good_ids = PackedStringArray("livestock_products", "fish", "electricity", "packaging")
input_quantities_per_day = PackedInt64Array(9800, 6200, 8600, 3200)
input_required_q16 = PackedInt32Array(58982, 49152, 65536, 32768)
input_category_ids = PackedStringArray("", "", "", "")
input_min_quality_levels = PackedInt32Array(0, 0, 0, 0)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("frozen_food")
output_quantities_per_day = PackedInt64Array(16800)
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

    good_path = os.path.join(GOODS, "frozen_food.tres")
    if os.path.exists(good_path) and os.path.getsize(good_path) > 0:
        log.append("SKIP 物资 frozen_food 已存在")
    else:
        log.append("新增物资 frozen_food 冷冻食品（processed_food 类别）")
        if not dry:
            write(good_path, GOOD_BODY)

    building_path = os.path.join(BUILDINGS, "cold_storage.tres")
    if os.path.exists(building_path) and os.path.getsize(building_path) > 0:
        log.append("SKIP 建筑 cold_storage 已存在")
    else:
        log.append("新增建筑 cold_storage 冷库 ← tech.refrigeration")
        if not dry:
            write(building_path, BUILDING_BODY)

    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    node = by_id.get("tech.refrigeration")
    if node is None:
        log.append("SKIP 找不到 tech.refrigeration")
    else:
        effects = node.setdefault("content_effects", [])
        bindings = node.setdefault("expected_bindings", [])
        changed = 0
        for kind, identifier, label in ((2.0, "cold_storage", "冷库"),
                                        (1.0, "frozen_food", "冷冻食品")):
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
            log.append("FIX tech.refrigeration 绑定冷库与冷冻食品（%d 处）" % changed)
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
