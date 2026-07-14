"""
Analyze all building .tres files for era-chain inconsistencies:
- Building at era X requires input good G, but earliest producer of G is at era Y > X.
"""

import os
import re
from collections import defaultdict

BUILDINGS_DIR = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\economy\buildings"

# Era ordering (0 = earliest)
ERA_ORDER = {
    "stone": 0,
    "bronze": 1,
    "classical": 2,
    "feudal": 3,
    "exploration": 4,
    "enlightenment": 5,
    "steam": 6,
    "electrical": 7,
    "atomic": 8,
    "information": 9,
    "ai": 10,
}

ERA_DISPLAY = {
    "stone": "石器时代",
    "bronze": "青铜时代",
    "classical": "古典时代",
    "feudal": "封建时代",
    "exploration": "探索时代",
    "enlightenment": "启蒙时代",
    "steam": "蒸汽时代",
    "electrical": "电气时代",
    "atomic": "原子时代",
    "information": "信息时代",
    "ai": "人工智能时代",
}

TAG_TO_ERA = {
    "tech.hunting": "stone",
    "tech.gathering": "stone",
    "tech.stone_knapping": "stone",
    "tech.fire_control": "stone",
    "tech.pottery": "bronze",
    "tech.bronze_casting": "bronze",
    "tech.writing": "classical",
    "tech.masonry": "classical",
    "tech.manuscript_culture": "feudal",
    "tech.guild_organization": "feudal",
    "tech.oceanic_navigation": "exploration",
    "tech.printing_press": "exploration",
    "tech.experimental_science": "enlightenment",
    "tech.precision_engineering": "enlightenment",
    "tech.coke_smelting": "steam",
    "tech.steam_power": "steam",
    "tech.electrification": "electrical",
    "tech.radio": "electrical",
    "tech.electrochemistry": "electrical",
    "tech.geological_prospecting": "atomic",
    "tech.advanced_metallurgy": "atomic",
    "tech.nuclear_fission": "atomic",
    "tech.digital_computing": "information",
    "tech.networked_computing": "information",
    "tech.legacy_modern_economy": "information",
    "tech.machine_learning": "ai",
    "tech.autonomous_systems": "ai",
}


def parse_tres(filepath):
    """Parse a .tres file and extract key fields."""
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()

    result = {
        "id": None,
        "display_name": None,
        "tags": [],
        "input_goods": [],
        "output_goods": [],
        "resource_ids": [],
    }

    # id
    m = re.search(r'id\s*=\s*&"([^"]+)"', content)
    if m:
        result["id"] = m.group(1)

    # display_name
    m = re.search(r'display_name\s*=\s*"([^"]*)"', content)
    if m:
        result["display_name"] = m.group(1)

    # technology_tags
    m = re.search(
        r"technology_tags\s*=\s*PackedStringArray\((.*?)\)", content, re.DOTALL
    )
    if m:
        tags_str = m.group(1)
        tags = re.findall(r'"([^"]+)"', tags_str)
        result["tags"] = tags

    # input_good_ids
    m = re.search(
        r"input_good_ids\s*=\s*PackedStringArray\((.*?)\)", content, re.DOTALL
    )
    if m:
        goods_str = m.group(1)
        goods = re.findall(r'"([^"]+)"', goods_str)
        result["input_goods"] = goods

    # output_good_ids
    m = re.search(
        r"output_good_ids\s*=\s*PackedStringArray\((.*?)\)", content, re.DOTALL
    )
    if m:
        goods_str = m.group(1)
        goods = re.findall(r'"([^"]+)"', goods_str)
        result["output_goods"] = goods

    # resource_ids (for extraction buildings)
    m = re.search(r"resource_ids\s*=\s*PackedStringArray\((.*?)\)", content, re.DOTALL)
    if m:
        res_str = m.group(1)
        resources = re.findall(r'"([^"]+)"', res_str)
        result["resource_ids"] = resources

    return result


def get_era(tags):
    """Determine the earliest era from technology_tags."""
    earliest_era = None
    earliest_idx = 999
    for tag in tags:
        era = TAG_TO_ERA.get(tag)
        if era and ERA_ORDER.get(era, 999) < earliest_idx:
            earliest_idx = ERA_ORDER[era]
            earliest_era = era
    return earliest_era


def main():
    buildings = []
    good_producers = defaultdict(list)  # good_name -> [(building_id, era, display_name)]

    # Parse all buildings
    for fname in sorted(os.listdir(BUILDINGS_DIR)):
        if not fname.endswith(".tres"):
            continue
        fpath = os.path.join(BUILDINGS_DIR, fname)
        b = parse_tres(fpath)
        if not b["id"]:
            continue
        buildings.append(b)

    # Build producer map
    for b in buildings:
        era = get_era(b["tags"])
        for g in b["output_goods"]:
            good_producers[g].append((b["id"], b["display_name"], era, b["tags"]))
        # Also treat resource extraction as producing the corresponding raw good
        # (resources like logs, iron_ore, etc. are gathered by collector buildings)
        for r in b["resource_ids"]:
            good_name = r  # resource name usually maps directly to a good
            good_producers[good_name].append(
                (b["id"], b["display_name"], era, b["tags"] + ["[resource_extraction]"])
            )

    # Find era-chain inconsistencies
    problems = []

    for b in buildings:
        b_era = get_era(b["tags"])
        if b_era is None:
            continue  # buildings without tech tags are always available (stone age effectively)

        for input_good in b["input_goods"]:
            producers = good_producers.get(input_good, [])

            if not producers:
                problems.append(
                    {
                        "building_id": b["id"],
                        "building_name": b["display_name"],
                        "building_era": b_era,
                        "building_tags": b["tags"],
                        "input_good": input_good,
                        "problem": "NO_PRODUCER",
                        "detail": f"物资 '{input_good}' 没有任何建筑产出",
                        "earliest_producer_era": None,
                        "earliest_producer_name": None,
                        "era_gap": None,
                    }
                )
                continue

            # Find earliest producer
            earliest = min(producers, key=lambda x: ERA_ORDER.get(x[2], 999))
            earliest_era = earliest[2]

            if earliest_era is None:
                continue  # producer has no era tag (always available), skip check

            b_era_idx = ERA_ORDER.get(b_era, 0)
            earliest_era_idx = ERA_ORDER.get(earliest_era, 0)

            if earliest_era_idx > b_era_idx:
                # Consumer is earlier era than producer = PROBLEM
                era_gap = earliest_era_idx - b_era_idx
                problems.append(
                    {
                        "building_id": b["id"],
                        "building_name": b["display_name"],
                        "building_era": b_era,
                        "building_tags": b["tags"],
                        "input_good": input_good,
                        "problem": "ERA_MISMATCH",
                        "detail": f"建筑 '{b['display_name']}'({b_era}) 需要 '{input_good}'，但最早产出建筑 '{earliest[1]}' 在 {earliest_era} 才解锁（晚 {era_gap} 个时代）",
                        "earliest_producer_era": earliest_era,
                        "earliest_producer_name": earliest[1],
                        "earliest_producer_id": earliest[0],
                        "era_gap": era_gap,
                        "all_producers": producers,
                    }
                )

    # Sort by era gap (largest first)
    problems.sort(key=lambda x: (x.get("era_gap") or 0), reverse=True)

    # Output report
    print("=" * 80)
    print("产业链时代断层分析报告")
    print("=" * 80)
    print()

    # Count by type
    era_mismatch = [p for p in problems if p["problem"] == "ERA_MISMATCH"]
    no_producer = [p for p in problems if p["problem"] == "NO_PRODUCER"]

    print(f"发现 {len(era_mismatch)} 个时代断层问题，{len(no_producer)} 个无产出建筑问题。")
    print()

    if era_mismatch:
        print("## 时代断层问题（输入物资在更晚时代才解锁）")
        print()
        for i, p in enumerate(era_mismatch):
            era_b = ERA_DISPLAY.get(p["building_era"], p["building_era"])
            era_p = (
                ERA_DISPLAY.get(p["earliest_producer_era"], p["earliest_producer_era"])
                if p["earliest_producer_era"]
                else "?"
            )
            print(f"### {i+1}. {p['building_name']} → {p['input_good']}")
            print(f"  - 建筑: {p['building_id']} ({era_b})")
            print(f"  - 需要物资: {p['input_good']}")
            print(f"  - 最早产出建筑: {p['earliest_producer_id']} ({p['earliest_producer_name']}, {era_p})")
            print(f"  - 时代差距: {p['era_gap']} 个时代")
            print(f"  - 建筑标签: {p['building_tags']}")
            all_prods = p.get("all_producers", [])
            if len(all_prods) > 1:
                print(f"  - 所有产出者:")
                for prod in all_prods:
                    pe = ERA_DISPLAY.get(prod[2], str(prod[2])) if prod[2] else "无时代限制"
                    print(f"    - {prod[0]} ({prod[1]}, {pe})")
            print()

    if no_producer:
        print("## 无产出建筑（物资没有任何建筑产出）")
        print()
        for i, p in enumerate(no_producer):
            era_b = ERA_DISPLAY.get(p["building_era"], p["building_era"])
            print(f"### {i+1}. {p['building_name']} → {p['input_good']}")
            print(f"  - 建筑: {p['building_id']} ({era_b})")
            print(f"  - 缺少产出者: {p['input_good']}")
            print()

    # Also output good_producers stats
    print()
    print("=" * 80)
    print("物资产出覆盖统计")
    print("=" * 80)
    goods_with_producer = len(good_producers)
    print(f"总计 {goods_with_producer} 种物资有建筑产出（含资源采集建筑）")
    print()

    # List goods that only have one producer
    single_producer_goods = []
    for good, producers in good_producers.items():
        if len(producers) == 1:
            pe = producers[0]
            era_id = pe[2]
            era_name = ERA_DISPLAY.get(era_id, "无限制") if era_id else "无时代限制"
            single_producer_goods.append((good, pe[0], pe[1], era_name))
    single_producer_goods.sort()
    print(f"{len(single_producer_goods)} 种物资仅有单一产出建筑：")
    for g, bid, bname, era in single_producer_goods:
        print(f"  - {g}: {bid} ({bname}, {era})")


if __name__ == "__main__":
    main()
