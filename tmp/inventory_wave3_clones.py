#!/usr/bin/env python3
"""List nodes still using cloned era-dump reveal packs."""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

NET = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\technology\technology_network.json")
OUT = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\wave3_inventory.txt")

PACKS = {
    "print_maritime": frozenset({
        "breakthrough.printing",
        "breakthrough.print_calibration",
        "breakthrough.maritime_operations",
    }),
    "rare_earth_auto": frozenset({
        "breakthrough.electrification",
        "breakthrough.automation",
        "resource.rare_earth",
    }),
    "digital_rare": frozenset({
        "breakthrough.digital_control",
        "breakthrough.automation",
        "resource.rare_earth",
    }),
    "digital_energy": frozenset({
        "breakthrough.digital_control",
        "breakthrough.automation",
        "breakthrough.energy_control",
    }),
    "elec_assembly": frozenset({
        "breakthrough.electrification",
        "breakthrough.motor_winding",
        "breakthrough.assembly_line",
    }),
    "steam_print": frozenset({
        "breakthrough.steam_power",
        "breakthrough.industrial_organization",
        "breakthrough.print_calibration",
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
    leftover_print = []
    leftover_rare = []
    for node in data["nodes"]:
        if node.get("is_milestone") or node.get("is_starting"):
            continue
        sigs: list[str] = []
        collect_signals(node.get("reveal_condition") or {}, sigs)
        key = frozenset(sigs)
        row = "|".join([
            node["id"],
            node.get("display_name", ""),
            node.get("node_role", ""),
            node.get("era_id", ""),
            node.get("domain_id", ""),
            node.get("effect_profile", ""),
            node.get("main_lane", ""),
            ",".join(sigs),
        ])
        matched = False
        for pack_name, pack in PACKS.items():
            if key == pack:
                by_pack[pack_name].append(row)
                matched = True
        if not matched:
            if "breakthrough.printing" in sigs and "breakthrough.maritime_operations" in sigs:
                leftover_print.append(row)
            if "resource.rare_earth" in sigs:
                leftover_rare.append(row)
    for pack_name, rows in by_pack.items():
        lines.append("=== %s %d ===" % (pack_name, len(rows)))
        lines.extend(rows)
        lines.append("")
    lines.append("=== leftover printing+maritime %d ===" % len(leftover_print))
    lines.extend(leftover_print)
    lines.append("")
    lines.append("=== leftover rare_earth %d ===" % len(leftover_rare))
    lines.extend(leftover_rare)
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print("wrote", OUT)
    for pack_name, rows in by_pack.items():
        print(pack_name, len(rows))
    print("leftover print", len(leftover_print), "leftover rare", len(leftover_rare))


if __name__ == "__main__":
    main()
