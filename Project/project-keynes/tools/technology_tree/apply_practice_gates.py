#!/usr/bin/env python3
"""给科技树批量补「实践经验」门槛。

设计口径（与 2026-11-16 手工补的作物路线一致）：
- 发现靠观察（reveal_condition 只说"你见过什么"）；
- 研究靠经验（research_routes 里必须有一条 development.* 实践信号）。

本脚本处理的是**非作物**的产业分支：把同族货物合并成一条经验信号（一族一条，
避免每个建筑一条 definition 把 trigger state 预算吃光），再把该信号 AND 进
该节点已有的每一条研究路线——路线之间是 OR，逐条 AND 等价于「所有路径都要经验」。

只处理「解锁的建筑全部落在同一货物族」的节点：解锁 5 个不同行业建筑的泛制度
科技（行业组织、工厂制）不该被绑到单一产业上，跳过。

用法：
  python tools/technology_tree/apply_practice_gates.py --dry-run
  python tools/technology_tree/apply_practice_gates.py --apply
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

NETWORK = "data/technology/technology_network.json"
BUILDING_DIR = "data/economy/buildings"

# 族 -> (经验信号 id, 显示名, 阈值, 说明)。阈值 = 该族 step1 建筑里产出最低那个
# 的 50%（单位是内部千分位，UI 除以 1000 显示）。
FAMILIES = {
    "stone_clay": dict(
        signal="development.stone_clay_practice_1300_180d",
        name="石料与黏土采制实践",
        threshold=1300,
        goods=["raw_stone", "clay"],
    ),
    "ore_metal": dict(
        signal="development.ore_metal_practice_542_180d",
        name="矿石与金属冶炼实践",
        threshold=542,
        goods=["wrought_iron", "copper", "tin_ore", "iron_ore", "lead_ore"],
    ),
    "timber": dict(
        signal="development.timber_practice_541_180d",
        name="木料采制实践",
        threshold=541,
        goods=["logs", "lumber"],
    ),
    "salt": dict(
        signal="development.salt_practice_625_180d",
        name="制盐实践",
        threshold=625,
        goods=["salt"],
    ),
    "livestock": dict(
        signal="development.livestock_practice_812_180d",
        name="畜牧与屠宰实践",
        threshold=812,
        goods=["game_meat", "livestock_products", "meat", "wool", "leather",
               "dairy_products"],
    ),
    "textile": dict(
        signal="development.textile_practice_406_180d",
        name="纺织成衣实践",
        threshold=406,
        goods=["cloth", "clothing"],
    ),
    "ceramic_glass": dict(
        signal="development.ceramic_glass_practice_1772_180d",
        name="陶器与玻璃烧制实践",
        threshold=1772,
        goods=["pottery", "glass"],
    ),
    "fuel": dict(
        signal="development.fuel_practice_1083_180d",
        name="燃料烧制与采掘实践",
        threshold=1083,
        goods=["charcoal", "coal", "coke"],
    ),
    # 作物族沿用 2026-11-16 手工补的那六条，阈值口径见
    # development_achievement_catalog.gd 的注释（棉花刻意取 700）。
    "grain": dict(
        signal="development.grain_practice_800_180d",
        name="谷物经营实践",
        threshold=800,
        goods=["wheat_grain", "corn_grain", "potatoes"],
    ),
    "rice": dict(
        signal="development.rice_practice_800_180d",
        name="稻作经营实践",
        threshold=800,
        goods=["rice_grain"],
    ),
    "cotton": dict(
        signal="development.cotton_practice_700_180d",
        name="棉田实践",
        threshold=700,
        goods=["seed_cotton", "cotton_fiber"],
    ),
    "fiber": dict(
        signal="development.fiber_practice_1800_180d",
        name="纤维作物收制实践",
        threshold=1800,
        goods=["flax_fiber", "bast_fiber"],
    ),
    "spice": dict(
        signal="development.spice_practice_180_180d",
        name="香料园实践",
        threshold=180,
        goods=["spices"],
    ),
    "latex": dict(
        signal="development.latex_practice_2900_180d",
        name="树液采割实践",
        threshold=2900,
        goods=["latex"],
    ),
}

# 军事科技文案承诺了观察证据，条件却是空。这里按文案补真实信号。
MILITARY_REVEALS = {
    "tech.military.war_bands": {
        "operator": 2.0,
        "children": [
            {"kind": 1.0, "id": "resource.wild_game", "value": 1.0},
            {"kind": 1.0, "id": "bio.horse", "value": 1.0},
            {"kind": 1.0, "id": "bio.cattle", "value": 1.0},
        ],
    },
    "tech.military.ambush_tactics": {
        "operator": 2.0,
        "children": [
            {"kind": 1.0, "id": "landform.marsh", "value": 1.0},
            {"kind": 1.0, "id": "landform.forest", "value": 1.0},
            {"kind": 1.0, "id": "landform.conifer_forest", "value": 1.0},
        ],
    },
    "tech.military.chariot_warfare": {
        "operator": 1.0,
        "children": [
            {"kind": 1.0, "id": "bio.horse", "value": 1.0},
            {"operator": 2.0, "children": [
                {"kind": 1.0, "id": "landform.steppe_plain", "value": 1.0},
                {"kind": 1.0, "id": "landform.grassland", "value": 1.0},
            ]},
        ],
    },
    "tech.military.mounted_warfare": {
        "operator": 1.0,
        "children": [
            {"kind": 1.0, "id": "bio.horse", "value": 1.0},
            {"operator": 2.0, "children": [
                {"kind": 1.0, "id": "resource.pasture", "value": 1.0},
                {"kind": 1.0, "id": "landform.steppe_plain", "value": 1.0},
            ]},
        ],
    },
    "tech.military.heavy_cavalry": {
        "operator": 1.0,
        "children": [
            {"kind": 1.0, "id": "bio.horse", "value": 1.0},
            {"kind": 1.0, "id": "resource.pasture", "value": 1.0},
        ],
    },
}


# 覆盖族别：默认按解锁建筑的货物族判定，但有两处必须人工指定，否则会写出
# 自锁门槛（门槛要求的货物只有该科技自己解锁的建筑能产）。
FAMILY_OVERRIDES = {
    # 木炭只有 charcoal_pit 能产，而 charcoal_pit 正是本条科技解锁的 →
    # 改挂「木材实践」：先有稳定的木料采制，才谈得上建窑烧炭。
    "tech.charcoal_burning": "timber",
    # 自然铜只有 natural_copper_workshop 能产，而那座作坊由本条科技解锁 →
    # 任何 ore_metal 门槛都是循环，直接跳过（保持无门槛）。
    "tech.natural_copper_working": None,
}


def parse_building(path: str) -> dict:
    text = open(path, encoding="utf-8").read()

    def scalar(key: str) -> str:
        match = re.search(rf"^{key} = (.*)$", text, re.M)
        return match.group(1).strip() if match else ""

    def strings(key: str) -> list[str]:
        match = re.search(rf"^{key} = PackedStringArray\((.*)\)$", text, re.M)
        return re.findall(r'"([^"]*)"', match.group(1)) if match else []

    return {
        "id": scalar("id").strip('&"'),
        "goods": strings("output_good_ids"),
        "step": int(scalar("progression_step") or 0),
    }


def load_buildings() -> dict[str, dict]:
    out = {}
    for name in sorted(os.listdir(BUILDING_DIR)):
        if not name.endswith(".tres"):
            continue
        building = parse_building(os.path.join(BUILDING_DIR, name))
        if building["id"]:
            out[building["id"]] = building
    return out


def family_of(building_ids: list[str], buildings: dict[str, dict]) -> str | None:
    """所有解锁建筑共有的货物族；任一建筑不属于该族就返回 None。"""
    common: set[str] | None = None
    for building_id in building_ids:
        building = buildings.get(building_id)
        if building is None:
            return None
        own = {fam for fam, spec in FAMILIES.items()
               if set(building["goods"]) & set(spec["goods"])}
        common = own if common is None else (common & own)
        if not common:
            return None
    if not common:
        return None
    return sorted(common)[0]


def condition_has_signal(condition, signal: str) -> bool:
    if not isinstance(condition, dict):
        return False
    if String_id(condition) == signal:
        return True
    return any(condition_has_signal(child, signal)
               for child in condition.get("children", []) or [])


def String_id(spec: dict) -> str:
    return str(spec.get("id", ""))


def with_practice(condition: dict, atom: dict) -> dict:
    if not condition:
        return atom
    if int(condition.get("operator", 0)) == 1 and condition.get("children"):
        merged = dict(condition)
        merged["children"] = list(condition["children"]) + [atom]
        return merged
    return {"operator": 1.0, "children": [condition, atom]}


def write_network(payload: dict, path: str) -> None:
    """保持原始格式：tab 缩进，空字典写成空行包裹的两行（作者手写的风格）。"""
    text = json.dumps(payload, ensure_ascii=False, indent="\t") + "\n"
    fixed = []
    for line in text.split("\n"):
        match = re.match(r'^(\t*)"([^"]+)": \{\},?$', line)
        if match:
            indent = match.group(1)
            tail = "," if line.rstrip().endswith(",") else ""
            fixed += [f'{indent}"{match.group(2)}": {{', "", f"{indent}}}{tail}"]
        else:
            fixed.append(line)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(fixed))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if not args.apply and not args.dry_run:
        parser.error("pass --dry-run or --apply")

    payload = json.load(open(NETWORK, encoding="utf-8"))
    nodes = {node["id"]: node for node in payload["nodes"]}
    buildings = load_buildings()

    planned: list[dict] = []
    skipped_mixed: list[str] = []
    for node_id, node in nodes.items():
        if node.get("network_role") == "backbone" or node.get("era_id") == "stone":
            continue
        if any(route.get("route_type") == "practice"
               for route in node.get("research_routes") or []):
            continue
        building_ids = [effect["id"] for effect in node.get("content_effects", [])
                        if effect.get("kind") == "building"
                        and not str(effect["id"]).startswith("method_")]
        if not building_ids:
            continue
        family = family_of(building_ids, buildings)
        if family is None:
            skipped_mixed.append(node_id)
            continue
        spec = FAMILIES[family]
        atom = {"kind": 1.0, "id": spec["signal"], "value": 1.0}
        routes = node.get("research_routes") or []
        if routes:
            for route in routes:
                if condition_has_signal(route.get("condition", {}), spec["signal"]):
                    continue
                route["condition"] = with_practice(route.get("condition", {}), atom)
            mode = "and-into-routes:%d" % len(routes)
        else:
            slug = node_id.replace("tech.", "").replace(".", "_")
            node["research_routes"] = [{
                "id": "research_route.%s.practice" % slug,
                "display_name": spec["name"],
                "route_type": "practice",
                "description": "本行当要求先把%s的规模做起来：合计日产出维持在 %.2f 以上并保持 180 日。"
                               % (spec["name"], spec["threshold"] / 1000.0),
                "condition": atom,
            }]
            mode = "new-practice-route"
        planned.append({"tech": node_id, "family": family, "mode": mode,
                        "buildings": building_ids})

    for node_id, reveal in MILITARY_REVEALS.items():
        node = nodes.get(node_id)
        if node is None:
            print("missing military node:", node_id)
            continue
        node["reveal_condition"] = reveal

    print("nodes patched:", len(planned))
    for row in sorted(planned, key=lambda r: (r["family"], r["tech"])):
        print("  %-46s %-14s %-22s %s" % (row["tech"], row["family"], row["mode"],
                                          ",".join(row["buildings"])))
    print("skipped (mixed families):", len(skipped_mixed))
    print("military reveals:", len(MILITARY_REVEALS))

    if args.apply:
        write_network(payload, NETWORK)
        print("written", NETWORK)
    return 0


if __name__ == "__main__":
    sys.exit(main())
