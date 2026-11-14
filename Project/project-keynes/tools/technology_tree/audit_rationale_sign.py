# -*- coding: utf-8 -*-
"""按"效果描述文字"反查符号：描述说减少、数值却是正；描述说提高、数值却是负。

这是对"文不对题"最直接的一类机器检查 ——
`effect_rationale` 是玩家可能看到的解释，如果它和数值方向相反，就是硬伤。
"""
import re
import io
import sys
import json

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")

UP_WORDS = ("提高", "提升", "增加", "增强", "扩大", "加快", "上升", "更多", "加倍")
DOWN_WORDS = ("减少", "降低", "下降", "减弱", "缩小", "放慢", "更少", "节省")
# 这些 stat 本身是"越低越好"，方向要反过来理解
NEGATIVE_GOOD = ("loss", "death", "cost", "consumption", "attrition", "desertion",
                 "input_factor", "use_factor", "time_factor")


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    era_ids = [era["id"] for era in data["eras"]]
    findings = []
    for node in data["nodes"]:
        for term in node.get("modifier_terms") or []:
            stat = str(term.get("stat", ""))
            value = float(term.get("value") or 0.0)
            text = str(term.get("effect_rationale", ""))
            if not text or value == 0.0:
                continue
            says_up = any(word in text for word in UP_WORDS)
            says_down = any(word in text for word in DOWN_WORDS)
            if says_up == says_down:
                continue
            # 只按字面方向判断：文字说"提高/增加" -> 数值应为正；
            # 说"降低/减少" -> 数值应为负。若描述谈的是另一个量（例如
            # "降低交易成本" 却写在 trade.capacity 上），这里会误报 —— 属已知局限。
            if says_up and value < 0:
                findings.append((node["id"], node["era_id"], stat, value, text[:34], "说提高但为负"))
            elif says_down and value > 0:
                findings.append((node["id"], node["era_id"], stat, value, text[:34], "说降低但为正"))

    print("描述与符号相反：%d 条" % len(findings))
    for node_id, era, stat, value, text, why in findings:
        print("  %-36s %-12s %-44s %+0.3f  [%s] %s" % (
            node_id, era, stat[-44:], value, why, text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
