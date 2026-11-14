# -*- coding: utf-8 -*-
"""v5 内容：补一个陆战兵种 —— 盾兵。

设计意图：王国代的高防御步兵，专为 `hold_the_line` 服务（防御高、速度低，只能站着打）。

> 海军（巡防舰/铁甲舰/驱逐舰）与空军（航空队）按用户要求不做，
> 因此本文件只保留盾兵。舰体/飞机相关的物资与建筑脚本已删除。
"""
from __future__ import annotations

import argparse
import json
import os
import sys

CATALOG = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\military\military_catalog.json")

UNITS = [
    {
        "id": "shield_bearers",
        "repair": {"goods": [{"good": "lumber", "weight": 1},
                             {"good": "iron_weapons", "weight": 1}]},
        "name": "盾兵",
        "description": "大盾与重甲让步兵第一次能「站在箭雨里」，阵线的价值超过个人的武艺。",
        "class": "line",
        "era": 2,
        "tech": "tech.military.standing_army",
        "militia": False,
        "attack": 1.8,
        "defense": 4.6,
        "speed": 0.9,
        "fortification_ignore": 0.0,
        "training_days": 45,
        "equipment": [
            {"category": "melee_arms", "min_quality": 2, "per_100": 10.0, "weight": 0.45},
            {"category": "body_armor", "min_quality": 2, "per_100": 12.0, "weight": 0.40},
            {"category": "missile_arms", "min_quality": 1, "per_100": 4.0, "weight": 0.15},
        ],
        "supply_idle": {"ration": 0.0, "fodder": 0.0, "ammunition": 0.0,
                        "fuel": 0.0, "upkeep": 0.05},
        "supply_combat": {"ration": 0.0, "fodder": 0.0, "ammunition": 0.0,
                          "fuel": 0.0, "upkeep": 0.14},
        "icon": "unit.line",
    },
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    data = json.load(open(CATALOG, encoding="utf-8"))
    units = data.setdefault("units", [])
    existing = {unit.get("id") for unit in units}
    for unit in UNITS:
        if unit["id"] in existing:
            print("SKIP 兵种 %s 已存在" % unit["id"])
            continue
        units.append(unit)
        print("新增兵种 %-16s era=%d tech=%s" % (unit["id"], unit["era"], unit["tech"]))
    if arguments.dry_run:
        print("--- dry-run ---")
        return 0
    temporary = CATALOG + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temporary, CATALOG)
    print("--- written：%d units ---" % len(units))
    return 0


if __name__ == "__main__":
    sys.exit(main())
