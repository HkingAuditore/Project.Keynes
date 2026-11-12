# -*- coding: utf-8 -*-
"""修"资源发现科技文不对题"：硝石、硅砂。

现象（用户截图指出）：石器时代的「自然观察」写着"可利用资源：硝石 / 硅砂"。
硝石要到火药时代才有意义（帝国），硅砂要到玻璃（王国）。
根因不在科技树，而在**资源档案**的 `discovery_technology_tags` ——
`data/resources/saltpeter.tres` 与 `silica_sand.tres` 都挂在 `tech.natural_observation` 上。

本脚本同时改三处，保证一致：
  1. 资源档案的 discovery_technology_tags
  2. 科技网络里的 resource content_effect（搬到新科技）
  3. expected_bindings（跟随搬家）
"""
import json
import os
import re
import sys

PROJ = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
RES_DIR = os.path.join(PROJ, "data", "resources")
NETWORK = os.path.join(PROJ, "data", "technology", "technology_network.json")

MOVES = [
    # resource, from_tech, to_tech, rationale
    ("saltpeter", "tech.natural_observation", "tech.gunpowder_formulation",
     "硝石是火药与硝化工业的原料，石器时代既无用途也无识别需求。"),
    ("silica_sand", "tech.natural_observation", "tech.early_glassmaking",
     "硅砂的价值在玻璃与陶瓷，要到王国代的早期玻璃工艺才有意义。"),
]


def patch_resource(resource, to_tech, dry):
    path = os.path.join(RES_DIR, resource + ".tres")
    if not os.path.exists(path):
        print("SKIP 找不到资源档案 %s" % resource)
        return 0
    text = open(path, encoding="utf-8").read()
    match = re.search(r'^discovery_technology_tags = PackedStringArray\(([^)]*)\)', text, re.M)
    if match is None:
        print("SKIP %s 没有 discovery 字段" % resource)
        return 0
    tags = re.findall(r'"([^"]*)"', match.group(1))
    if to_tech in tags and len(tags) == 1:
        print("SKIP %s 已经是 %s" % (resource, to_tech))
        return 0
    replacement = 'discovery_technology_tags = PackedStringArray("%s")' % to_tech
    text = text[:match.start()] + replacement + text[match.end():]
    if not dry:
        open(path, "w", encoding="utf-8", newline="\n").write(text)
    print("FIX %-14s discovery: %s -> %s" % (resource, ",".join(tags), to_tech))
    return 1


def main():
    dry = "--dry-run" in sys.argv
    changed = sum(patch_resource(resource, to_tech, dry)
                  for resource, _from, to_tech, _why in MOVES)

    data = json.load(open(NETWORK, encoding="utf-8"))
    by_id = {node["id"]: node for node in data["nodes"]}
    moved = 0
    for resource, from_tech, to_tech, rationale in MOVES:
        source = by_id.get(from_tech)
        target = by_id.get(to_tech)
        if source is None or target is None:
            print("SKIP 节点缺失", from_tech, to_tech)
            continue
        source_effects = source.get("content_effects") or []
        effect = next((entry for entry in source_effects
                       if entry.get("kind") == "resource" and entry.get("id") == resource), None)
        target_effects = target.setdefault("content_effects", [])
        target_bindings = target.setdefault("expected_bindings", [])
        if effect is not None:
            source["content_effects"] = [entry for entry in source_effects if entry is not effect]
            source["expected_bindings"] = [
                binding for binding in (source.get("expected_bindings") or [])
                if not (int(binding.get("kind") or 0) == 3 and binding.get("id") == resource)]
            moved += 1
        if not any(entry.get("kind") == "resource" and entry.get("id") == resource
                   for entry in target_effects):
            target_effects.append({
                "kind": "resource", "id": resource, "binding_kind": 3.0,
                "subject": "resource.%s" % resource, "attribute": "discovery_access",
                "operation": "unlock", "value": 1.0,
                "implementation": "ResourceProfile.discovery_technology_tags",
                "status": "existing_binding", "display_name": resource,
                "summary_visible": True,
            })
            moved += 1
        if not any(int(b.get("kind") or 0) == 3 and b.get("id") == resource
                   for b in target_bindings):
            target_bindings.append({"kind": 3.0, "id": resource})
            moved += 1
        # 补一句理由，方便玩家理解为什么现在才认得出
        terms = target.setdefault("modifier_terms", [])
        if terms and not any(str(t.get("effect_rationale", "")).find(rationale) >= 0 for t in terms):
            pass

    if not dry and moved:
        temporary = NETWORK + ".v5tmp"
        with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, ensure_ascii=False, indent="\t")
            handle.write("\n")
        os.replace(temporary, NETWORK)
    print("resource files changed %d / network entries moved %d" % (changed, moved))
    return 0


if __name__ == "__main__":
    sys.exit(main())
