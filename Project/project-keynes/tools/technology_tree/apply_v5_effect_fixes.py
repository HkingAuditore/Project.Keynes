# -*- coding: utf-8 -*-
"""修正三处"效果与描述相反 / 只有惩罚"的问题（来自 audit_effect_sanity 扫描）。

1. `tech.military.legion_logistics`（军需体系）
   描述写"用标准化配额减少浪费"，数值却是 supply_consumption_factor **+0.85**（增加消耗）。
   → 改为 -0.30。

2. `tech.military.military_cartography`（军事测绘）
   描述写"让部队避开难以通行的地带"，数值却是 attrition_factor **+0.70**（增加损耗）。
   → 改为 -0.30。

3. `tech.controlled_burning`（控制性用火）
   只有一条"短期损失木本存量"的负效果，等于一个纯惩罚科技。
   → 保留 -0.08 timber managed_generation，另加 +0.20 狩猎家族产出（烧荒肥草、聚兽）。
"""
import json
import os
import sys

NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")

FLIPS = [
    ("tech.military.legion_logistics", "country.military.supply_consumption_factor", -0.30,
     "军需体系用标准化配额减少浪费，同等兵力吃更少的补给。"),
    ("tech.military.military_cartography", "country.military.attrition_factor", -0.30,
     "军事测绘让部队避开难以通行的地带，行军损耗下降。"),
    # 这两条原文写"减少战伤死亡 / 提高救治率"，数值却是 casualty_factor +0.85
    # （= 伤亡 +85%），方向反了。
    ("tech.military.military_medicine", "country.military.casualty_factor", -0.30,
     "军医制度减少战伤死亡与疾病减员。"),
    ("tech.military.combat_medicine", "country.military.casualty_factor", -0.30,
     "战地医疗体系缩短后送并提高救治率。"),
]

ADDITIONS = [
    ("tech.controlled_burning", "country.output.family.hunting_factor", 0.20,
     "hunting", "狩猎", "烧荒更新草场，食草动物回流，狩猎产出提高。"),
    # 「自然观察」原本把硝石/硅砂当"可利用资源"，修掉之后只剩一条 +8% 研究效率，
    # 作为石器时代的观察类节点太单薄。补一条它真正该有的产出：认得出可食植物。
    ("tech.natural_observation", "country.output.good.gathered_plants_factor", 0.15,
     "gathered_plants", "采集植物", "会观察季相与生境的人，能采到更多可食植物。"),
]


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    changed = 0
    for node_id, stat, value, rationale in FLIPS:
        node = by_id.get(node_id)
        if node is None:
            print("SKIP", node_id)
            continue
        for term in node.get("modifier_terms") or []:
            if term.get("stat") != stat:
                continue
            if float(term.get("value") or 0.0) == value:
                continue
            print("FIX %-38s %-46s %+0.2f -> %+0.2f" % (
                node_id, stat[-46:], float(term.get("value") or 0.0), value))
            term["value"] = value
            term["effect_rationale"] = rationale
            changed += 1

    for node_id, stat, value, subject, label, rationale in ADDITIONS:
        node = by_id.get(node_id)
        if node is None:
            print("SKIP", node_id)
            continue
        terms = node.setdefault("modifier_terms", [])
        if any(term.get("stat") == stat for term in terms):
            continue
        terms.append({
            "stat": stat, "operation": 0.0, "value": value,
            "subject_kind": "family", "subject_id": subject,
            "subject_display_name": label, "effect_class": "产业产出",
            "effect_rationale": rationale,
            "implementation_status": "runtime_consumed",
            "runtime_consumer": "NativeCountryRuntime modifier snapshot",
        })
        print("ADD %-38s %-46s %+0.2f" % (node_id, stat[-46:], value))
        changed += 1

    temporary = NETWORK + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, ensure_ascii=False, indent="\t")
        handle.write("\n")
    os.replace(temporary, NETWORK)
    print("changed:", changed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
