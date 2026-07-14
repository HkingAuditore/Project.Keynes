"""
Final comprehensive analysis with cascading chain tracking.
"""
import os, re
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
    if m: result["input_categories"] = re.findall(r'"([^"]*)"', m.group(1))
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
    good_producers = defaultdict(list)
    good_category = {}
    upgrade_families = defaultdict(list)

    # Parse goods
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

    # === PASS 1: Direct mismatch detection ===
    direct_issues = []

    for b in buildings:
        b_era = get_era(b["tags"])
        if b_era is None:
            continue

        for idx, input_good in enumerate(b["input_goods"]):
            input_cat = ""
            if idx < len(b["input_categories"]):
                input_cat = b["input_categories"][idx]

            good_cat = good_category.get(input_good, "")
            has_category_fallback = bool(input_cat) and input_cat == good_cat

            # Check category substitution availability
            if has_category_fallback and good_cat:
                cat_ok = False
                for gname, gcat in good_category.items():
                    if gcat == good_cat:
                        for _, _, pera in good_producers.get(gname, []):
                            if pera and ERA_ORDER.get(pera, 999) <= ERA_ORDER.get(b_era, 999):
                                cat_ok = True
                                break
                    if cat_ok: break
                if cat_ok: continue

            producers = good_producers.get(input_good, [])
            if not producers: continue

            earliest = min(producers, key=lambda x: ERA_ORDER.get(x[2], 999))
            earliest_era = earliest[2]
            if earliest_era is None: continue

            b_era_idx = ERA_ORDER.get(b_era, 0)
            earliest_era_idx = ERA_ORDER.get(earliest_era, 0)
            if earliest_era_idx > b_era_idx:
                # Check upgrade building
                is_blocked = True
                if b["upgrade_family"] and b["upgrade_tier"] > 0:
                    lower = any(t < b["upgrade_tier"] for t, _ in upgrade_families.get(b["upgrade_family"], []))
                    if lower: is_blocked = False
                if is_blocked:
                    direct_issues.append({
                        "building": b, "input_good": input_good,
                        "earliest_producer_era": earliest_era,
                        "earliest_producer_name": earliest[1],
                        "earliest_producer_id": earliest[0],
                        "era_gap": earliest_era_idx - b_era_idx,
                    })

    direct_issues.sort(key=lambda x: x["era_gap"], reverse=True)

    # === PASS 2: Cascading chain analysis ===
    # For each direct issue, trace the input good's producer chain to see if it
    # also has era mismatches (cascading)

    def trace_era_mismatch_chain(good_name, consumer_era, visited=None, depth=0):
        """Recursively trace era mismatches upstream."""
        if visited is None:
            visited = set()
        if good_name in visited or depth > 5:
            return []
        visited.add(good_name)

        issues = []
        producers = good_producers.get(good_name, [])
        for pid, pname, pera in producers:
            if pera is None: continue
            if ERA_ORDER.get(pera, 999) > ERA_ORDER.get(consumer_era, 999):
                # This producer is too late for the consumer
                continue  # Already captured as direct issue
            # Check this producer's inputs
            for b in buildings:
                if b["id"] == pid:
                    b_era = get_era(b["tags"])
                    if b_era is None: b_era = consumer_era  # use consumer era as baseline
                    for idx, input_g in enumerate(b["input_goods"]):
                        # Skip category fallback inputs
                        input_cat = ""
                        if idx < len(b["input_categories"]):
                            input_cat = b["input_categories"][idx]
                        good_cat = good_category.get(input_g, "")
                        if input_cat and input_cat == good_cat:
                            # Has category fallback - check if early alternative available
                            cat_ok = False
                            for gn, gc in good_category.items():
                                if gc == good_cat:
                                    for _, _, pe in good_producers.get(gn, []):
                                        if pe and ERA_ORDER.get(pe, 999) <= ERA_ORDER.get(consumer_era, 999):
                                            cat_ok = True; break
                                if cat_ok: break
                            if cat_ok: continue

                        in_producers = good_producers.get(input_g, [])
                        if not in_producers: continue
                        earliest_in = min(in_producers, key=lambda x: ERA_ORDER.get(x[2], 999))
                        earliest_in_era = earliest_in[2]
                        if earliest_in_era is None: continue
                        if ERA_ORDER.get(earliest_in_era, 999) > ERA_ORDER.get(consumer_era, 999):
                            issues.append({
                                "good": input_g,
                                "earliest_producer": earliest_in[1],
                                "earliest_producer_era": earliest_in_era,
                                "era_gap": ERA_ORDER.get(earliest_in_era, 0) - ERA_ORDER.get(consumer_era, 0),
                                "depth": depth + 1,
                            })
                            # Recurse
                            sub = trace_era_mismatch_chain(input_g, consumer_era, visited, depth + 1)
                            issues.extend(sub)
        return issues

    # === Generate output ===
    print("=" * 95)
    print("产业链时代断层分析报告（完整版）")
    print("=" * 95)
    print()
    print("分析方法：遍历全部 182 个建筑，按 building.technology_tags 确定解锁时代，")
    print("对比每个建筑输入物资的最早产出建筑时代。已排除以下假阳性：")
    print("  - 使用 input_category_ids 替代（如 tools 大类可经 chipped_stone_tools/bronze_tools 满足）")
    print("  - 升级链中 tier>1 建筑（已有更早 tier 可运作）")
    print()

    print(f"## 一、直接时代断层：{len(direct_issues)} 个")
    print()

    # Group by root cause
    paper_issues = [i for i in direct_issues if i["input_good"] == "paper"]
    salt_issues = [i for i in direct_issues if i["input_good"] == "salt"]
    farm_issues = [i for i in direct_issues if i["input_good"] in ("fertilizer", "agricultural_machinery")]

    for group_name, group_issues in [("paper 造纸产业链", paper_issues), ("salt 盐产业链", salt_issues), ("机械化农场供应链", farm_issues)]:
        print(f"### {group_name}（{len(group_issues)} 个建筑受影响）")
        print()
        for p in group_issues:
            b = p["building"]
            eb = ERA_DISPLAY[get_era(b["tags"])]
            ep = ERA_DISPLAY[p["earliest_producer_era"]]
            print(f"- **{b['display_name']}** ({eb}) 需要 **{p['input_good']}**，最早产出建筑 **{p['earliest_producer_name']}** 在 **{ep}**，差距 {p['era_gap']} 个时代")
        print()

    print("### 详细清单")
    print()
    for i, p in enumerate(direct_issues):
        b = p["building"]
        eb = ERA_DISPLAY[get_era(b["tags"])]
        ep = ERA_DISPLAY[p["earliest_producer_era"]]
        print(f"#### {i+1}. {b['display_name']} → {p['input_good']}")
        print(f"| 字段 | 值 |")
        print(f"|------|-----|")
        print(f"| 建筑 ID | {b['id']} |")
        print(f"| 建筑时代 | {eb} |")
        print(f"| 建筑标签 | {', '.join(b['tags'])} |")
        print(f"| 升级链 | {b['upgrade_family'] + ' tier ' + str(b['upgrade_tier']) if b['upgrade_family'] else '无'} |")
        print(f"| 缺失物资 | {p['input_good']} |")
        print(f"| 物资最早产出建筑 | {p['earliest_producer_id']} ({p['earliest_producer_name']}) |")
        print(f"| 物资最早产出时代 | {ep} |")
        print(f"| 时代差距 | {p['era_gap']} 个时代 |")
        print()
        
        # Check for cascading issues
        cascading = trace_era_mismatch_chain(p["input_good"], get_era(b["tags"]))
        cascading.sort(key=lambda x: x["depth"])
        if cascading:
            print(f"**级联问题**（{p['input_good']}的上游供应链也存在时代断层）：")
            print()
            for ci, c in enumerate(cascading):
                cera = ERA_DISPLAY.get(c["earliest_producer_era"], "?")
                print(f"  - L{ci+1}: 物资 **{c['good']}** 最早由 **{c['earliest_producer']}** 在 **{cera}** 产出（差距 {c['era_gap']} 代）")
            print()

    # Summary table
    print("## 二、问题汇总表")
    print()
    print("| # | 建筑 | 时代 | 缺失输入 | 物资产出建筑 | 产出时代 | 时代差 |")
    print("|---|------|------|----------|-------------|----------|--------|")
    for i, p in enumerate(direct_issues):
        b = p["building"]
        eb = ERA_DISPLAY[get_era(b["tags"])]
        ep = ERA_DISPLAY[p["earliest_producer_era"]]
        print(f"| {i+1} | {b['display_name']} | {eb} | {p['input_good']} | {p['earliest_producer_name']} | {ep} | {p['era_gap']}代 |")

    print()
    print("## 三、影响分析")
    print()
    print("### 1. paper 产业链（影响最广）")
    print()
    print("```")
    print("探索时代：以下建筑无法运转（输入 paper 无来源）：")
    print("  - 包装厂 (packaging_plant)         → 产出 packaging")
    print("  - 印刷厂 (printed_materials_plant)  → 产出 printed_materials")
    print("级联影响：")
    print("  - 鱼罐头厂 (canned_fish_plant) 需要 packaging，间接被阻断")
    print("  - 马铃薯食品加工厂 (potato_food_plant) 需要 packaging，间接被阻断")
    print()
    print("根本原因：")
    print("  - paper_plant (造纸厂) 标签 tech.legacy_modern_economy → 信息时代")
    print("  - paper 物资本身标签 tech.writing → 古典时代（物资标签与生产建筑脱节）")
    print("  - papyrus(莎草纸)、parchment(羊皮纸) 可在古典/封建时代生产，但不属于同一 category")
    print("```")
    print()
    print("### 2. salt 产业链")
    print()
    print("```")
    print("探索时代：")
    print("  - 鱼罐头厂 (canned_fish_plant) 需要 salt → 无来源")
    print()
    print("根本原因：")
    print("  - salt_collector 标签 tech.legacy_modern_economy → 信息时代")
    print("  - salt 物资标签 tech.gathering → 石器时代（物资标签与生产建筑脱节）")
    print("  - 尽管 salt 是自然资源（有 ResourceProfile），但缺少早期采集建筑")
    print("```")
    print()
    print("### 3. 机械化农场供应链")
    print()
    print("```")
    print("蒸汽时代：")
    print("  - 机械化农场 (mechanized_farm) 需要 fertilizer + agricultural_machinery → 均无来源")
    print()
    print("减轻因素：")
    print("  - grain/vegetables 可通过 subsistence_food 链（subsistence_farm 青铜/three_field_smallholding 封建）")
    print("    获得，机械化农场是 field_crop_farming 新链的第1级，不影响基本食物获取")
    print("  - 但 mechanized_farm 本身在蒸汽时代解锁后完全不可用，形同虚设")
    print("```")

    print()
    print("## 四、修复建议")
    print()
    print("### Paper 链（推荐方案B或A）")
    print()
    print("**方案B（推荐）**: 新增 `early_paper_mill`（手工造纸坊），时代标签 `tech.printing_press`（或 `tech.writing`），")
    print("  使用 rag/plant_fiber + water 等古典可获取原料产出 paper，产量低于 paper_plant。")
    print("  - 优点：不破坏信息时代体系，仅补充早期缺失环节")
    print("  - 缺点：需新增1个建筑")
    print()
    print("**方案A**: 将 paper_plant 标签从 `tech.legacy_modern_economy` 改为 `tech.printing_press`。")
    print("  - 优点：简单直接")
    print("  - 缺点：造纸厂本身使用 wood_pulp（需要工业化学品），在探索时代获得工业化学品同样困难")
    print()
    print("**方案D（简单）**: 将 `paper` 物资加入与 `papyrus`/`parchment` 同一 category，")
    print("  packaging_plant 和 printed_materials_plant 设置 `input_category_ids` 为该类别。")
    print("  - 优点：改动最小")
    print("  - 缺点：语义上纸质包装用羊皮纸替代不太合理")
    print()
    print("### Salt 链（推荐方案B）")
    print()
    print("**方案B（推荐）**: 新增 `salt_evaporation_pond`（盐田/晒盐场），时代标签 `tech.writing` 或更早，")
    print("  使用海水或盐水自然蒸发产盐，无需工业设备。")
    print("  - salt 本身就是自然资源（蒸发岩 geology_family），前期完全可手工开采")
    print()
    print("**方案A**: 将 salt_collector 标签从 `tech.legacy_modern_economy` 改为 `tech.pottery` 或 `tech.writing`。")
    print("  - 优点：简单")
    print("  - 缺点：salt_collector 可能使用了工业化开采逻辑（explosives/electricity），需确认")
    print()
    print("### 机械化农场（推荐方案C 或 B）")
    print()
    print("**方案C（推荐）**: 将 mechanized_farm 时代标签从 `tech.steam_power` 改为 `tech.legacy_modern_economy`。")
    print("  - 机械化农场需要化肥和农业机械，这在蒸汽时代确实不现实；推后到信息时代更合理")
    print("  - 粮食和蔬菜已有 subsistence_food 链兜底，不影响玩家基本食物获取")
    print()
    print("**方案B**: 新增 `guano_collector`（鸟粪石采集，蒸汽时代）和 `steam_tractor_plant`（蒸汽拖拉机厂，蒸汽时代）。")
    print("  - 蒸汽时代的肥料可用鸟粪石/绿肥等有机肥")
    print("  - 蒸汽拖拉机在历史上确实存在于工业化早期")

if __name__ == "__main__":
    main()
