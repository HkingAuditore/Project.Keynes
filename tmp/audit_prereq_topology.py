#!/usr/bin/env python3
"""Audit hard-prerequisite topology for scientific/knowledge-order issues."""
from __future__ import annotations

import json
from collections import defaultdict, deque
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "Project/project-keynes/data/technology/technology_network.json"
OUT = ROOT / "tmp/prereq_topology_audit.json"

ERA_ORDER = [
    "stone", "agrarian", "kingdom", "empire", "exploration",
    "enlightenment", "steam", "electrical", "atomic", "information", "intelligent",
]


def collect_signals(spec, out: set[str]) -> None:
    if not isinstance(spec, dict) or not spec:
        return
    sid = str(spec.get("id") or "")
    if sid:
        out.add(sid)
    for child in spec.get("children") or []:
        collect_signals(child, out)


def objects(signals: set[str]) -> set[str]:
    return {s for s in signals if s.startswith(("resource.", "bio."))}


def main() -> None:
    data = json.loads(NETWORK.read_text(encoding="utf-8"), strict=False)
    nodes = data["nodes"]
    by_id = {n["id"]: n for n in nodes}
    hard_of = {n["id"]: list(n.get("hard_prerequisite_ids") or []) for n in nodes}
    era_index = {e: i for i, e in enumerate(ERA_ORDER)}
    milestones = {n["era_id"]: n["id"] for n in nodes if n.get("is_milestone")}

    def closure(tid: str) -> set[str]:
        seen = set()
        stack = list(hard_of.get(tid, []))
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            stack.extend(hard_of.get(cur, []))
        return seen

    # cycles
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {n["id"]: WHITE for n in nodes}
    cycles = []

    def dfs(u: str, path: list[str]) -> None:
        color[u] = GRAY
        path.append(u)
        for v in hard_of[u]:
            if color[v] == GRAY:
                cycles.append(path[path.index(v):] + [v])
            elif color[v] == WHITE:
                dfs(v, path)
        path.pop()
        color[u] = BLACK

    for n in nodes:
        if color[n["id"]] == WHITE:
            dfs(n["id"], [])

    era_back = []
    layout_back = []
    missing_node = []
    for n in nodes:
        for hid in hard_of[n["id"]]:
            if hid not in by_id:
                missing_node.append((n["id"], hid))
                continue
            h = by_id[hid]
            if era_index[h["era_id"]] > era_index[n["era_id"]]:
                era_back.append((n["id"], hid))
            if int(h["layout_order"]) >= int(n["layout_order"]):
                layout_back.append((n["id"], hid, h["layout_order"], n["layout_order"]))

    ident_nodes = [
        n for n in nodes
        if n.get("node_role") == "identification" and not n.get("is_starting")
    ]
    ident_info = {}
    ident_by_obj = defaultdict(list)
    for n in ident_nodes:
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        objs = objects(sigs)
        ident_info[n["id"]] = objs
        for oid in objs:
            ident_by_obj[oid].append(n["id"])

    # first same-object handling missing ident in closure
    first_skip = []
    later_skip = []
    for n in nodes:
        if n.get("is_milestone") or n.get("is_starting"):
            continue
        if n.get("node_role") == "identification":
            continue
        role = str(n.get("node_role") or "")
        if role not in ("handling", "production_system"):
            continue
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        objs = objects(sigs)
        cl = closure(n["id"])
        hard = hard_of[n["id"]]
        missing = []
        for oid in objs:
            for iid in ident_by_obj.get(oid, []):
                ident = by_id[iid]
                if int(ident["layout_order"]) >= int(n["layout_order"]):
                    continue
                if iid in hard or iid in cl:
                    continue
                missing.append(iid)
        missing = sorted(set(missing))
        if not missing:
            continue
        row = {
            "id": n["id"],
            "name": n.get("display_name"),
            "era": n["era_id"],
            "role": role,
            "anchor": n.get("anchor_kind"),
            "lane": n.get("main_lane"),
            "hard": [by_id[h]["display_name"] + f" ({h})" for h in hard],
            "missing": [by_id[m]["display_name"] + f" ({m})" for m in missing],
        }
        if n["era_id"] == "stone" and not hard:
            first_skip.append(row)
        else:
            later_skip.append(row)

    # cross-object: handling hard is an identification of a disjoint object
    wrong_ident = []
    for n in nodes:
        if n.get("is_starting") or n.get("is_milestone"):
            continue
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        objs = objects(sigs)
        if not objs:
            continue
        for hid in hard_of[n["id"]]:
            h = by_id[hid]
            if h.get("node_role") != "identification":
                continue
            hobjs = ident_info.get(hid, set())
            if hobjs and objs.isdisjoint(hobjs):
                wrong_ident.append({
                    "id": n["id"],
                    "name": n.get("display_name"),
                    "objs": sorted(objs),
                    "ident": hid,
                    "ident_name": h.get("display_name"),
                    "ident_objs": sorted(hobjs),
                })

    # thematically odd: hard prereq is not milestone, different lane, and
    # object sets disjoint, and neither is identification-of-same
    odd_cross = []
    for n in nodes:
        if n.get("is_starting") or n.get("is_milestone"):
            continue
        nsigs = set()
        collect_signals(n.get("reveal_condition") or {}, nsigs)
        nobjs = objects(nsigs)
        for hid in hard_of[n["id"]]:
            h = by_id[hid]
            if h.get("is_milestone"):
                continue
            if h["main_lane"] == n["main_lane"]:
                continue
            hsigs = set()
            collect_signals(h.get("reveal_condition") or {}, hsigs)
            hobjs = objects(hsigs)
            if nobjs and hobjs and nobjs.isdisjoint(hobjs):
                odd_cross.append({
                    "id": n["id"],
                    "name": n.get("display_name"),
                    "era": n["era_id"],
                    "lane": n.get("main_lane"),
                    "anchor": n.get("anchor_kind"),
                    "prereq": hid,
                    "prereq_name": h.get("display_name"),
                    "prereq_lane": h.get("main_lane"),
                    "prereq_role": h.get("node_role"),
                    "node_objs": sorted(nobjs),
                    "prereq_objs": sorted(hobjs),
                })

    # same-lane previous but disjoint objects (generator chain artifact)
    odd_same_lane = []
    for n in nodes:
        if n.get("is_starting") or n.get("is_milestone"):
            continue
        nsigs = set()
        collect_signals(n.get("reveal_condition") or {}, nsigs)
        nobjs = objects(nsigs)
        if not nobjs:
            continue
        for hid in hard_of[n["id"]]:
            h = by_id[hid]
            if h.get("is_milestone") or h["main_lane"] != n["main_lane"]:
                continue
            if h.get("node_role") == "identification":
                continue
            hsigs = set()
            collect_signals(h.get("reveal_condition") or {}, hsigs)
            hobjs = objects(hsigs)
            if hobjs and nobjs.isdisjoint(hobjs):
                odd_same_lane.append({
                    "id": n["id"],
                    "name": n.get("display_name"),
                    "era": n["era_id"],
                    "lane": n.get("main_lane"),
                    "prereq": hid,
                    "prereq_name": h.get("display_name"),
                    "node_objs": sorted(nobjs),
                    "prereq_objs": sorted(hobjs),
                })

    # designed chains
    def has_edge(a, b) -> bool:
        return a in hard_of.get(b, [])

    def in_closure(a, b) -> bool:
        return a in closure(b)

    designed = [
        ("玉米", ["tech.maize_identification", "tech.wild_maize_collection",
                 "tech.maize_seed_saving", "tech.maize_propagation"]),
        ("小麦", ["tech.wheat_identification", "tech.wild_wheat_collection",
                 "tech.wheat_seed_saving", "tech.wheat_propagation"]),
        ("水稻", ["tech.rice_identification", "tech.wild_rice_collection",
                 "tech.rice_seed_saving"]),
        ("块茎", ["tech.potato_identification", "tech.tuber_storage",
                 "tech.potato_propagation"]),
        ("黏土", ["tech.clay_identification", "tech.clay_preparation",
                 "tech.hand_pottery"]),
        ("铜", ["tech.natural_copper_identification", "tech.natural_copper_working",
               "tech.copper_annealing", "tech.copper_ore_roasting"]),
        ("棉花", ["tech.cotton_identification", "tech.wild_cotton_collection"]),
        ("香料", ["tech.spice_identification", "tech.wild_spice_collection"]),
        ("橡胶", ["tech.rubber_identification", "tech.wild_latex_tapping"]),
        ("亚麻沤麻", ["tech.flax_identification", "tech.flax_retting"]),
        ("铁矿拣采", ["tech.iron_ore_identification", "tech.surface_iron_collection"]),
        ("煤炭拣采", ["tech.coal_outcrop_identification", "tech.surface_coal_collection"]),
        ("锡在铜后", ["tech.copper_annealing", "tech.tin_identification"]),
    ]
    designed_ok = []
    designed_break = []
    for label, chain in designed:
        broken = []
        for a, b in zip(chain, chain[1:]):
            if not has_edge(a, b):
                broken.append(f"{by_id[a]['display_name']} ↛ {by_id[b]['display_name']}")
        (designed_break if broken else designed_ok).append({"label": label, "broken": broken, "chain": chain})

    extra_designed = [
        ("陶器容器←手制陶器", "tech.hand_pottery", "tech.pottery"),
        ("日晒土坯←手制陶器", "tech.hand_pottery", "tech.adobe_making"),
        ("青铜←锡辨识", "tech.tin_identification", "tech.bronze_casting"),
        ("青铜←冷锤", "tech.natural_copper_working", "tech.bronze_casting"),
        ("块炼铁←铁矿辨识", "tech.iron_ore_identification", "tech.iron_smelting"),
        ("地表用煤←露头煤辨识", "tech.coal_outcrop_identification", "tech.surface_coal_use"),
        ("纤维捻制←亚麻辨识", "tech.flax_identification", "tech.fiber_twisting"),
        ("高地块茎农业←块茎保存", "tech.tuber_storage", "tech.highland_tuber_farming"),
        ("垄作块茎←块茎辨识", "tech.potato_identification", "tech.ridge_tuber_cultivation"),
    ]
    extra_rows = []
    for label, a, b in extra_designed:
        extra_rows.append({
            "label": label,
            "direct": has_edge(a, b),
            "transitive": in_closure(a, b),
            "b_hard": hard_of[b],
        })

    # stone empty-hard researchable (not starting, not ident)
    stone_empty = []
    for n in nodes:
        if n["era_id"] != "stone" or n.get("is_starting") or n.get("is_milestone"):
            continue
        if hard_of[n["id"]]:
            continue
        stone_empty.append({
            "id": n["id"],
            "name": n.get("display_name"),
            "role": n.get("node_role"),
            "anchor": n.get("anchor_kind"),
            "lane": n.get("main_lane"),
        })

    # cross-lane hard (non-milestone)
    cross = []
    for n in nodes:
        for hid in hard_of[n["id"]]:
            h = by_id[hid]
            if h.get("is_milestone"):
                continue
            if h["main_lane"] != n["main_lane"]:
                cross.append({
                    "from": hid,
                    "from_name": h.get("display_name"),
                    "to": n["id"],
                    "to_name": n.get("display_name"),
                    "from_lane": h["main_lane"],
                    "to_lane": n["main_lane"],
                })

    inventory = {
        "cycles": cycles,
        "era_back": era_back,
        "layout_back": layout_back,
        "missing_node": missing_node,
        "day0_ident_skip": first_skip,
        "later_ident_skip_count": len(later_skip),
        "later_ident_skip_stone_agrarian": [
            r for r in later_skip if r["era"] in ("stone", "agrarian", "kingdom")
        ],
        "wrong_ident": wrong_ident,
        "odd_cross_count": len(odd_cross),
        "odd_cross_stone_agrarian": [
            r for r in odd_cross if r["era"] in ("stone", "agrarian")
        ],
        "odd_same_lane_count": len(odd_same_lane),
        "odd_same_lane_stone_agrarian": [
            r for r in odd_same_lane if r["era"] in ("stone", "agrarian")
        ],
        "designed_ok": designed_ok,
        "designed_break": designed_break,
        "extra_designed": extra_rows,
        "stone_empty": stone_empty,
        "cross_lane_hard": cross,
    }
    OUT.write_text(json.dumps(inventory, ensure_ascii=False, indent=2), encoding="utf-8")

    print("cycles", len(cycles), "era_back", era_back, "layout_back", layout_back)
    print("day0 skip", len(first_skip), "later skip", len(later_skip), "wrong ident", wrong_ident)
    print("odd_cross", len(odd_cross), "odd_same_lane", len(odd_same_lane), "cross_lane_hard", len(cross))
    print("designed_ok", [x["label"] for x in designed_ok])
    print("designed_break", designed_break)
    print("\n=== extra designed ===")
    for r in extra_rows:
        print(f"{r['label']:28} direct={r['direct']} trans={r['transitive']} hard={r['b_hard']}")
    print("\n=== stone empty hard ===")
    for r in stone_empty:
        print(f"{r['id']:42} {r['name']} role={r['role']} anchor={r['anchor']}")
    print("\n=== later skip stone/agrarian/kingdom ===")
    for r in inventory["later_ident_skip_stone_agrarian"]:
        print(f"{r['era']:10} {r['name']:16} hard={r['hard']} missing={r['missing']}")
    print("\n=== odd cross stone/agrarian ===")
    for r in inventory["odd_cross_stone_agrarian"]:
        print(f"{r['name']} ({r['id']}) <- {r['prereq_name']} ({r['prereq']}) {r['prereq_lane']} -> {r['lane']}")
    print("\n=== odd same-lane stone/agrarian ===")
    for r in inventory["odd_same_lane_stone_agrarian"]:
        print(f"{r['name']} <- {r['prereq_name']} objs {r['node_objs']} vs {r['prereq_objs']}")
    print("\n=== cross-lane hard ===")
    for r in cross:
        print(f"{r['from_name']} -> {r['to_name']}  ({r['from_lane']} -> {r['to_lane']})")


if __name__ == "__main__":
    main()
