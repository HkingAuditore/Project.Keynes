# -*- coding: utf-8 -*-
"""v5 内容：结构钢 + 染料。

两个设计缺口：
  1. **蒸汽代之后连续 4 代 0 个新建材** —— 加 `structural_steel`（属于既有 `structural_metal` 建造类别，
     所有带该类别槽的建筑自动可以使用它，不需要改任何建筑）。
  2. **染料链完全缺失**，而 `bio.dye_plant` 信号一直闲置 —— 加 `dyestuff` + `dye_works`，
     并把它接成 `textile_mill` 的可选输入（`input_required_q16 = 0`）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GOODS = os.path.join(ROOT, "data", "goods")
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")

GOODS_BODY = {
    "structural_steel": """[gd_resource type="Resource" script_class="GoodProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/good_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"structural_steel"
display_name = "结构钢"
semantic_tags = PackedStringArray()
category_id = &"structural_metal"
substitution_category_ids = PackedStringArray("structural_metal")
technology_tags = PackedStringArray("industry.metals", "tech.coke_smelting")
default_price = 62000
reference_max_price = 3100000
price_adjust_q16 = 1434
demand_price_elasticity_q16 = 45875
""",
    "dyestuff": """[gd_resource type="Resource" script_class="GoodProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/good_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"dyestuff"
display_name = "染料"
semantic_tags = PackedStringArray()
category_id = &"dyestuff"
substitution_category_ids = PackedStringArray("dyestuff", "industrial_chemicals")
technology_tags = PackedStringArray("industry.chemicals", "tech.industrial_chemistry")
default_price = 26000
reference_max_price = 1300000
price_adjust_q16 = 1638
demand_price_elasticity_q16 = 52429
""",
}

BUILDINGS_BODY = {
    "steel_rolling_mill": """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"steel_rolling_mill"
display_name = "型钢轧机"
building_kind = "industrial"
economic_sector_id = "manufacturing"
semantic_tags = PackedStringArray("activity.metalworking", "industry.metals")
technology_tags = PackedStringArray("tech.coke_smelting")
required_technology_tags = PackedStringArray("tech.steam_power")
industry_chain_id = &"steelmaking"
progression_step = 2
maturity_rank = 5
maturity_display_name = "规模化生产"
progression_role = "mainline"
predecessor_building_ids = PackedStringArray("steam_steel_works")
construction_good_ids = PackedStringArray("bricks", "wrought_iron", "tools")
construction_quantities = PackedInt64Array(128000, 74000, 26000)
construction_category_ids = PackedStringArray("classical_construction", "ferrous_stock", "tools")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray("tools")
maintenance_quantities_per_day = PackedInt64Array(1800)
owner_profession_id = &"industrialist"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("metallurgist", "industrial_worker")
employee_slots_per_building = PackedInt64Array(4, 20)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive")
input_good_ids = PackedStringArray("steel", "coal", "tools")
input_quantities_per_day = PackedInt64Array(24800, 8600, 900)
input_required_q16 = PackedInt32Array(65536, 49152, 32768)
input_category_ids = PackedStringArray("", "solid_fuel", "tools")
input_min_quality_levels = PackedInt32Array(0, 1, 1)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("structural_steel")
output_quantities_per_day = PackedInt64Array(19200)
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
""",
    "dye_works": """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"dye_works"
display_name = "染坊"
building_kind = "industrial"
economic_sector_id = "manufacturing"
semantic_tags = PackedStringArray("activity.chemical", "industry.chemicals")
technology_tags = PackedStringArray("tech.industrial_chemistry")
required_technology_tags = PackedStringArray()
industry_chain_id = &"chemical_industry"
progression_step = 2
maturity_rank = 4
maturity_display_name = "规模化生产"
progression_role = "mainline"
predecessor_building_ids = PackedStringArray("industrial_chemicals_plant")
construction_good_ids = PackedStringArray("bricks", "wrought_iron", "tools")
construction_quantities = PackedInt64Array(96000, 42000, 18000)
construction_category_ids = PackedStringArray("classical_construction", "ferrous_stock", "tools")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray()
maintenance_quantities_per_day = PackedInt64Array()
owner_profession_id = &"industrialist"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("chemist", "artisan", "industrial_worker")
employee_slots_per_building = PackedInt64Array(4, 6, 12)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive", "adaptive")
input_good_ids = PackedStringArray("coal", "industrial_chemicals", "tools")
input_quantities_per_day = PackedInt64Array(14400, 6800, 600)
input_required_q16 = PackedInt32Array(65536, 65536, 32768)
input_category_ids = PackedStringArray("solid_fuel", "", "tools")
input_min_quality_levels = PackedInt32Array(1, 0, 1)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("dyestuff")
output_quantities_per_day = PackedInt64Array(11600)
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
""",
}

# 科技节点 → 新建筑
BINDINGS = [
    ("tech.coke_smelting", "steel_rolling_mill", "型钢轧机"),
    ("tech.industrial_chemistry", "dye_works", "染坊"),
]


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write(path, text):
    temporary = path + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temporary, path)


def add_optional_input(building_id, good_id, quantity, log, dry_run):
    """给既有建筑追加一个可选输入槽（required=0），五个数组同步 +1。"""
    path = os.path.join(BUILDINGS, building_id + ".tres")
    if not os.path.exists(path):
        log.append("SKIP 找不到建筑 %s" % building_id)
        return 0
    text = read(path)
    if '"%s"' % good_id in text:
        log.append("SKIP %s 已有输入 %s" % (building_id, good_id))
        return 0

    def append(field, value):
        nonlocal text
        pattern = re.compile(r"^(%s = [A-Za-z0-9]+Array\()([^)]*)(\))$" % re.escape(field), re.M)

        def repl(match):
            inner = match.group(2).strip()
            combined = (inner + ", " if inner else "") + value
            return "%s = %s%s)" % (field, match.group(1).split(" = ", 1)[1], combined)

        text, count = pattern.subn(repl, text, count=1)
        if count != 1:
            raise SystemExit("missing field %s in %s" % (field, building_id))

    append("input_good_ids", '"%s"' % good_id)
    append("input_quantities_per_day", str(quantity))
    append("input_required_q16", "0")
    append("input_category_ids", '""')
    append("input_min_quality_levels", "0")
    append("input_candidate_offsets", "0")
    log.append("FIX %s 追加可选输入 %s（%d/日，required=0）" % (building_id, good_id, quantity))
    if not dry_run:
        write(path, text)
    return 1


def bind_network(log, dry_run):
    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    changed = 0
    for tech_id, building_id, building_name in BINDINGS:
        node = by_id.get(tech_id)
        if node is None:
            log.append("SKIP 找不到 %s" % tech_id)
            continue
        effects = node.setdefault("content_effects", [])
        if not any(effect.get("kind") == "building" and effect.get("id") == building_id
                   for effect in effects):
            effects.append({
                "kind": "building", "id": building_id, "binding_kind": 2.0,
                "subject": "building.%s" % building_id,
                "attribute": "construction_and_production_access",
                "operation": "unlock", "value": 1.0,
                "implementation": "BuildingProfile.technology_tags",
                "status": "existing_binding", "display_name": building_name,
            })
            changed += 1
        bindings = node.setdefault("expected_bindings", [])
        if not any(int(b.get("kind") or 0) == 2 and b.get("id") == building_id
                   for b in bindings):
            bindings.append({"kind": 2.0, "id": building_id})
            changed += 1
        log.append("绑定 %s → %s" % (tech_id, building_id))
    # 物资归属：结构钢挂 coke_smelting（生产者同标签），染料挂 industrial_chemistry
    for tech_id, good_id in (("tech.coke_smelting", "structural_steel"),
                             ("tech.industrial_chemistry", "dyestuff")):
        node = by_id.get(tech_id)
        if node is None:
            continue
        effects = node.setdefault("content_effects", [])
        if not any(effect.get("kind") == "good" and effect.get("id") == good_id
                   for effect in effects):
            effects.append({
                "kind": "good", "id": good_id, "binding_kind": 1.0,
                "subject": "good.%s" % good_id, "attribute": "production_access",
                "operation": "unlock", "value": 1.0,
                "implementation": "GoodProfile.technology_tags",
                "status": "existing_binding",
                "display_name": {"structural_steel": "结构钢", "dyestuff": "染料"}[good_id],
                "summary_visible": True,
            })
            changed += 1
    if changed and not dry_run:
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
    for good_id, body in GOODS_BODY.items():
        path = os.path.join(GOODS, good_id + ".tres")
        if os.path.exists(path):
            log.append("SKIP 物资 %s 已存在" % good_id)
            continue
        log.append("新增物资 %s" % good_id)
        if not arguments.dry_run:
            write(path, body)
    for building_id, body in BUILDINGS_BODY.items():
        path = os.path.join(BUILDINGS, building_id + ".tres")
        if os.path.exists(path):
            log.append("SKIP 建筑 %s 已存在" % building_id)
            continue
        log.append("新增建筑 %s" % building_id)
        if not arguments.dry_run:
            write(path, body)
    add_optional_input("textile_mill", "dyestuff", 900, log, arguments.dry_run)
    bind_network(log, arguments.dry_run)
    for line in log:
        print(line)
    print("--- %s ---" % ("dry-run" if arguments.dry_run else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
