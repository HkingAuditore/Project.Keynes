# -*- coding: utf-8 -*-
"""把每个节点的 expected_bindings 与 content_effects 强制对齐（双向）。

流水线里有多个脚本各自往 content_effects 加条目，顺序稍变就会遗漏
expected_binding，编译器随即报 `technology_content_effect_invalid`。
与其逐个脚本打补丁，不如在最后统一按效果重算一遍绑定表。
"""
import json
import os
import sys

NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")

data = json.load(open(NETWORK, encoding="utf-8"))
fixed_add = 0
fixed_drop = 0
for node in data["nodes"]:
    effects = node.get("content_effects") or []
    wanted = []
    for effect in effects:
        kind = int(effect.get("binding_kind", 0))
        if kind <= 0:
            continue
        wanted.append((kind, str(effect.get("id", ""))))
    bindings = node.get("expected_bindings") or []
    current = [(int(b.get("kind") or 0), str(b.get("id") or "")) for b in bindings]
    if sorted(wanted) == sorted(current):
        continue
    seen = set()
    rebuilt = []
    for kind, identifier in wanted:
        if (kind, identifier) in seen:
            continue
        seen.add((kind, identifier))
        rebuilt.append({"kind": float(kind), "id": identifier})
    fixed_add += len(set(wanted) - set(current))
    fixed_drop += len(set(current) - set(wanted))
    node["expected_bindings"] = rebuilt

print("expected_bindings 补齐 %d 条 / 删除多余 %d 条" % (fixed_add, fixed_drop))
temporary = NETWORK + ".v5tmp"
with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
    json.dump(data, handle, ensure_ascii=False, indent="\t")
    handle.write("\n")
os.replace(temporary, NETWORK)
print("--- written ---")
