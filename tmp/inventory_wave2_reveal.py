#!/usr/bin/env python3
"""Inventory wave-2 reveal candidates: handling, production_system, wide tokens."""
from __future__ import annotations

import json
from pathlib import Path

NET = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\technology\technology_network.json")
OUT = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\wave2_inventory.txt")

WIDE = {
    "fiber": ["fiber", "weaving", "loom", "spinning", "textile", "flax", "cotton"],
    "grain": ["wheat", "grain", "cereal", "rainfed", "dryland", "maize", "rice", "paddy", "potato", "tuber"],
    "mine": ["iron", "steel", "coal", "mine", "mining", "shaft"],
    "metal": ["copper", "tin", "bronze", "alloy", "metallurgy", "metal"],
    "maritime": ["maritime", "ocean", "ship", "port", "navigation", "logistics", "coast"],
    "clay": ["clay", "pottery", "kiln", "brick", "adobe"],
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


def id_tokens(nid: str) -> list[str]:
    return nid.replace("tech.", "").split("_")


def which_wide(nid: str) -> list[str]:
    toks = id_tokens(nid)
    hay = " ".join(toks)
    hits = []
    for fam, words in WIDE.items():
        for word in words:
            if word in toks or (len(word) > 3 and word in hay):
                hits.append(fam)
                break
    return hits


def main() -> None:
    data = json.loads(NET.read_text(encoding="utf-8"))
    lines: list[str] = []

    def dump(title: str, rows: list[str]) -> None:
        lines.append(title)
        lines.extend(rows)
        lines.append("count %d" % len(rows))
        lines.append("")

    handling = []
    production = []
    applied = []
    wide = []
    for node in data["nodes"]:
        if node.get("is_milestone") or node.get("is_starting"):
            continue
        sigs: list[str] = []
        collect_signals(node.get("reveal_condition") or {}, sigs)
        row = "|".join([
            node["id"],
            node.get("display_name", ""),
            node.get("node_role", ""),
            node.get("era_id", ""),
            node.get("effect_profile", ""),
            ",".join(sigs),
        ])
        role = node.get("node_role", "")
        if role == "handling":
            handling.append(row)
        elif role == "production_system":
            production.append(row)
        elif role == "applied_method":
            applied.append(row)
        fams = which_wide(node["id"])
        if fams and role != "identification":
            wide.append("|".join(fams) + "|" + row)

    dump("=== handling ===", handling)
    dump("=== production_system ===", production)
    dump("=== applied_method (crop/mine related only later) ===", applied)
    dump("=== wide-token non-ident ===", wide)
    OUT.write_text("\n".join(lines), encoding="utf-8")
    print("wrote", OUT, "handling", len(handling), "prod", len(production), "wide", len(wide))


if __name__ == "__main__":
    main()
