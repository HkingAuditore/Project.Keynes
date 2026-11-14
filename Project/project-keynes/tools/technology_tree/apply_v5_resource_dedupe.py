# -*- coding: utf-8 -*-
"""把"重复解锁的自然资源"收敛到最早的那个节点（与物资去重同一逻辑）。

之前的 `apply_v5_dedupe.py` 只处理了 `kind == "good"`，资源没管，
于是同一个资源会在好几个科技面板上重复出现 ——
`industrial_chemistry`（蒸汽）还写着"可利用资源：硫磺"，而硫磺在帝国就认得了。

规则与物资一致：同一资源只保留最早（era, layout_order 最小）的那个 content_effect，
并同步删除对应节点的 expected_bindings。
"""
import json
import os
import sys

NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    era_ids = [era["id"] for era in data["eras"]]
    era_index = {era: index for index, era in enumerate(era_ids)}

    earliest = {}
    for index, node in enumerate(data["nodes"]):
        key = (era_index.get(node["era_id"], 99), float(node.get("layout_order") or 0.0), index)
        for effect in node.get("content_effects") or []:
            if effect.get("kind") != "resource":
                continue
            resource = str(effect.get("id", ""))
            if resource not in earliest or key < earliest[resource][0]:
                earliest[resource] = (key, node["id"])

    removed = 0
    kept_because_empty = 0
    per_node = {}
    for node in data["nodes"]:
        effects = node.get("content_effects") or []
        resources = [effect for effect in effects if effect.get("kind") == "resource"]
        if not resources:
            continue
        removable = []
        for effect in resources:
            owner = earliest.get(str(effect.get("id", "")), (None, ""))[1]
            if owner != node["id"]:
                removable.append(effect)
        if not removable:
            continue
        other = [effect for effect in effects if effect.get("kind") != "resource"]
        if not other and not node.get("modifier_terms") and not node.get("runtime_capability_tags"):
            kept_because_empty += len(removable)
            continue
        for effect in removable:
            effects.remove(effect)
            removed += 1
            bindings = node.get("expected_bindings") or []
            for binding in list(bindings):
                if int(binding.get("kind") or 0) == 3 and binding.get("id") == effect.get("id"):
                    bindings.remove(binding)
            node["expected_bindings"] = bindings
        per_node[node["id"]] = len(removable)

    print("重复资源效果删除：%d 条，涉及 %d 个节点（为避免空节点保留 %d 条）"
          % (removed, len(per_node), kept_because_empty))
    for node_id, count in sorted(per_node.items(), key=lambda kv: -kv[1])[:12]:
        print("  %-44s -%d" % (node_id, count))
    if removed:
        temporary = NETWORK + ".v5tmp"
        with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, ensure_ascii=False, indent="\t")
            handle.write("\n")
        os.replace(temporary, NETWORK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
