"""
Refined era-chain analysis — properly handles:
1. Category-based inputs (tools category has chipped_stone_tools, bronze_tools, etc.)
2. Upgrade buildings with lower-tier alternatives that don't need those inputs
"""
import os
import re
from collections import defaultdict

BUILDINGS_DIR = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\economy\buildings"
GOODS_DIR = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\goods"

ERA_ORDER = {"stone":0,"bronze":1,"classical":2,"feudal":3,"exploration":4,"enlightenment":5,"steam":6,"electrical":7,"atomic":8,"information":9,"ai":10}
ERA_DISPLAY = {"stone":"石器时代","bronze":"青铜时代","classical":"古典时代","feudal":"封建时代","exploration":"探索时代","enlightenment":"启蒙时代","steam":"蒸汽时代","electrical":"电气时代","atomic":"原子时代","information":"信息时代","ai":"人工智能时代"}
TAG_TO_ERA = {
    "tech.hunting":"stone","tech.gathering":"stone","tech.stone_knapping":"stone","tech.fire_control":"stone",
    "tech.pottery":"bronze","tech.bronze_casting":"bronze",
    "tech.writing":"classical","tech.masonry":"classical",
    "tech.manuscript_culture":"feudal","tech.guild_organization":"feudal",
    "tech.oceanic_navigation":"exploration","tech.printing_press":"exploration",
    "tech.experimental_science":"enlightenment","tech.precision_engineering":"enlightenment",
    "tech.coke_smelting":"steam","tech.steam_power":"steam",
    "tech.electrification":"electrical","tech.radio":"electrical","tech.electrochemistry":"electrical",
    "tech.geological_prospecting":"atomic","tech.advanced_metallurgy":"atomic","tech.nuclear_fission":"atomic",
    "tech.digital_computing":"information","tech.networked_computing":"information","tech.legacy_modern_economy":"information",
    "tech.machine_learning":"ai","tech.autonomous_systems":"ai",
}

def parse_tres(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    result = {"id":None,"display_name":None,"tags":[],"input_goods":[],"input_categories":[],
              "output_goods":[],"resource_ids":[],"upgrade_family":"","upgrade_tier":0}
    m = re.search(r'id\s*=\s*&"([^"]+)"', content)
    if m: result["id"] = m.group(1)
    m = re.search(r'display_name\s*=\s*"([^"]*)"', content)
    if m: result["display_name"] = m.group(1)
    m = re.search(r'technology_tags\s*=\s*PackedStringArray\((.*?)\)', content, re.DOTALL)
    if m: result["tags"] = re.findall(r'"([^"]+)"', m.group(1))
    m = re.search(r'input_good_ids\s*=\s*PackedStringArray\((.*?)\)', content, re.DOTALL)
    if m: result["input_goods"] = re.findall(r'"([^"]+)"', m.group(1))
    m = re.search(r'input_category_ids\s*=\s*PackedStringArray\((.*?)\)', content, re.DOTALL)
    if m:
        # Extract ALL strings including empty ones: PackedStringArray("", "tools")
        raw = m.group(1)
        result["input_categories"] = re.findall(r'"([^"]*)"', raw)
    m = re.search(r'output_good_ids\s*=\s*PackedStringArray\((.*?)\)', content, re.DOTALL)
    if m: result["output_goods"] = re.findall(r'"([^"]+)"', m.group(1))
    m = re.search(r'resource_ids\s*=\s*PackedStringArray\((.*?)\)', content, re.DOTALL)
    if m: result["resource_ids"] = re.findall(r'"([^"]+)"', m.group(1))
    m = re.search(r'upgrade_family_id\s*=\s*&"([^"]*)"', content)
    if m: result["upgrade_family"] = m.group(1)
    m = re.search(r'upgrade_tier\s*=\s*(\d+)', content)
    if m: result["upgrade_tier"] = int(m.group(1))
    return result

def get_era(tags):
    earliest_idx = 999
    earliest_era = None
    for tag in tags:
        era = TAG_TO_ERA.get(tag)
        if era and ERA_ORDER.get(era, 999) < earliest_idx:
            earliest_idx = ERA_ORDER[era]
            earliest_era = era
    return earliest_era

def parse_good_category(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
    m = re.search(r'category_id\s*=\s*&"([^"]+)"', content)
    return m.group(1) if m else None

def main():
    buildings = []
    good_producers = defaultdict(list)  # good -> [(building_id, display_name, era)]
    good_category = {}  # good_name -> category_id
    upgrade_families = defaultdict(list)  # family_id -> [(tier, building)]

    # Parse goods for categories
    for fname in os.listdir(GOODS_DIR):
        if not fname.endswith('.tres'): continue
        good_name = fname[:-5]
        cat = parse_good_category(os.path.join(GOODS_DIR, fname))
        if cat:
            good_category[good_name] = cat

    # Parse buildings
    for fname in sorted(os.listdir(BUILDINGS_DIR)):
        if not fname.endswith('.tres'): continue
        b = parse_tres(os.path.join(BUILDINGS_DIR, fname))
        if not b["id"]: continue
        buildings.append(b)
        if b["upgrade_family"]:
            upgrade_families[b["upgrade_family"]].append((b["upgrade_tier"], b))

    # Build producer map
    for b in buildings:
        era = get_era(b["tags"])
        for g in b["output_goods"]:
            good_producers[g].append((b["id"], b["display_name"], era))

    # Find genuine issues
    issues = []

    for b in buildings:
        b_era = get_era(b["tags"])
        if b_era is None:
            continue

        for idx, input_good in enumerate(b["input_goods"]):
            # Check if this input uses category fallback
            input_cat = ""
            if idx < len(b["input_categories"]):
                input_cat = b["input_categories"][idx]

            # Category fallback means any good in that category works
            # Get the category of the input good
            good_cat = good_category.get(input_good, "")
            
            has_category_fallback = bool(input_cat) and input_cat == good_cat
            
            # Check if there are earlier goods in the same category
            if has_category_fallback and good_cat:
                # Check if ANY good in this category is available at or before this era
                cat_goods_available = False
                for gname, gcat in good_category.items():
                    if gcat == good_cat:
                        producers = good_producers.get(gname, [])
                        for pid, pname, pera in producers:
                            if pera and ERA_ORDER.get(pera, 999) <= ERA_ORDER.get(b_era, 999):
                                cat_goods_available = True
                                break
                    if cat_goods_available:
                        break
                if cat_goods_available:
                    continue  # Category substitute available, skip

            # Find earliest producer of this exact good
            producers = good_producers.get(input_good, [])
            if not producers:
                issues.append({
                    "building": b, "input_good": input_good, "type": "no_producer",
                    "detail": f"物资 '{input_good}' 没有任何建筑产出"
                })
                continue

            earliest = min(producers, key=lambda x: ERA_ORDER.get(x[2], 999))
            earliest_era = earliest[2]
            if earliest_era is None:
                continue

            b_era_idx = ERA_ORDER.get(b_era, 0)
            earliest_era_idx = ERA_ORDER.get(earliest_era, 0)
            if earliest_era_idx > b_era_idx:
                # Check if this is an upgrade building where lower tiers work fine
                is_upgrade_blocked = True
                if b["upgrade_family"] and b["upgrade_tier"] > 0:
                    # Check if any lower tier in this family doesn't need this input
                    # Actually, we only consider it a problem if there's NO lower tier
                    # that produces the same output without this problematic input.
                    # For upgrade buildings (tier > 1): the tier 1 building should work.
                    # For tier 1 buildings in a new family: it IS a problem.
                    family_buildings = upgrade_families.get(b["upgrade_family"], [])
                    lower_tiers_exist = any(t < b["upgrade_tier"] for t, _ in family_buildings)
                    if lower_tiers_exist:
                        is_upgrade_blocked = False

                if is_upgrade_blocked:
                    era_gap = earliest_era_idx - b_era_idx
                    issues.append({
                        "building": b,
                        "input_good": input_good,
                        "type": "era_mismatch",
                        "earliest_producer_era": earliest_era,
                        "earliest_producer_name": earliest[1],
                        "earliest_producer_id": earliest[0],
                        "era_gap": era_gap,
                    })

    # Sort by era gap desc
    issues.sort(key=lambda x: (x.get("era_gap") or 0), reverse=True)

    print("=" * 90)
    print("产业链时代断层分析报告（已过滤分类替代假阳性 + 升级建筑假阳性）")
    print("=" * 90)
    print()

    mismatches = [i for i in issues if i["type"] == "era_mismatch"]
    no_prods = [i for i in issues if i["type"] == "no_producer"]

    print(f"发现 {len(mismatches)} 个时代断层问题，{len(no_prods)} 个无产出建筑问题")
    print()

    if mismatches:
        print("## 一、时代断层问题（输入物资在更晚时代才有生产者）")
        print()
        for i, p in enumerate(mismatches):
            b = p["building"]
            eb = ERA_DISPLAY.get(get_era(b["tags"]), str(get_era(b["tags"])))
            ep = ERA_DISPLAY.get(p["earliest_producer_era"], str(p["earliest_producer_era"]))
            fam = f", 升级链: {b['upgrade_family']} tier {b['upgrade_tier']}" if b["upgrade_family"] else ""
            print(f"### {i+1}. {b['display_name']} → {p['input_good']}")
            print(f"  - 建筑: {b['id']} ({eb}){fam}")
            print(f"  - 建筑标签: {b['tags']}")
            print(f"  - 需要物资: {p['input_good']}")
            print(f"  - 最早产出建筑: {p['earliest_producer_id']} ({p['earliest_producer_name']}, {ep})")
            print(f"  - 时代差距: {p['era_gap']} 个时代")
            print(f"  - 问题: {b['display_name']}在{eb}解锁，但其必需输入物资{p['input_good']}只能由{ep}的建筑产出")
            print()

            # Chain analysis
            all_prods = good_producers.get(p["input_good"], [])
            if len(all_prods) > 1:
                print(f"  - 所有产出者:")
                for prod in all_prods:
                    pe = ERA_DISPLAY.get(prod[2], "无时代限制") if prod[2] else "无时代限制"
                    print(f"    - {prod[0]} ({prod[1]}, {pe})")
                print()

    # Print summary table
    print()
    print("## 二、问题汇总")
    print()
    print("| # | 建筑 | 时代 | 输入物资 | 物资最早产出时代 | 差距 |")
    print("|---|------|------|----------|------------------|------|")
    for i, p in enumerate(mismatches):
        b = p["building"]
        eb = ERA_DISPLAY.get(get_era(b["tags"]), "?")
        ep = ERA_DISPLAY.get(p["earliest_producer_era"], "?")
        print(f"| {i+1} | {b['display_name']} | {eb} | {p['input_good']} | {ep} | {p['era_gap']}个时代 |")

    if mismatches:
        print()
        print("## 三、建议修复方案")
        print()
        for i, p in enumerate(mismatches):
            b = p["building"]
            eb = ERA_DISPLAY.get(get_era(b["tags"]), "?")
            ep = ERA_DISPLAY.get(p["earliest_producer_era"], "?")
            print(f"### {i+1}. {b['display_name']} → {p['input_good']}")
            print()
            print(f"**方案A**: 将 {p['earliest_producer_id']} ({p['earliest_producer_name']}) 的时代标签从 {ep} 前移到 {eb} 或更早。")
            print(f"**方案B**: 为 {p['input_good']} 新增一个 {eb}（或更早）时代的替代产出建筑。")
            print(f"**方案C**: 将 {b['id']} ({b['display_name']}) 的时代标签从 {eb} 后移到 {ep} 或更晚。")
            print(f"**方案D**: 添加 category 替代机制，允许{b['display_name']}使用同一 category 的更早期物资。")
            print()

if __name__ == "__main__":
    main()
