# -*- coding: utf-8 -*-
"""把家族/地理两类产出效果放大到"押线才有的收益"量级。

背景：放开预算上限之后实测发现，真正的约束不是上限而是**原始数值** ——
全树家族项加起来只有 +0.80（×1.80）、地理项只有 +0.35（×1.35），
单条科技仍然是 +2~5%，玩家感觉不到"押这条线"的回报。

本脚本按类别放大原始数值，再交回上限收敛（上限已放宽到 family 2.60 / geo 1.00）：

    家族产出 × 3.0     -> 上限 ×3.6
    地理专长 × 3.0     -> 上限 ×2.0

行业产出本来已经顶到上限（+1.38 / 1.40），不再放大。
"""
import json
import os
import sys

NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")

SECTOR_SCALE = 2.0
FAMILY_SCALE = 3.0
GEO_SCALE = 3.0
SECTOR_CAP = {
    "country.output.agriculture_factor": 3.00,
    "country.output.extractive_factor": 3.00,
    "country.output.manufacturing_factor": 3.00,
    "country.output.energy_factor": 2.00,
    "country.output.knowledge_factor": 2.00,
}
FAMILY_CAP = 2.60
GEO_CAP = 1.00


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    scaled_family = scaled_geo = scaled_sector = 0
    for node in data["nodes"]:
        for term in node.get("modifier_terms") or []:
            stat = str(term.get("stat", ""))
            value = float(term.get("value") or 0.0)
            if stat in SECTOR_CAP:
                term["value"] = round(value * SECTOR_SCALE, 3)
                scaled_sector += 1
            elif stat.startswith("country.output.family."):
                term["value"] = round(value * FAMILY_SCALE, 3)
                scaled_family += 1
            elif ".terrain." in stat or ".landform." in stat:
                term["value"] = round(value * GEO_SCALE, 3)
                scaled_geo += 1

    # 收敛回上限（按 stat 等比缩放）
    buckets = {}
    for node in data["nodes"]:
        for index, term in enumerate(node.get("modifier_terms") or []):
            stat = str(term.get("stat", ""))
            if stat in SECTOR_CAP:
                buckets.setdefault(stat, (SECTOR_CAP[stat], []))[1].append((node, index))
            elif stat.startswith("country.output.family."):
                buckets.setdefault(stat, (FAMILY_CAP, []))[1].append((node, index))
            elif ".terrain." in stat or ".landform." in stat:
                buckets.setdefault(stat, (GEO_CAP, []))[1].append((node, index))
    capped = 0
    for stat, (cap, entries) in buckets.items():
        total = sum(abs(float(node["modifier_terms"][index].get("value") or 0.0))
                    for node, index in entries)
        if total <= cap or total <= 0:
            continue
        ratio = cap / total
        for node, index in entries:
            value = float(node["modifier_terms"][index].get("value") or 0.0)
            node["modifier_terms"][index]["value"] = round(value * ratio, 3)
        capped += 1

    temporary = NETWORK + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, ensure_ascii=False, indent="\t")
        handle.write("\n")
    os.replace(temporary, NETWORK)
    print("scaled sector %d / family %d / geo %d ; capped keys %d"
          % (scaled_sector, scaled_family, scaled_geo, capped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
