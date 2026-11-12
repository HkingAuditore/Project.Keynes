# -*- coding: utf-8 -*-
"""v5 内容：补齐最后两个职业（染工、船政官）。

设计稿里 4 个新职业，已落地农艺师与养殖员，本批补：
  * `dyer` 染工   → 挂到 `dye_works`（染坊）的雇工槽
  * `ship_officer` 船政官 → 挂到 `logistics_hub`（物流枢纽）

两个职业都有明确雇主，不会变成"无人可雇"的空壳职业。
"""
from __future__ import annotations

import argparse
import os
import re
import sys

ROOT = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
PROFESSIONS = os.path.join(ROOT, "data", "economy", "professions")
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")

PROFESSION_BODIES = {
    "dyer": """[gd_resource type="Resource" script_class="ProfessionProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/profession_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"dyer"
satisfaction_dimension_weights_q16 = PackedInt32Array(58982, 45875, 26214, 9830, 26214, 22938, 22938, 16384)
display_name = "染工"
semantic_tags = PackedStringArray("activity.chemical", "activity.craft")
default_consumption_plan_id = &"artisan_household"
technology_tags = PackedStringArray()
""",
    "ship_officer": """[gd_resource type="Resource" script_class="ProfessionProfile" load_steps=2 format=3]
[ext_resource type="Script" path="res://scripts/data/profession_profile.gd" id="1"]
[resource]
script = ExtResource("1")
id = &"ship_officer"
satisfaction_dimension_weights_q16 = PackedInt32Array(52429, 45875, 22938, 13107, 32768, 26214, 26214, 16384)
display_name = "船政官"
semantic_tags = PackedStringArray("activity.logistics", "activity.administration")
default_consumption_plan_id = &"merchant_household"
technology_tags = PackedStringArray()
""",
}

ASSIGNMENTS = [
    ("dye_works", "dyer", 6),
    ("logistics_hub", "ship_officer", 3),
]


def write(path, text):
    temporary = path + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temporary, path)


def append_employee(building_id, profession_id, slots, dry, log):
    path = os.path.join(BUILDINGS, building_id + ".tres")
    if not os.path.exists(path):
        log.append("SKIP 找不到建筑 %s" % building_id)
        return 0
    text = open(path, encoding="utf-8").read()
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
    if not dry:
        write(path, text)
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    dry = arguments.dry_run
    log = []
    for profession_id, body in PROFESSION_BODIES.items():
        path = os.path.join(PROFESSIONS, profession_id + ".tres")
        if os.path.exists(path) and os.path.getsize(path) > 0:
            log.append("SKIP 职业 %s 已存在" % profession_id)
            continue
        log.append("新增职业 %s" % profession_id)
        if not dry:
            write(path, body)
    for building_id, profession_id, slots in ASSIGNMENTS:
        append_employee(building_id, profession_id, slots, dry, log)
    for line in log:
        print(line)
    print("--- %s ---" % ("dry-run" if dry else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
