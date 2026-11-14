# -*- coding: utf-8 -*-
"""v5 内容：合成氨（ammonia）——把"化肥厂没有氮源"和"天然气没有出口"一起修掉。

三件事：
  1. 新增物资 `ammonia`（类别 industrial_chemicals，与工业化学品可替代）
  2. 新增建筑 `ammonia_plant`：天然气 + 工业化学品 + 电 → 氨
  3. 给 `fertilizer_plant` 追加一个必需输入槽 `ammonia`（把磷肥厂变成真正的化肥厂）

只改既有结构，不新增产业链、不新增职业。
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

GOOD_BODY = """[gd_resource type="Resource" script_class="GoodProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/good_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"ammonia"
display_name = "合成氨"
semantic_tags = PackedStringArray()
category_id = &"industrial_chemicals"
substitution_category_ids = PackedStringArray("industrial_chemicals")
technology_tags = PackedStringArray("industry.chemicals", "tech.synthetic_fertilizer")
default_price = 42000
reference_max_price = 2100000
price_adjust_q16 = 1638
demand_price_elasticity_q16 = 52429
"""

BUILDING_BODY = """[gd_resource type="Resource" script_class="BuildingProfile" format=3]

[ext_resource type="Script" path="res://scripts/data/building_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"ammonia_plant"
display_name = "合成氨厂"
building_kind = "industrial"
economic_sector_id = "manufacturing"
semantic_tags = PackedStringArray("activity.chemical", "industry.chemicals")
technology_tags = PackedStringArray("tech.synthetic_fertilizer")
required_technology_tags = PackedStringArray("tech.petrochemical_cracking")
industry_chain_id = &"chemical_industry"
progression_step = 3
maturity_rank = 6
maturity_display_name = "规模化生产"
progression_role = "mainline"
predecessor_building_ids = PackedStringArray("electrochemical_works")
construction_good_ids = PackedStringArray("bricks", "construction_components", "steel")
construction_quantities = PackedInt64Array(8800000, 6400000, 4200000)
construction_category_ids = PackedStringArray("industrial_construction", "industrial_construction", "structural_metal")
construction_min_quality_levels = PackedInt32Array(0, 0, 0)
construction_candidate_offsets = PackedInt32Array()
construction_candidate_good_ids = PackedStringArray()
construction_candidate_efficiency_q16 = PackedInt32Array()
maintenance_good_ids = PackedStringArray("tools")
maintenance_quantities_per_day = PackedInt64Array(2400)
owner_profession_id = &"industrialist"
owner_slots_per_building = 1
employee_profession_ids = PackedStringArray("chemist", "industrial_worker", "technician")
employee_slots_per_building = PackedInt64Array(10, 18, 4)
employee_wage_policy_ids = PackedStringArray("adaptive", "adaptive", "adaptive")
input_good_ids = PackedStringArray("natural_gas", "industrial_chemicals", "electricity", "tools")
input_quantities_per_day = PackedInt64Array(38600, 12200, 9400, 700)
input_required_q16 = PackedInt32Array(65536, 65536, 65536, 32768)
input_category_ids = PackedStringArray("", "", "", "tools")
input_min_quality_levels = PackedInt32Array(0, 0, 0, 1)
input_candidate_offsets = PackedInt32Array(0, 0, 0, 0, 0)
input_candidate_good_ids = PackedStringArray()
input_candidate_efficiency_q16 = PackedInt32Array()
output_good_ids = PackedStringArray("ammonia")
output_quantities_per_day = PackedInt64Array(24800)
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


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write(path, text):
    temporary = path + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temporary, path)


def add_fertilizer_input(log, dry_run):
    """给化肥厂追加 ammonia 输入槽（五个对齐数组同步 +1）。"""
    path = os.path.join(BUILDINGS, "fertilizer_plant.tres")
    text = read(path)
    if '"ammonia"' in text:
        log.append("SKIP fertilizer_plant 已有 ammonia 输入")
        return 0

    def append(field, value):
        nonlocal text
        pattern = re.compile(r"^(%s = [A-Za-z0-9]+Array\()([^)]*)(\))$" % re.escape(field), re.M)

        def repl(match):
            inner = match.group(2).strip()
            combined = (inner + ", " if inner else "") + value
            return "%s = %s%s%s)" % (field, match.group(1).split(" = ", 1)[1],
                                     combined, "")

        text, count = pattern.subn(repl, text, count=1)
        if count != 1:
            raise SystemExit("missing field %s in fertilizer_plant" % field)

    append("input_good_ids", '"ammonia"')
    append("input_quantities_per_day", "5200")
    append("input_required_q16", "49152")
    append("input_category_ids", '""')
    append("input_min_quality_levels", "0")
    append("input_candidate_offsets", "0")
    log.append("FIX fertilizer_plant 追加 ammonia 输入槽（52.00/日，75% 必需）")
    if not dry_run:
        write(path, text)
    return 1


def bind_network(log, dry_run):
    path = NETWORK
    data = json.load(open(path, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    node = by_id.get("tech.synthetic_fertilizer")
    if node is None:
        log.append("SKIP 找不到 tech.synthetic_fertilizer")
        return 0
    changed = 0
    effects = node.setdefault("content_effects", [])
    if not any(effect.get("kind") == "building" and effect.get("id") == "ammonia_plant"
               for effect in effects):
        effects.append({
            "kind": "building", "id": "ammonia_plant", "binding_kind": 2.0,
            "subject": "building.ammonia_plant",
            "attribute": "construction_and_production_access",
            "operation": "unlock", "value": 1.0,
            "implementation": "BuildingProfile.technology_tags",
            "status": "existing_binding", "display_name": "合成氨厂",
        })
        changed += 1
    if not any(effect.get("kind") == "good" and effect.get("id") == "ammonia"
               for effect in effects):
        effects.append({
            "kind": "good", "id": "ammonia", "binding_kind": 1.0,
            "subject": "good.ammonia", "attribute": "production_access",
            "operation": "unlock", "value": 1.0,
            "implementation": "GoodProfile.technology_tags",
            "status": "existing_binding", "display_name": "合成氨",
            "summary_visible": True,
        })
        changed += 1
    bindings = node.setdefault("expected_bindings", [])
    for kind, identifier in ((2.0, "ammonia_plant"), (1.0, "ammonia")):
        if not any(int(b.get("kind") or 0) == int(kind) and b.get("id") == identifier
                   for b in bindings):
            bindings.append({"kind": kind, "id": identifier})
            changed += 1
    review = node.get("building_unlock_review")
    if isinstance(review, dict):
        review["policy"] = "paired"
        review["rationale"] = "本科技同时解锁合成氨厂与合成氨物资，把磷肥厂升级为真正的氮磷复合肥厂。"
    if changed:
        log.append("FIX tech.synthetic_fertilizer 绑定 ammonia_plant + ammonia（%d 处）" % changed)
        if not dry_run:
            temporary = path + ".v5tmp"
            with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
                json.dump(data, handle, ensure_ascii=False, indent="\t")
                handle.write("\n")
            os.replace(temporary, path)
    return changed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    log = []
    good_path = os.path.join(GOODS, "ammonia.tres")
    if os.path.exists(good_path):
        log.append("SKIP 物资 ammonia 已存在")
    else:
        log.append("新增物资 ammonia（industrial_chemicals q3）")
        if not arguments.dry_run:
            write(good_path, GOOD_BODY)
    building_path = os.path.join(BUILDINGS, "ammonia_plant.tres")
    if os.path.exists(building_path):
        log.append("SKIP 建筑 ammonia_plant 已存在")
    else:
        log.append("新增建筑 ammonia_plant ← tech.synthetic_fertilizer")
        if not arguments.dry_run:
            write(building_path, BUILDING_BODY)
    add_fertilizer_input(log, arguments.dry_run)
    bind_network(log, arguments.dry_run)
    for line in log:
        print(line)
    print("--- %s ---" % ("dry-run" if arguments.dry_run else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
