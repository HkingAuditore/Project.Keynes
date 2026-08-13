#!/usr/bin/env python3
"""Audit identification -> handling gaps like copper cold-hammering."""
from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path

NETWORK = Path(__file__).resolve().parents[1] / (
    "Project/project-keynes/data/technology/technology_network.json"
)


def collect_signals(spec, out: set[str]) -> None:
    if not isinstance(spec, dict) or not spec:
        return
    if "id" in spec and spec.get("kind") is not None:
        sid = str(spec.get("id", ""))
        if sid:
            out.add(sid)
    for child in spec.get("children") or []:
        collect_signals(child, out)


def object_signals(signals: set[str]) -> set[str]:
    keep = set()
    for sid in signals:
        if sid.startswith(("resource.", "bio.")):
            keep.add(sid)
        elif sid.startswith("contact."):
            keep.add(sid)
    return keep


def main() -> None:
    raw = NETWORK.read_text(encoding="utf-8")
    data = json.loads(raw, strict=False)
    nodes = data["nodes"]
    by_id = {n["id"]: n for n in nodes}

    ident = []
    for n in nodes:
        if n.get("node_role") == "identification" and not n.get("is_milestone") and not n.get("is_starting"):
            sigs = set()
            collect_signals(n.get("reveal_condition") or {}, sigs)
            ident.append((n, object_signals(sigs), sigs))

    ident_by_object: dict[str, list[str]] = defaultdict(list)
    for n, objs, _ in ident:
        for sid in objs:
            if sid.startswith(("resource.", "bio.")):
                ident_by_object[sid].append(n["id"])

    print("=== identification nodes ===")
    for n, objs, all_sigs in ident:
        print(
            f"{n['id']:42} era={n['era_id']:14} lane={n.get('main_lane','')} "
            f"hard={n.get('hard_prerequisite_ids')} objs={sorted(objs)}"
        )

    # Same-object handling/production without identification hard prereq
    print("\n=== handling/production sharing object evidence, missing ident hard prereq ===")
    gaps = []
    for n in nodes:
        if n.get("is_milestone") or n.get("is_starting"):
            continue
        role = str(n.get("node_role") or "")
        if role == "identification":
            continue
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        objs = {s for s in sigs if s.startswith(("resource.", "bio."))}
        hard = list(n.get("hard_prerequisite_ids") or [])
        matched = []
        for sid in sorted(objs):
            for iid in ident_by_object.get(sid, []):
                if iid not in hard and iid != n["id"]:
                    ident_node = by_id[iid]
                    # same era or ident earlier layout, and typically same-ish route
                    matched.append((sid, iid, ident_node["era_id"], ident_node.get("layout_order")))
        if not matched:
            continue
        breakthrough = sorted(s for s in sigs if s.startswith("breakthrough."))
        gaps.append((n, objs, hard, matched, breakthrough, sigs))

    # Focus: stone era empty-hard (day-0 analog)
    print("\n--- A. stone + empty hard (day-0 analog of copper working) ---")
    a_count = 0
    for n, objs, hard, matched, breakthrough, sigs in gaps:
        if n.get("era_id") != "stone" or hard:
            continue
        a_count += 1
        print(
            f"{n['id']:42} {n.get('display_name'):12} role={n.get('node_role'):18} "
            f"anchor={n.get('anchor_kind'):14} starter_elig={n.get('is_starter_eligible')} "
            f"objs={sorted(objs)} bt={breakthrough} missing={[m[1] for m in matched]}"
        )
    print(f"count A={a_count}")

    print("\n--- B. stone + non-empty hard, still missing ident ---")
    b_count = 0
    for n, objs, hard, matched, breakthrough, sigs in gaps:
        if n.get("era_id") != "stone" or not hard:
            continue
        # skip if ident is later era than this node
        relevant = [m for m in matched if by_id[m[1]]["era_id"] == "stone"]
        if not relevant:
            continue
        b_count += 1
        print(
            f"{n['id']:42} {n.get('display_name'):12} role={n.get('node_role'):18} "
            f"hard={hard} missing={[m[1] for m in relevant]}"
        )
    print(f"count B={b_count}")

    print("\n--- C. all stone empty-hard researchable (including no ident pair) ---")
    for n in nodes:
        if n.get("era_id") != "stone":
            continue
        if n.get("is_milestone") or n.get("is_starting"):
            continue
        hard = list(n.get("hard_prerequisite_ids") or [])
        if hard:
            continue
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        bt = sorted(s for s in sigs if s.startswith("breakthrough."))
        print(
            f"{n['id']:42} {n.get('display_name'):16} role={n.get('node_role') or '-':18} "
            f"anchor={n.get('anchor_kind') or '-':14} starter_elig={n.get('is_starter_eligible')} "
            f"sigs={sorted(sigs)} bt={bt}"
        )

    print("\n--- D. starting (granted) nodes: keep empty hard ---")
    for n in nodes:
        if n.get("is_starting"):
            print(
                f"{n['id']:42} {n.get('display_name'):16} hard={n.get('hard_prerequisite_ids')} "
                f"elig={n.get('is_starter_eligible')}"
            )


if __name__ == "__main__":
    main()
