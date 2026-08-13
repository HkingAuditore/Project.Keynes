#!/usr/bin/env python3
"""Inventory remaining cloned reveal packs after wave 3."""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

NET = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\technology\technology_network.json")
OUT = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\wave4_inventory.txt")

PACKS = {
    "elec_assembly": frozenset({
        "breakthrough.electrification",
        "breakthrough.motor_winding",
        "breakthrough.assembly_line",
    }),
    "stone_knowledge": frozenset({
        "weather.monsoon",
        "weather.frost",
        "landform.river_valley",
    }),
    "agrarian_institution": frozenset({
        "resource.fertile_soil",
        "landform.river_valley",
        "breakthrough.seed_saving",
    }),
    "steam_org": frozenset({
        "breakthrough.steam_power",
        "breakthrough.industrial_organization",
        "breakthrough.print_calibration",
    }),
    "steam_seal": frozenset({
        "breakthrough.steam_power",
        "breakthrough.steam_sealing",
        "breakthrough.assembly_line",
    }),
    "timber_forest": frozenset({
        "resource.timber",
        "landform.forest",
        "breakthrough.forest_management",
    }),
}


def collect_signals(spec, out):
    if not spec:
        return
    if "kind" in spec:
        if int(spec.get("kind", -1)) in (1, 2):
            sid = spec.get("id", "")
            if sid and sid not in out:
                out.append(sid)
        return
    for child in spec.get("children") or []:
        if isinstance(child, dict):
            collect_signals(child, out)


def main() -> None:
    data = json.loads(NET.read_text(encoding="utf-8"))
    lines: list[str] = []
    by_pack: dict[str, list[str]] = {k: [] for k in PACKS}
    triples = Counter()
    for node in data["nodes"]:
        if node.get("is_milestone") or node.get("is_starting"):
            continue
        sigs: list[str] = []
        collect_signals(node.get("reveal_condition") or {}, sigs)
        key = frozenset(sigs)
        if len(sigs) >= 2:
            triples[tuple(sorted(sigs))] += 1
        row = "|".join([
            node["id"],
            node.get("display_name", ""),
            node.get("node_role", ""),
            node.get("era_id", ""),
            node.get("domain_id", ""),
            node.get("effect_profile", ""),
            ",".join(sigs),
        ])
        for pack_name, pack in PACKS.items():
            if key == pack:
                by_pack[pack_name].append(row)
    for pack_name, rows in by_pack.items():
        lines.append("=== %s %d ===" % (pack_name, len(rows)))
        lines.extend(rows)
        lines.append("")
    lines.append("=== most cloned remaining ===")
    for pack, n in triples.most_common(15):
        if n >= 4:
            lines.append("%d\t%s" % (n, ",".join(pack)))
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print("wrote", OUT)
    for pack_name, rows in by_pack.items():
        print(pack_name, len(rows))


if __name__ == "__main__":
    main()
