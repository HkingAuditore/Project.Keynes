#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

NETWORK = Path(__file__).resolve().parents[1] / (
    "Project/project-keynes/data/technology/technology_network.json"
)

FOCUS = [
    "tech.clay_identification",
    "tech.clay_preparation",
    "tech.hand_pottery",
    "tech.adobe_making",
    "tech.pottery",
    "tech.natural_copper_identification",
    "tech.natural_copper_working",
    "tech.copper_annealing",
    "tech.copper_ore_roasting",
    "tech.tin_identification",
    "tech.maize_identification",
    "tech.wild_maize_collection",
    "tech.wheat_identification",
    "tech.wild_wheat_collection",
    "tech.rice_identification",
    "tech.wild_rice_collection",
    "tech.potato_identification",
    "tech.wild_tuber_collection",
    "tech.tuber_storage",
    "tech.cotton_identification",
    "tech.wild_cotton_collection",
    "tech.flax_identification",
    "tech.wild_flax_collection",
    "tech.flax_retting",
    "tech.fiber_twisting",
    "tech.spice_identification",
    "tech.wild_spice_collection",
    "tech.rubber_identification",
    "tech.wild_latex_tapping",
    "tech.gold_placer_identification",
    "tech.gold_panning",
    "tech.silver_vein_identification",
    "tech.surface_silver_collection",
    "tech.reed_identification",
    "tech.reed_harvesting",
    "tech.flint_identification",
    "tech.stone_knapping",
    "tech.composite_tools",
    "tech.iron_ore_identification",
    "tech.surface_iron_collection",
    "tech.iron_smelting",
    "tech.coal_outcrop_identification",
    "tech.surface_coal_use",
    "tech.surface_coal_collection",
    "tech.coal_mining",
    "tech.charcoal_burning",
    "tech.brine_collection",
    "tech.controlled_burning",
    "tech.fishing_boats",
    "tech.herd_management",
]


def collect_signals(spec, out: set[str]) -> None:
    if not isinstance(spec, dict) or not spec:
        return
    sid = str(spec.get("id", ""))
    if sid:
        out.add(sid)
    for child in spec.get("children") or []:
        collect_signals(child, out)


def op_label(spec) -> str:
    if not isinstance(spec, dict) or not spec:
        return "empty"
    op = spec.get("operator")
    kind = spec.get("kind")
    if op is not None:
        return {1: "ALL_OF", 2: "ANY_OF", 3: "AT_LEAST", 4: "NOT"}.get(int(op), str(op))
    if kind is not None:
        return f"atom:{spec.get('id')}"
    return "?"


def main() -> None:
    data = json.loads(NETWORK.read_text(encoding="utf-8"), strict=False)
    by_id = {n["id"]: n for n in data["nodes"]}
    print(f"{'id':42} {'era':12} {'order':5} {'role':18} {'anchor':16} {'start':5} {'hard':50} reveal_op  signals")
    for tid in FOCUS:
        n = by_id[tid]
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        hard = ",".join(n.get("hard_prerequisite_ids") or []) or "-"
        print(
            f"{tid:42} {n['era_id']:12} {int(n['layout_order']):5} "
            f"{str(n.get('node_role') or '-'):18} {str(n.get('anchor_kind') or '-'):16} "
            f"{int(bool(n.get('is_starting')))} {hard:50} {op_label(n.get('reveal_condition')):8} "
            f"{sorted(sigs)}"
        )

    print("\n=== stone empty-hard handling/production (not starting, not ident) ===")
    for n in sorted(data["nodes"], key=lambda x: int(x["layout_order"])):
        if n.get("era_id") != "stone":
            continue
        if n.get("is_starting") or n.get("is_milestone"):
            continue
        if n.get("node_role") == "identification":
            continue
        hard = n.get("hard_prerequisite_ids") or []
        if hard:
            continue
        sigs = set()
        collect_signals(n.get("reveal_condition") or {}, sigs)
        print(
            f"{n['id']:42} {n.get('display_name')} role={n.get('node_role')} "
            f"anchor={n.get('anchor_kind')} op={op_label(n.get('reveal_condition'))} sigs={sorted(sigs)}"
        )


if __name__ == "__main__":
    main()
