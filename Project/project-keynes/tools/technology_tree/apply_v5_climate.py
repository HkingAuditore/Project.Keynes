# -*- coding: utf-8 -*-
"""v5 内容：第八个气候档案 `controlled_environment`（温室 / 可控环境）。

前七个档案都描述"自然环境"（旱作、水田、种植园、牧场、采集、物候、高寒），
没有一个能表达"人在棚里造一个小气候"。而自动化农场正是靠人工环境把产量稳定下来的。

三件事：
  1. 新档案 `controlled_environment`：宽耐受、高下限（灾害损失被压得很低）
  2. `automated_farm` 改挂该档案
  3. 给 `tech.automated_agriculture` 加一条该档案的灾害减免效果
  4. `technology_catalog_test` 的档案 stat 数断言 28 → 32（8 档案 × 4 灾害）
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
CLIMATES = os.path.join(ROOT, "data", "economy", "production_climates")
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")
CATALOG_TEST = os.path.join(ROOT, "tests", "technology", "technology_catalog_test.gd")

BODY = """[gd_resource type="Resource" script_class="ProductionClimateProfile" load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/data/production_climate_profile.gd" id="1"]

[resource]
script = ExtResource("1")
id = &"controlled_environment"
temperature_opt = 0.60
temperature_tolerance = 0.55
water_opt = 0.60
water_tolerance = 0.52
floor_q16 = 13107
exposure_q16 = 32768
"""

STAT = "country.climate.profile.controlled_environment.heat_stress_loss_factor"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    dry = arguments.dry_run
    log = []

    climate_path = os.path.join(CLIMATES, "controlled_environment.tres")
    if os.path.exists(climate_path) and os.path.getsize(climate_path) > 0:
        log.append("SKIP 气候档案 controlled_environment 已存在")
    else:
        log.append("新增气候档案 controlled_environment（宽耐受 / 高下限）")
        if not dry:
            with open(climate_path + ".v5tmp", "w", encoding="utf-8", newline="\n") as handle:
                handle.write(BODY)
            os.replace(climate_path + ".v5tmp", climate_path)

    building_path = os.path.join(BUILDINGS, "automated_farm.tres")
    if os.path.exists(building_path):
        text = open(building_path, encoding="utf-8").read()
        if 'production_climate_profile_id = &"controlled_environment"' in text:
            log.append("SKIP automated_farm 已使用新档案")
        else:
            match = re.search(r'^production_climate_profile_id = &"([^"]*)"', text, re.M)
            if match:
                text = text.replace(match.group(0),
                                    'production_climate_profile_id = &"controlled_environment"', 1)
                log.append("FIX automated_farm 气候档案 %s → controlled_environment"
                           % match.group(1))
                if not dry:
                    with open(building_path + ".v5tmp", "w", encoding="utf-8", newline="\n") as handle:
                        handle.write(text)
                    os.replace(building_path + ".v5tmp", building_path)
    else:
        log.append("SKIP 找不到 automated_farm")

    data = json.load(open(NETWORK, encoding="utf-8"))
    node = next((entry for entry in data["nodes"]
                 if entry["id"] == "tech.automated_agriculture"), None)
    if node is None:
        log.append("SKIP 找不到 tech.automated_agriculture")
    else:
        terms = node.setdefault("modifier_terms", [])
        if any(term.get("stat") == STAT for term in terms):
            log.append("SKIP 自动化农业已有受控环境效果")
        else:
            terms.append({
                "stat": STAT, "operation": 0.0, "value": -0.12,
                "subject_kind": "climate_profile", "subject_id": "controlled_environment",
                "subject_display_name": "可控环境",
                "effect_class": "气候适应",
                "effect_rationale": "温室与环控把高温挡在棚外，热害损失显著下降。",
                "implementation_status": "runtime_consumed",
                "runtime_consumer": "NativeEconomyRuntime country climate loss heat",
            })
            log.append("FIX tech.automated_agriculture 追加受控环境热害减免 −12%")
            if not dry:
                temporary = NETWORK + ".v5tmp"
                with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
                    json.dump(data, handle, ensure_ascii=False, indent="\t")
                    handle.write("\n")
                os.replace(temporary, NETWORK)

    if os.path.exists(CATALOG_TEST):
        text = open(CATALOG_TEST, encoding="utf-8").read()
        if "profile_stat_count == 32" in text:
            log.append("SKIP 测试已按 8 档案更新")
        elif "profile_stat_count == 28" in text:
            text = text.replace("assert(profile_stat_count == 28)",
                                "assert(profile_stat_count == 32)")
            log.append("FIX technology_catalog_test 档案 stat 数 28 → 32")
            if not dry:
                with open(CATALOG_TEST + ".v5tmp", "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(text)
                os.replace(CATALOG_TEST + ".v5tmp", CATALOG_TEST)

    for line in log:
        print(line)
    print("--- %s ---" % ("dry-run" if dry else "written"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
