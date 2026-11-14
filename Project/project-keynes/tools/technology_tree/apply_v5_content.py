# -*- coding: utf-8 -*-
"""v5 内容数据修复（P0）：只改既有字段，不新增内容。

覆盖 04-content-changes.md §1 中风险最低、收益最高的一批：
  * 汽车链在电气代无法启动（engines_plant 需要原子代才有的铝）
  * 7 座建筑用 structural_metal 作建材，而该类只有蒸汽之后的成员 → 永远造不出来
  * 若干"输入早于解锁"的时序死锁
  * 兵种绑定与装备槽错位
  * progression_step / upgrade_tier 倒挂

用法：
  python apply_v5_content.py --dry-run
  python apply_v5_content.py
幂等：已是目标值的条目会被跳过。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILDINGS = os.path.join(ROOT, "data", "economy", "buildings")
GOODS = os.path.join(ROOT, "data", "goods")
MILITARY = os.path.join(ROOT, "data", "military", "military_catalog.json")
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")

# (建筑 id, 字段, 旧片段, 新片段, 说明)
TRES_EDITS = [
    # ---- 汽车链时序死锁：铝到原子代才有，发动机厂在电气代
    ("engines_plant", "input_good_ids", '"aluminum"', '"copper"',
     "发动机厂在电气代，铝要等原子代；改用铜（绕组/线束），汽车链才能在本代启动"),
    # ---- 建材类别倒挂：structural_metal 只有 steel/aluminum/stainless（全在蒸汽之后）
    ("early_iron_mine", "construction_category_ids", '"structural_metal"', '"ferrous_stock"',
     "铁矿在帝国代，建材不能用蒸汽后的钢材类别"),
    ("gold_mine", "construction_category_ids", '"structural_metal"', '"ferrous_stock"',
     "金矿在探索代，同上"),
    ("silver_mine", "construction_category_ids", '"structural_metal"', '"ferrous_stock"',
     "银矿在探索代，同上"),
    ("cement_plant", "construction_category_ids", '"structural_metal"', '"ferrous_stock"',
     "造水泥的厂不该先要求钢"),
    ("improved_smallholding", "construction_category_ids", '"structural_metal"', '"ferrous_stock"',
     "自耕农场在启蒙代，同上"),
    ("learned_society", "construction_category_ids", '"structural_metal"', '"ferrous_stock"',
     "博学学会在启蒙代，同上"),
    ("silica_sand_collector", "construction_category_ids", '"structural_metal"', '"ferrous_stock"',
     "硅砂采集在启蒙代，同上"),
    # ---- 输入早于解锁
    ("leather_goods_manufactory", "input_good_ids", '"industrial_chemicals"', '"lime"',
     "皮革制品厂在探索代，工业化学品要等蒸汽代"),
    ("method_marine_fish_collector_r2", "input_good_ids", '"natural_rubber"', '"bast_fiber"',
     "二阶段渔船在探索代早期，天然橡胶要等后期"),
    ("machine_parts_plant", "input_good_ids", '"lubricants"', '"coke"',
     "机械零件厂在探索代，润滑油要等电气代"),
    # ---- 阶梯倒挂
    ("nitric_acid_plant", "progression_step", "5", "6",
     "硝酸厂在电气代，应排在无烟火药（蒸汽代，step 5）之后"),
    ("smokeless_powder_works", "progression_step", "6", "5",
     "无烟火药在蒸汽代，是硝酸的前一步"),
    ("potato_collector", "progression_step", "2", "3",
     "马铃薯采集在农耕代，必须晚于家户块茎园（step 2）且早于佃农薯田（step 5）"),
    ("bark_paper_workshop", "progression_step", "1", "1", "树皮纸是最早的造纸工序，保持 step 1"),
    ("plant_fiber_paper_workshop", "progression_step", "1", "2", "植物纤维纸晚于树皮纸"),
    ("parchment_workshop", "progression_step", "1", "3", "羊皮纸是纸的替代品，排在造纸之后"),
    ("learned_society", "upgrade_tier", "7", "6", "研究机构家族里 6 级属于启蒙，7 级属于电气"),
    ("industrial_research_laboratory", "upgrade_tier", "6", "7", "同上：电气的研究实验室是 7 级"),

]

GOOD_TAG_EDITS = [
    # horses 不能单独加 tag：economy_catalog 要求物资的每个科技标签都有同标签的生产者建筑，
    # 且建筑只允许一个 tech.* 绑定（building_technology_binding_must_be_single）。
    ("hide_armor", "technology_tags", 'tech.hide_tanning',
     "皮甲必须由皮革鞣制解锁"),
]

MILITARY_UNIT_EDITS = [
    ("bronze_spearmen", "tech", "tech.hide_tanning", "tech.bronze_casting",
     "青铜矛兵不能由鞣皮解锁"),
]
MILITARY_EQUIPMENT_EDITS = [
    ("mechanized_infantry", "mounts", "armored_vehicles",
     "机械化步兵要求马匹是复制粘贴错误"),
    ("sp_artillery", "mounts", "armored_vehicles",
     "自行火炮要求马匹同上"),
]

NETWORK_STRING_EDITS = [
    ("development.trade.partners_8", "development.trade.partners_4",
     "默认局总国家数 6，永远凑不到 8 个贸易伙伴 → 死分支"),
]


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def write(path, text):
    temporary = path + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    os.replace(temporary, path)


def apply_tres(log, dry_run):
    count = 0
    for building_id, field, old, new, reason in TRES_EDITS:
        if old == new:
            continue
        path = os.path.join(BUILDINGS, building_id + ".tres")
        if not os.path.exists(path):
            log.append("SKIP 缺少文件 %s" % building_id)
            continue
        text = read(path)
        pattern = re.compile(r"^(%s = .*)$" % re.escape(field), re.M)
        match = pattern.search(text)
        if match is None:
            log.append("SKIP %s 无字段 %s" % (building_id, field))
            continue
        line = match.group(1)
        if old not in line:
            if new in line:
                continue
            log.append("SKIP %s.%s 不含 %s" % (building_id, field, old))
            continue
        new_line = line.replace(old, new, 1)
        text = text[:match.start(1)] + new_line + text[match.end(1):]
        count += 1
        log.append("FIX  %-30s %-26s %s → %s ｜ %s" % (
            building_id, field, old.strip('"'), new.strip('"'), reason))
        if not dry_run:
            write(path, text)
    return count


def apply_good_tags(log, dry_run):
    count = 0
    for good_id, field, tag, reason in GOOD_TAG_EDITS:
        path = os.path.join(GOODS, good_id + ".tres")
        if not os.path.exists(path):
            log.append("SKIP 缺少物资 %s" % good_id)
            continue
        text = read(path)
        match = re.search(r"^(%s = PackedStringArray\(([^)]*)\))$" % re.escape(field),
                          text, re.M)
        if match is None:
            log.append("SKIP %s 无字段 %s" % (good_id, field))
            continue
        if '"%s"' % tag in match.group(2):
            continue
        new_line = '%s = PackedStringArray(%s, "%s")' % (
            field, match.group(2).strip(), tag)
        new_line = new_line.replace("PackedStringArray(, ", "PackedStringArray(")
        text = text[:match.start(0)] + new_line + text[match.end(0):]
        count += 1
        log.append("FIX  %-30s %-26s += %s ｜ %s" % (good_id, field, tag, reason))
        if not dry_run:
            write(path, text)
    return count


def _unit_span(text, unit_id):
    """返回该兵种 JSON 文本片段 [start, end)，用于作用域内替换。"""
    marker = '"id": "%s"' % unit_id
    start = text.find(marker)
    if start < 0:
        return None
    end = text.find('\n      "id": "', start + len(marker))
    if end < 0:
        end = text.find("\n    }", start)
        end = len(text) if end < 0 else end
    return start, end


def apply_military(log, dry_run):
    """兵种修正用作用域文本替换，避免整份 JSON 重排。"""
    if not os.path.exists(MILITARY):
        log.append("SKIP 缺少 military_catalog.json")
        return 0
    text = read(MILITARY)
    count = 0
    for unit_id, old_tech, new_tech, reason in [
            (row[0], row[2], row[3], row[4]) for row in MILITARY_UNIT_EDITS]:
        span = _unit_span(text, unit_id)
        if span is None:
            log.append("SKIP 找不到兵种 %s" % unit_id)
            continue
        chunk = text[span[0]:span[1]]
        old_key = '"tech": "%s"' % old_tech
        if old_key not in chunk:
            continue
        chunk = chunk.replace(old_key, '"tech": "%s"' % new_tech, 1)
        text = text[:span[0]] + chunk + text[span[1]:]
        count += 1
        log.append("FIX  unit %-24s tech %s → %s ｜ %s" % (
            unit_id, old_tech, new_tech, reason))
    for unit_id, old_category, new_category, reason in MILITARY_EQUIPMENT_EDITS:
        span = _unit_span(text, unit_id)
        if span is None:
            log.append("SKIP 找不到兵种 %s" % unit_id)
            continue
        chunk = text[span[0]:span[1]]
        old_key = '"category": "%s"' % old_category
        if old_key not in chunk:
            continue
        chunk = chunk.replace(old_key, '"category": "%s"' % new_category, 1)
        text = text[:span[0]] + chunk + text[span[1]:]
        count += 1
        log.append("FIX  unit %-24s equipment %s → %s ｜ %s" % (
            unit_id, old_category, new_category, reason))
    if count and not dry_run:
        write(MILITARY, text)
    return count


def apply_network_strings(log, dry_run):
    if not os.path.exists(NETWORK):
        log.append("SKIP 缺少 technology_network.json")
        return 0
    text = read(NETWORK)
    count = 0
    for old, new, reason in NETWORK_STRING_EDITS:
        occurrences = text.count('"%s"' % old)
        if occurrences == 0:
            continue
        text = text.replace('"%s"' % old, '"%s"' % new)
        count += occurrences
        log.append("FIX  network %-38s → %s ｜ %s（%d 处）" % (old, new, reason, occurrences))
    if count and not dry_run:
        write(NETWORK, text)
    return count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    log = []
    total = 0
    total += apply_tres(log, arguments.dry_run)
    total += apply_good_tags(log, arguments.dry_run)
    total += apply_military(log, arguments.dry_run)
    total += apply_network_strings(log, arguments.dry_run)
    for line in log:
        print(line)
    print("--- %s：%d 处改动 ---" % ("dry-run" if arguments.dry_run else "written", total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
