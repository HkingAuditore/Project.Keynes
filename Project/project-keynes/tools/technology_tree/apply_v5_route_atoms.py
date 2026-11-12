# -*- coding: utf-8 -*-
"""路线原子清洗：把与硬前置重复的路线证据换成安全替代。

`technology_route_duplicates_core_prerequisite` 是编译期硬错误：
只要某个节点的路线条件里出现了它自己的硬前置，整棵树都编不过。

每当给一个节点补了新的硬前置，它的旧路线就有可能撞车（本次是
`tech.public_health_systems` 的 `industrial_chemistry`）。
本脚本按统一规则处理，避免每次都靠一次性脚本打补丁：

  1. 若节点有替代组（alternative_groups），优先用组里第一个非硬前置原子；
  2. 否则用 `tech.electrochemistry`（若它早于本节点）；
  3. 都不行就删掉该原子（条件是纯发展信号时仍然合法）。
"""
import json
import os
import sys

NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")
FALLBACK = "tech.electrochemistry"


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    row = {node["id"]: index for index, node in enumerate(data["nodes"])}
    changed = 0
    for index, node in enumerate(data["nodes"]):
        hard = set(node.get("hard_prerequisite_ids") or [])
        if not hard:
            continue
        groups = (node.get("knowledge_basis") or {}).get("alternative_groups") or []
        pool = [atom for group in groups for atom in group
                if atom not in hard and atom in row and row[atom] < index]
        replacement = pool[0] if pool else (
            FALLBACK if FALLBACK in row and row[FALLBACK] < index else "")
        for route in node.get("research_routes") or []:
            condition = route.get("condition") or {}
            children = condition.get("children")
            if not isinstance(children, list):
                continue
            kept = []
            for child in children:
                if not isinstance(child, dict):
                    kept.append(child)
                    continue
                atom = str(child.get("id", ""))
                is_tech = float(child.get("kind", 0.0)) == 0.0 and atom.startswith("tech.")
                if is_tech and atom in hard:
                    if replacement:
                        child["id"] = replacement
                        changed += 1
                    else:
                        changed += 1
                        continue
                kept.append(child)
            if len(kept) != len(children):
                condition["children"] = kept
        # alternative_groups 里也不该出现硬前置
        for group in groups:
            for position, atom in enumerate(group):
                if atom in hard and replacement:
                    group[position] = replacement
                    changed += 1
    if changed:
        temporary = NETWORK + ".v5tmp"
        with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, ensure_ascii=False, indent="\t")
            handle.write("\n")
        os.replace(temporary, NETWORK)
    print("route atoms sanitized: %d" % changed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
