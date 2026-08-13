#!/usr/bin/env python3
"""Full identification-handling gap inventory."""
from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "Project/project-keynes/data/technology/technology_network.json"
OUT = ROOT / "tmp/ident_handling_inventory.json"


def collect_signals(spec, out: set[str]) -> None:
    if not isinstance(spec, dict) or not spec:
        return
    sid = str(spec.get("id", "") or "")
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

    ident_nodes = [
        n for n in nodes
        if n.get("node_role") == "identification"
        and not n.get("is_milestone")
        and not n.get("is_starting")
    ]
    ident_by_obj: dict[str, list[str]] = defaultdict(list)
    ident_info = {}
    for n in ident_nodes:
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        objs = objects(sigs)
        ident_info[n["id"]] = {"objs": sorted(objs), "all": sorted(sigs), "node": n}
        for oid in objs:
            ident_by_obj[oid].append(n["id"])

    issues = []
    for n in nodes:
        if n.get("is_milestone") or n.get("is_starting"):
            continue
        if n.get("node_role") == "identification":
            continue
        role = str(n.get("node_role") or "")
        if role not in ("handling", "production_system", "applied_method", "power_scale"):
            continue
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        objs = objects(sigs)
        hard = hard_of[n["id"]]
        cl = closure(n["id"])
        missing = []
        for oid in sorted(objs):
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
        bt = sorted(s for s in sigs if s.startswith("breakthrough."))
        issues.append({
            "id": n["id"],
            "name": n.get("display_name"),
            "era": n["era_id"],
            "role": role,
            "anchor": n.get("anchor_kind"),
            "lane": n.get("main_lane"),
            "order": int(n["layout_order"]),
            "hard": hard,
            "empty_hard": not hard,
            "objs": sorted(objs),
            "breakthrough": bt,
            "reveal_op": int((n.get("reveal_condition") or {}).get("operator", -1)),
            "missing_ident": missing,
            "day0_analog": n["era_id"] == "stone" and not hard,
        })

    inverted = []
    for iid, info in ident_info.items():
        n = info["node"]
        for hid in hard_of[iid]:
            h = by_id[hid]
            hsigs = set()
            collect_signals(h.get("reveal_condition") or {}, hsigs)
            shared = objects(hsigs) & set(info["objs"])
            if shared or h.get("node_role") in ("handling", "production_system"):
                inverted.append({
                    "ident": iid,
                    "ident_name": n.get("display_name"),
                    "ident_order": int(n["layout_order"]),
                    "prereq": hid,
                    "prereq_name": h.get("display_name"),
                    "prereq_role": h.get("node_role"),
                    "prereq_order": int(h["layout_order"]),
                    "shared_objects": sorted(shared),
                    "same_object_handling": bool(shared),
                })

    wrong_object = []
    for n in nodes:
        if n.get("is_starting") or n.get("is_milestone"):
            continue
        hard = hard_of[n["id"]]
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        objs = objects(sigs)
        for hid in hard:
            h = by_id[hid]
            if h.get("node_role") != "identification":
                continue
            hsigs = set()
            collect_signals(h.get("reveal_condition") or {}, hsigs)
            hobjs = objects(hsigs)
            if objs and hobjs and objs.isdisjoint(hobjs):
                wrong_object.append({
                    "id": n["id"],
                    "name": n.get("display_name"),
                    "objs": sorted(objs),
                    "ident": hid,
                    "ident_name": h.get("display_name"),
                    "ident_objs": sorted(hobjs),
                })

    # visual hard vs node hard
    visual_hard = [
        (e["from"], e["to"])
        for e in data["visual_edges"]
        if e.get("kind") == "hard"
    ]
    node_hard_edges = []
    for n in nodes:
        for hid in hard_of[n["id"]]:
            node_hard_edges.append((hid, n["id"]))

    inventory = {
        "ident_count": len(ident_nodes),
        "missing_ident_on_handling": issues,
        "day0_count": sum(1 for i in issues if i["day0_analog"]),
        "inverted_ident_prereqs": inverted,
        "wrong_object_ident_prereq": wrong_object,
        "visual_hard": len(visual_hard),
        "node_hard": len(node_hard_edges),
    }
    OUT.write_text(json.dumps(inventory, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"ident={len(ident_nodes)} missing_ident_handling={len(issues)} day0={inventory['day0_count']}")
    print("\n=== DAY0 ANALOGS ===")
    for i in issues:
        if i["day0_analog"]:
            print(f"{i['id']:42} {i['name']} missing={i['missing_ident']} objs={i['objs']} bt={i['breakthrough']} op={i['reveal_op']}")
    print("\n=== LATER MISSING IDENT (first 40) ===")
    later = [i for i in issues if not i["day0_analog"]]
    for i in later[:40]:
        print(f"{i['era']:14} {i['id']:42} {i['name']} hard={i['hard']} missing={i['missing_ident']}")
    print(f"... later total {len(later)}")
    print("\n=== INVERTED IDENT PREREQS ===")
    for row in inverted:
        print(f"{row['ident']:42} <- {row['prereq']:42} same_obj={row['same_object_handling']} shared={row['shared_objects']}")
    print("\n=== WRONG OBJECT IDENT PREREQ ===")
    for row in wrong_object:
        print(f"{row['id']:42} uses {row['ident']} ident_objs={row['ident_objs']} node_objs={row['objs']}")


if __name__ == "__main__":
    main()
