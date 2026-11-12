# -*- coding: utf-8 -*-
"""全面扫描"文不对题 / 解锁内容与时代不匹配"的四类问题。

A. 内容错代：科技 era 与它声明的 content_effect（建筑/物资/资源）自身的 era 相差 >= 2 代。
B. 效果错代：某个 stat（例如 country.research.*、country.military.*、某家族的产出）
   在别的节点里都是晚期才出现，这个节点却在早期就给。
C. 条件错代：reveal / route 里的信号原子（development.* / breakthrough.* / resource.* / bio.*）
   绝大多数出现在晚期，某个早期节点却拿它当条件 —— 那个条件在该时代几乎不可能满足。
D. 空泛指代：content_effect 的 kind/subject/display_name 缺字段或 id 对不上任何档案。
"""
import json
import os
import re
import io
import sys
import collections

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
PROJ = r"D:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes"
NETWORK = os.path.join(PROJ, "data", "technology", "technology_network.json")
BUILD_DIR = os.path.join(PROJ, "data", "economy", "buildings")
GOOD_DIR = os.path.join(PROJ, "data", "goods")
RES_DIR = os.path.join(PROJ, "data", "resources")


def parse(path):
    body = open(path, encoding="utf-8", errors="replace").read()
    return {m.group(1): m.group(2).strip()
            for m in re.finditer(r"^([a-z_0-9]+)\s*=\s*(.+)$", body, re.M)}


def arr(value):
    return re.findall(r'"([^"]*)"', value or "")


def collect_era(dir_path, keyword):
    """id -> era（取该档案 technology_tags 里第一个 tech.* 的时代）"""
    out = {}
    for name in os.listdir(dir_path):
        if not name.endswith(".tres"):
            continue
        data = parse(os.path.join(dir_path, name))
        identifier = (arr(data.get("id", "")) or [name[:-5]])[0].replace("&", "")
        tags = [t for t in arr(data.get("technology_tags", "")) if t.startswith("tech.")]
        if not tags:
            tags = [t for t in arr(data.get("discovery_technology_tags", ""))
                    if t.startswith("tech.")]
        out[identifier] = tags
    return out


def main():
    net = json.load(open(NETWORK, encoding="utf-8"))
    era_ids = [era["id"] for era in net["eras"]]
    era_of_tech = {node["id"]: era_ids.index(node["era_id"]) for node in net["nodes"]}

    building_tags = collect_era(BUILD_DIR, "building")
    good_tags = collect_era(GOOD_DIR, "good")
    resource_tags = collect_era(RES_DIR, "resource")

    def target_era(kind, identifier):
        pool = {"building": building_tags, "good": good_tags,
                "resource": resource_tags}.get(kind, {})
        tags = pool.get(identifier, [])
        eras = [era_of_tech[t] for t in tags if t in era_of_tech]
        return min(eras) if eras else None

    problems = collections.defaultdict(list)

    # ---- A 内容错代
    for node in net["nodes"]:
        node_era = era_ids.index(node["era_id"])
        for effect in node.get("content_effects") or []:
            kind = str(effect.get("kind", ""))
            identifier = str(effect.get("id", ""))
            target = target_era(kind, identifier)
            if target is None:
                continue
            if target - node_era >= 2:
                problems["A"].append((node["id"], node["era_id"], kind, identifier,
                                      era_ids[target], target - node_era))
            elif node_era - target >= 3:
                problems["A"].append((node["id"], node["era_id"], kind, identifier,
                                      era_ids[target], node_era - target))

    # ---- B 效果错代：某 stat 的"惯常时代"（中位数）远晚于本节点
    stat_eras = collections.defaultdict(list)
    for node in net["nodes"]:
        node_era = era_ids.index(node["era_id"])
        for term in node.get("modifier_terms") or []:
            stat_eras[str(term.get("stat", ""))].append(node_era)
    stat_typical = {}
    for stat, eras in stat_eras.items():
        if len(eras) < 3:
            continue
        ordered = sorted(eras)
        stat_typical[stat] = ordered[len(ordered) // 2]
    for node in net["nodes"]:
        node_era = era_ids.index(node["era_id"])
        for term in node.get("modifier_terms") or []:
            stat = str(term.get("stat", ""))
            typical = stat_typical.get(stat)
            if typical is None:
                continue
            if typical - node_era >= 3:
                problems["B"].append((node["id"], node["era_id"], stat,
                                      era_ids[typical], typical - node_era))

    # ---- C 条件错代：信号原子的时代分布
    atom_eras = collections.defaultdict(list)

    def walk(spec, node_era):
        for child in (spec or {}).get("children", []) if isinstance(spec, dict) else []:
            if not isinstance(child, dict):
                continue
            atom = str(child.get("id", ""))
            if atom and float(child.get("kind", 0.0)) == 1.0:
                atom_eras[atom].append(node_era)
            walk(child, node_era)

    for node in net["nodes"]:
        node_era = era_ids.index(node["era_id"])
        walk(node.get("reveal_condition") or {}, node_era)
        for route in node.get("research_routes") or []:
            walk(route.get("condition") or {}, node_era)

    for atom, eras in atom_eras.items():
        if len(eras) < 3:
            continue
        ordered = sorted(eras)
        typical = ordered[len(ordered) // 2]
        for era in eras:
            if typical - era >= 2:
                problems["C"].append((atom, era_ids[era], era_ids[typical], typical - era))

    # ---- D 效果字段完整性
    for node in net["nodes"]:
        for effect in node.get("content_effects") or []:
            for field in ("kind", "id", "subject", "attribute", "operation",
                          "implementation", "status"):
                if not str(effect.get(field, "")).strip():
                    problems["D"].append((node["id"], effect.get("id"), field))

    for key, title in (("A", "A 内容错代（科技时代 vs 解锁物时代）"),
                       ("B", "B 效果错代（该 stat 通常更晚出现）"),
                       ("C", "C 条件错代（信号原子通常更晚才有）"),
                       ("D", "D 效果字段缺失")):
        rows = problems[key]
        print("== %s：%d 条" % (title, len(rows)))
        for row in rows[:25]:
            print("   ", " | ".join(str(x) for x in row))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
