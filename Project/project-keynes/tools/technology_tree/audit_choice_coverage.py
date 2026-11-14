# -*- coding: utf-8 -*-
"""科技"给不给玩家新选择"普查。

对每个节点判定它提供了下列哪些**具体抓手**（而不是笼统的 +%）：
  建筑 / 物资 / 自然资源 / 运行时能力 / 地理条件 / 军事条令 / 职业满意度
  税率 / 营造 / 科研成本或机构产出 / 气候档案

只给「行业或家族产出百分比」的节点记为 **GREEDY**（只有数值、没有新选择）。
输出统计与最差的若干节点，供后续补通道或合并。
"""
import collections
import io
import json
import os
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
PROJ = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
NETWORK = os.path.join(PROJ, "data", "technology", "technology_network.json")

CHANNELS = [
    ("building", lambda stat: False),
]

GEO_MARKERS = (".terrain.", ".landform.")
PERCENT_ONLY_PREFIXES = (
    "country.output.agriculture_factor",
    "country.output.extractive_factor",
    "country.output.manufacturing_factor",
    "country.output.energy_factor",
    "country.output.knowledge_factor",
    "country.output.family.",
    "country.economy_output_factor",
)


def classify(node):
    tags = set()
    for effect in node.get("content_effects") or []:
        kind = str(effect.get("kind", ""))
        if kind:
            tags.add(kind)
    for capability in node.get("runtime_capability_tags") or []:
        tags.add("runtime")
    for term in node.get("modifier_terms") or []:
        stat = str(term.get("stat", ""))
        if any(marker in stat for marker in GEO_MARKERS):
            tags.add("geography")
        elif stat.startswith("country.military.rule."):
            tags.add("military_rule")
        elif stat.startswith("economy.profession."):
            tags.add("profession")
        elif stat.startswith("country.tax."):
            tags.add("tax")
        elif stat.startswith("country.construction."):
            tags.add("construction")
        elif stat.startswith("country.research.cost") or stat.startswith(
                "country.research.institution"):
            tags.add("research_cost")
        elif stat.startswith("country.climate.profile."):
            tags.add("climate_profile")
        elif stat.startswith("country.climate."):
            tags.add("climate")
        elif stat.startswith("country.resource."):
            tags.add("resource_use")
        elif stat.startswith("country.trade."):
            tags.add("trade")
        elif stat.startswith("country.production.input"):
            tags.add("input")
    return tags


def is_percent_only(tags, node):
    if tags:
        return False
    for term in node.get("modifier_terms") or []:
        stat = str(term.get("stat", ""))
        if not stat.startswith(PERCENT_ONLY_PREFIXES):
            return False
    return True


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    eras = [era["id"] for era in data["eras"]]
    coverage = collections.Counter()
    per_era_greedy = collections.Counter()
    greedy = []
    for node in data["nodes"]:
        tags = classify(node)
        for tag in tags:
            coverage[tag] += 1
        if is_percent_only(tags, node):
            per_era_greedy[node["era_id"]] += 1
            greedy.append((node["era_id"], node["id"], node.get("display_name", ""),
                           round(max(abs(float(t.get("value") or 0.0))
                                     for t in node.get("modifier_terms") or []), 3)))
    total = len(data["nodes"])
    print("节点总数: %d" % total)
    print("\n各通道覆盖节点数：")
    for tag, count in coverage.most_common():
        print("  %-18s %3d" % (tag, count))
    print("\n只有产出百分比的节点（GREEDY）：%d 个（%.1f%%）" % (
        len(greedy), 100.0 * len(greedy) / total))
    for era in eras:
        if per_era_greedy[era]:
            print("  %-14s %d" % (era, per_era_greedy[era]))
    print("\n最靠后的 12 个：")
    for era, node_id, name, peak in greedy[-12:]:
        print("  %-14s %-42s %-14s peak=%.3f" % (era, node_id, name, peak))
    return 0


if __name__ == "__main__":
    sys.exit(main())
