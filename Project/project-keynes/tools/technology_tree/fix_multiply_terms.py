# -*- coding: utf-8 -*-
"""修正两处语义/单位问题：

1. **乘算项（operation=2）必须写"系数"而不是"增量"。**
   `legion_logistics` / `military_cartography` / `military_medicine` / `combat_medicine`
   原本是 `op=2, value=0.85`，即"×0.85 = 少 15%"，语义是对的。
   上一批我把它们当成增量写成了 `-0.30`，在乘算下等于"× -0.3"（负值），是**我引入的 bug**。
   现在统一改成系数 0.70（少 30%）。

2. **bp 类统计（满意度基准点）显示要除以 100。**
   `satisfaction_bp = 200` 是 200 个基准点 = 2%，但摘要按"值×100%"渲染成了 +20000%。
"""
import json
import os
import sys

NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")

FACTORS = [
    ("tech.military.legion_logistics", "country.military.supply_consumption_factor", 0.70),
    ("tech.military.military_cartography", "country.military.attrition_factor", 0.70),
    ("tech.military.military_medicine", "country.military.casualty_factor", 0.70),
    ("tech.military.combat_medicine", "country.military.casualty_factor", 0.70),
]


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    changed = 0
    for node_id, stat, factor in FACTORS:
        node = by_id.get(node_id)
        if node is None:
            print("SKIP", node_id)
            continue
        for term in node.get("modifier_terms") or []:
            if term.get("stat") != stat:
                continue
            if int(term.get("operation", 0)) != 2:
                # 只有乘算项需要系数；若被改成加减法说明数据已经跑偏
                term["operation"] = 2.0
            if abs(float(term.get("value") or 0.0) - factor) < 1e-6:
                continue
            print("FIX %-34s %-42s %.3f -> %.3f (op=2 系数)"
                  % (node_id, stat[-42:], float(term.get("value") or 0.0), factor))
            term["value"] = factor
            changed += 1

    # 把误写成增量的加减法项（op=0）也一并纠回乘算系数
    for node in data["nodes"]:
        for term in node.get("modifier_terms") or []:
            if term.get("stat") in (t[1] for t in FACTORS) and int(term.get("operation", 0)) == 0:
                if float(term.get("value") or 0.0) < 0:
                    print("FIX operation 归位 %-30s %s" % (node["id"], term["stat"][-40:]))
                    term["operation"] = 2.0
                    term["value"] = 1.0 + float(term.get("value") or 0.0)
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
