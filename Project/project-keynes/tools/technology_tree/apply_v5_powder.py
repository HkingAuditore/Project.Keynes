# -*- coding: utf-8 -*-
"""让 `tech.military.powder_milling` 在网络里登记「火药工场」。

`steam_powder_works` 的主科技已改为 `military.powder_milling`（建筑侧），
这里把网络侧的内容效果与 expected_bindings 补齐，保证"建筑标签 ↔ 科技内容"一致。
幂等：已存在则跳过。
"""
from __future__ import annotations

import json
import os
import sys

NETWORK = (r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
           r"\data\technology\technology_network.json")
TECH = "tech.military.powder_milling"
BUILDING = "steam_powder_works"
NAME = "火药工场"


def main():
    data = json.load(open(NETWORK, encoding="utf-8"))
    node = next((entry for entry in data["nodes"] if entry["id"] == TECH), None)
    if node is None:
        print("SKIP 找不到 %s" % TECH)
        return 0
    effects = node.setdefault("content_effects", [])
    bindings = node.setdefault("expected_bindings", [])
    changed = 0
    if not any(effect.get("kind") == "building" and effect.get("id") == BUILDING
               for effect in effects):
        effects.append({
            "kind": "building", "id": BUILDING, "binding_kind": 2.0,
            "subject": "building.%s" % BUILDING,
            "attribute": "construction_and_production_access",
            "operation": "unlock", "value": 1.0,
            "implementation": "BuildingProfile.technology_tags",
            "status": "existing_binding", "display_name": NAME,
        })
        changed += 1
    if not any(int(b.get("kind") or 0) == 2 and b.get("id") == BUILDING for b in bindings):
        bindings.append({"kind": 2.0, "id": BUILDING})
        changed += 1
    if changed == 0:
        print("SKIP 已登记")
        return 0
    temporary = NETWORK + ".v5tmp"
    with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, ensure_ascii=False, indent="\t")
        handle.write("\n")
    os.replace(temporary, NETWORK)
    print("FIX %s 绑定 %s（%d 处）" % (TECH, BUILDING, changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
