# -*- coding: utf-8 -*-
"""扫描"符号/量级明显不对"的科技效果。

三类启发式：
  A. 负值出现在"正向"统计上（产出、效率、再生），或正值出现在"负向"统计上
     （成本、损失、死亡、投入）—— 通常是符号写反。
  B. 石器/农耕代节点给出 >= +15% 的家族产出 —— 早期就给终局级加成，量级可疑。
  C. 识别类节点（*_identification）给出 >= +20% 的产出类加成 —— 只是"认得出来"，
     不该直接给这么大的产出。
"""
import sys
import json
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")

NEGATIVE_STATS = ("loss", "death", "cost", "input_factor", "consumption", "attrition")
POSITIVE_STATS = ("_factor", "efficiency", "output", "capacity", "speed", "generation",
                  "recovery", "morale", "satisfaction")


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    era_ids = [era["id"] for era in data["eras"]]
    issues = {"A": [], "B": [], "C": []}
    for node in data["nodes"]:
        era = node["era_id"]
        for term in node.get("modifier_terms") or []:
            stat = str(term.get("stat", ""))
            value = float(term.get("value") or 0.0)
            negative_stat = any(key in stat for key in NEGATIVE_STATS)
            positive_stat = any(key in stat for key in POSITIVE_STATS)
            if negative_stat and value > 0:
                issues["A"].append((node["id"], era, stat, value, "负向统计为正"))
            elif positive_stat and value < 0 and not negative_stat:
                issues["A"].append((node["id"], era, stat, value, "正向统计为负"))
            if era in ("stone", "agrarian") and stat.startswith("country.output.family.") \
                    and abs(value) >= 0.15:
                issues["B"].append((node["id"], era, stat, value, "早期家族加成过大"))
        if node["id"].endswith("_identification"):
            for term in node.get("modifier_terms") or []:
                stat = str(term.get("stat", ""))
                value = float(term.get("value") or 0.0)
                if stat.startswith("country.output.") and not stat.startswith(
                        "country.output.good.") and value >= 0.20:
                    issues["C"].append((node["id"], era, stat, value, "识别类给产出加成过大"))

    for key, title in (("A", "符号可疑"), ("B", "早期家族加成过大"), ("C", "识别类产出加成过大")):
        rows = issues[key]
        print("== %s：%d 条" % (title, len(rows)))
        for node_id, era, stat, value, why in rows[:30]:
            print("   %-38s %-12s %-46s %+0.3f" % (node_id, era, stat[-46:], value))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
