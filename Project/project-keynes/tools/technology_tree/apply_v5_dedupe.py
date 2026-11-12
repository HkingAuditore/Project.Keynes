# -*- coding: utf-8 -*-
"""v5 清理：重复解锁的物资条目。

评审指出 133 个"同一物资被多个科技重复解锁"的目标 —— 例如 `corn_grain` 被 10 个科技
分别列为"解锁物资"，而它真正只需要在最早那个节点解锁一次。重复项对运行时零贡献，
只污染效果列表与审计。

规则：
  * 同一种物资只保留**最早**（era_index, layout_order 最小）的那个 content_effect；
  * 同时删除该节点里对应的 `expected_bindings`（编译器要求双向匹配）；
  * 若删除会让某节点既无内容也无数值效果，则保留（不制造空节点）。
"""
from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NETWORK = os.path.join(ROOT, "data", "technology", "technology_network.json")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args()

    data = json.load(open(NETWORK, encoding="utf-8"))
    eras = [era["id"] for era in data["eras"]]
    era_index = {era_id: index for index, era_id in enumerate(eras)}

    # 1. 找出每种物资最早出现的节点
    earliest = {}
    for node in data["nodes"]:
        key = (era_index.get(node["era_id"], 99), float(node.get("layout_order") or 0.0))
        for effect in node.get("content_effects") or []:
            if effect.get("kind") != "good":
                continue
            good = str(effect.get("id", ""))
            if good not in earliest or key < earliest[good][0]:
                earliest[good] = (key, node["id"])

    # 2. 从非最早节点里删除重复的物资效果
    removed = 0
    kept_because_empty = 0
    per_node = {}
    for node in data["nodes"]:
        effects = node.get("content_effects") or []
        goods_here = [effect for effect in effects if effect.get("kind") == "good"]
        if not goods_here:
            continue
        removable = []
        for effect in goods_here:
            good = str(effect.get("id", ""))
            owner = earliest.get(good, (None, ""))[1]
            if owner != node["id"]:
                removable.append(effect)
        if not removable:
            continue
        other_content = [effect for effect in effects if effect.get("kind") != "good"]
        has_terms = bool(node.get("modifier_terms"))
        has_runtime = bool(node.get("runtime_capability_tags"))
        if not other_content and not has_terms and not has_runtime:
            kept_because_empty += len(removable)
            continue
        for effect in removable:
            effects.remove(effect)
            removed += 1
            bindings = node.get("expected_bindings") or []
            for binding in list(bindings):
                if int(binding.get("kind") or 0) == 1 and binding.get("id") == effect.get("id"):
                    bindings.remove(binding)
            node["expected_bindings"] = bindings
        per_node[node["id"]] = len(removable)

    print("重复物资效果删除：%d 条，涉及 %d 个节点" % (removed, len(per_node)))
    print("为避免空节点而保留：%d 条" % kept_because_empty)
    for node_id, count in sorted(per_node.items(), key=lambda kv: -kv[1])[:12]:
        print("  %-44s -%d" % (node_id, count))

    if arguments.dry_run:
        print("--- dry-run ---")
        return 0
    temporary = NETWORK + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, ensure_ascii=False, indent="\t")
        handle.write("\n")
    os.replace(temporary, NETWORK)
    print("--- written ---")
    return 0


if __name__ == "__main__":
    sys.exit(main())
