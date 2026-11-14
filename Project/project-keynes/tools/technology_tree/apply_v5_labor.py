# -*- coding: utf-8 -*-
"""v5 内容：高寒作物气候档案 + 农艺师职业。

两件事：
  1. 新增气候档案 `highland_crop`（此前 6 个档案没有冷凉/高原作物，高地农业只能借用 dryland_crop），
     并把梯田农场与高寒梯田改挂到它；再给「梯田农业」加一条该档案的寒害减免效果。
  2. 新增职业 `agronomist` 农艺师（此前农业岗位止于王国代的 agricultural_worker，没有后期技师），
     并挂到精准农场的雇工槽位上。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CLIMATES = os.path.join(ROOT, "data", "economy", "production_climates")
PROFESSIONS = os.path.join(ROOT, "data", "economy", "professions")
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")
CATALOG_TEST = os.path.join(ROOT, "tests", "technology", "technology_catalog_test.gd")

CLIMATE_BODY = """[gd_resource type="Resource" script_class="ProductionClimateProfile" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/data/production_climate_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"highland_crop"
temperature_opt = 0.38
temperature_tolerance = 0.30
water_opt = 0.52
water_tolerance = 0.30
floor_q16 = 16384
exposure_q16 = 65536
"""

PROFESSION_BODY = """[gd_resource type="Resource" script_class="ProfessionProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/profession_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"agronomist"
satisfaction_dimension_weights_q16 = PackedInt32Array(62915, 45875, 22938, 6554, 32768, 22938, 26214, 13107)
display_name = "农艺师"
semantic_tags = PackedStringArray("activity.farming", "activity.knowledge")
default_consumption_plan_id = &"technical_household"
technology_tags = PackedStringArray()
"""


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write(path, text):
    temporary = path + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temporary, path)


def swap_climate(building_id, log, dry_run):
    path = os.path.join(BUILDINGS, building_id + ".tres")
    if not os.path.exists(path):
        log.append("SKIP 找不到建筑 %s" % building_id)
        return 0
    text = read(path)
    if 'production_climate_profile_id = &"highland_crop"' in text:
        log.append("SKIP %s 已使用 highland_crop" % building_id)
        return 0
    if 'production_climate_profile_id = &"dryland_crop"' not in text:
        log.append("SKIP %s 没有 dryland_crop 档案字段" % building_id)
        return 0
    text = text.replace('production_climate_profile_id = &"dryland_crop"',
                        'production_climate_profile_id = &"highland_crop"', 1)
    log.append("FIX %s 气候档案 dryland_crop → highland_crop" % building_id)
    if not dry_run:
        write(path, text)
    return 1


def append_employee(building_id, profession_id, slots, log, dry_run):
    path = os.path.join(BUILDINGS, building_id + ".tres")
    if not os.path.exists(path):
        log.append("SKIP 找不到建筑 %s" % building_id)
        return 0
    text = read(path)
    if '"%s"' % profession_id in text:
        log.append("SKIP %s 已雇 %s" % (building_id, profession_id))
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

    append("employee_profession_ids", '"%s"' % profession_id)
    append("employee_slots_per_building", str(slots))
    append("employee_wage_policy_ids", '"adaptive"')
    log.append("FIX %s 新增岗位 %s ×%d" % (building_id, profession_id, slots))
    if not dry_run:
        write(path, text)
    return 1


def bind_climate_tech(log, dry_run):
    """给梯田农业加一条 highland_crop 档案的寒害减免。"""
    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    node = by_id.get("tech.terrace_farming")
    if node is None:
        log.append("SKIP 找不到 tech.terrace_farming")
        return 0
    terms = node.setdefault("modifier_terms", [])
    stat = "country.climate.profile.highland_crop.cold_stress_loss_factor"
    if any(term.get("stat") == stat for term in terms):
        log.append("SKIP 梯田农业已有高寒档案效果")
        return 0
    terms.append({
        "stat": stat, "operation": 0.0, "value": -0.12,
        "subject_kind": "climate_profile", "subject_id": "highland_crop",
        "subject_display_name": "高寒作物",
        "effect_class": "气候适应",
        "effect_rationale": "梯田的挡风与昼暖夜冷的排水安排，让高寒作物少受霜冻损失。",
        "implementation_status": "runtime_consumed",
        "runtime_consumer": "NativeEconomyRuntime country climate loss freeze",
    })
    log.append("FIX tech.terrace_farming 追加 highland_crop 寒害减免 −12%")
    if not dry_run:
        temporary = NETWORK + ".v5tmp"
        with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, ensure_ascii=False, indent="\t")
            handle.write("\n")
        os.replace(temporary, NETWORK)
    return 1


def update_catalog_test(log, dry_run):
    text = read(CATALOG_TEST)
    if "profile_stat_count == 28" in text:
        log.append("SKIP 测试已按 7 个档案更新")
        return 0
    if "profile_stat_count == 24" not in text:
        log.append("SKIP 未找到档案数量断言")
        return 0
    text = text.replace("assert(profile_stat_count == 24)", "assert(profile_stat_count == 28)")
    log.append("FIX technology_catalog_test 气候档案 stat 数 24 → 28（7 个档案 × 4 灾害）")
    if not dry_run:
        write(CATALOG_TEST, text)
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    log = []
    climate_path = os.path.join(CLIMATES, "highland_crop.tres")
    if os.path.exists(climate_path):
        log.append("SKIP 气候档案 highland_crop 已存在")
    else:
        log.append("新增气候档案 highland_crop（冷凉 + 中等水分，窄耐受）")
        if not arguments.dry_run:
            write(climate_path, CLIMATE_BODY)
    profession_path = os.path.join(PROFESSIONS, "agronomist.tres")
    if os.path.exists(profession_path):
        log.append("SKIP 职业 agronomist 已存在")
    else:
        log.append("新增职业 agronomist 农艺师")
        if not arguments.dry_run:
            write(profession_path, PROFESSION_BODY)
    swap_climate("terrace_farm", log, arguments.dry_run)
    swap_climate("highland_tuber_plot", log, arguments.dry_run)
    append_employee("precision_farm", "agronomist", 4, log, arguments.dry_run)
    bind_climate_tech(log, arguments.dry_run)
    update_catalog_test(log, arguments.dry_run)
    for line in log:
        print(line)
    print("--- %s ---" % ("dry-run" if arguments.dry_run else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
