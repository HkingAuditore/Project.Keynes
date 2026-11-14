# -*- coding: utf-8 -*-
"""给"只有产出百分比"的节点补一条具体通道。

普查（audit_choice_coverage.py）显示 25 个节点（5.8%）只给行业/家族 +%，
玩家研究完只看到数字变化，没有任何新的造法/产法/放法。本脚本按领域给它们
补一条**具体通道**（不删原有效果，只叠加），使其进入"给了新选择"的集合。

选择依据：
  agriculture → 投入因子（更好农艺 = 更少损耗）
  engineering → 营造成本（更好的工程 = 更省的建造）
  knowledge   → 科研机构产出（更好的知识组织 = 更强研究）
  society     → 贸易容量（更好的制度 = 更大的市场）
"""
from __future__ import annotations

import argparse
import json
import os
import sys

NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")

DEFAULT_BY_DOMAIN = {
    "agriculture": ("country.production.input_factor", -0.03, "投入因子",
                    "更精细的农艺让同样的投入产出更多，损耗下降。"),
    "engineering": ("country.construction.cost_factor", -0.03, "建造成本",
                    "更成熟的工程做法让同样的建筑花更少的料。"),
    "knowledge": ("country.research.institution_output_factor", 0.05, "科研机构产出",
                  "知识组织的改进让同样的机构产出更多成果。"),
    "society": ("country.trade.capacity_factor", 0.04, "贸易容量",
                "更有效的制度安排扩大了可承载的市场规模。"),
    "science": ("country.resource.use_factor", -0.03, "资源利用",
                "识别与观察让采收更有针对性，同样矿脉能取出更多可用料。"),
}

OVERRIDES = {
    "tech.land_reform": ("country.tax.income.landlord.rate_bp", 200.0, "地主",
                         "土地清丈让地租税基可核定，征收效率提高。"),
    "tech.servomechanism": ("country.research.engineering_efficiency", 0.06, "工程研究效率",
                            "伺服控制把实验装置自动化，工程研究更快。"),
    "tech.robotic_control": ("country.research.engineering_efficiency", 0.08, "工程研究效率",
                             "机器人控制让工程试验可并行、可复现。"),
    "tech.prefabricated_construction": ("country.construction.time_factor", -0.06, "建造工期",
                                        "构件在工厂预制，现场只装配，工期显著缩短。"),
    "tech.forest_products_industry": ("country.production.input_factor", -0.05, "投入因子",
                                      "林产工业把边角料变成纸浆与板材，原料利用率上升。"),
    "tech.polymer_composites": ("country.production.input_factor", -0.04, "投入因子",
                                "复合材料按需增强，同等强度用的料更少。"),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()
    data = json.load(open(NETWORK, encoding="utf-8"))
    changed = 0
    for node in data["nodes"]:
        terms = node.get("modifier_terms") or []
        if not terms:
            continue
        # 已经有建筑/物资/资源/运行时能力解锁的节点，本身就给了新选择，不再叠加。
        if node.get("content_effects") or node.get("runtime_capability_tags"):
            continue
        # 里程碑固定 2-3 条 buff，不再叠加通道
        if node.get("is_milestone"):
            continue
        has_specific = False
        for term in terms:
            stat = str(term.get("stat", ""))
            if not stat.startswith(("country.output.agriculture_factor",
                                    "country.output.extractive_factor",
                                    "country.output.manufacturing_factor",
                                    "country.output.energy_factor",
                                    "country.output.knowledge_factor",
                                    "country.output.family.",
                                    "country.economy_output_factor")):
                has_specific = True
                break
        if has_specific:
            continue
        override = OVERRIDES.get(node["id"])
        if override is not None:
            stat, value, label, rationale = override
        else:
            fallback = DEFAULT_BY_DOMAIN.get(String(node.get("domain_id", ""))
                                             if False else str(node.get("domain_id", "")))
            if fallback is None:
                continue
            stat, value, label, rationale = fallback
        if any(term.get("stat") == stat for term in terms):
            continue
        if stat.startswith("country.tax."):
            new_term = {
                "stat": stat, "operation": 0.0, "value": value,
                "subject_kind": "profession", "subject_id": stat.split(".")[2],
                "subject_display_name": label, "effect_class": "税制",
                "effect_rationale": rationale,
                "implementation_status": "runtime_consumed",
                "runtime_consumer": "NativeCountryRuntime tax policy snapshot",
            }
        else:
            new_term = {
                "stat": stat, "operation": 0.0, "value": value,
                "subject_kind": "country", "subject_id": "",
                "subject_display_name": label, "effect_class": "制度与效率",
                "effect_rationale": rationale,
                "implementation_status": "runtime_consumed",
                "runtime_consumer": "NativeCountryRuntime modifier snapshot",
            }
        terms.append(new_term)
        changed += 1
        print("补通道 %-42s → %s %+.3f" % (node["id"], stat, value))
    print("--- 共 %d 个节点 ---" % changed)
    if arguments.dry_run:
        return 0
    temporary = NETWORK + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, ensure_ascii=False, indent="\t")
        handle.write("\n")
    os.replace(temporary, NETWORK)
    print("written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
