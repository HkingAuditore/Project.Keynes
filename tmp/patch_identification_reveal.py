#!/usr/bin/env python3
"""Patch identification-node reveal conditions in technology_network.json."""
from __future__ import annotations

import json
from pathlib import Path

PATH = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\technology\technology_network.json")

EVIDENCE = {
    "tech.clay_identification": ["resource.clay"],
    "tech.natural_copper_identification": ["resource.copper_ore"],
    "tech.tin_identification": ["resource.tin_ore", "contact.tin"],
    "tech.maize_identification": ["bio.maize", "contact.maize"],
    "tech.wheat_identification": ["bio.wheat", "contact.wheat"],
    "tech.rice_identification": ["bio.rice", "contact.rice"],
    "tech.potato_identification": ["bio.potato", "contact.potato"],
    "tech.cotton_identification": ["bio.cotton", "contact.cotton"],
    "tech.flax_identification": ["bio.flax", "bio.bast_fiber", "contact.flax"],
    "tech.spice_identification": ["bio.spice", "contact.spice"],
    "tech.rubber_identification": ["bio.rubber", "contact.rubber"],
    "tech.gold_placer_identification": ["resource.gold_ore", "landform.freshwater_access"],
    "tech.silver_vein_identification": ["resource.silver_ore"],
    "tech.reed_identification": ["bio.reed", "landform.marsh", "landform.freshwater_access"],
    "tech.flint_identification": ["resource.flint"],
    "tech.iron_ore_identification": ["resource.iron_ore"],
    "tech.coal_outcrop_identification": ["resource.coal"],
    "tech.coal_geology": ["resource.coal"],
}


def any_of(signals: list[str]) -> dict:
    return {
        "operator": 2,
        "children": [{"kind": 1, "id": sid, "value": 1} for sid in signals],
    }


def dump_block(spec: dict, indent: str) -> str:
    dumped = json.dumps(spec, ensure_ascii=False, indent="\t")
    lines = dumped.split("\n")
    return lines[0] + "\n" + "\n".join(indent + line for line in lines[1:])


def replace_object_after(text: str, key_idx: int) -> tuple[int, int]:
    brace = text.find("{", key_idx)
    depth = 0
    for i in range(brace, len(text)):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return brace, i + 1
    raise RuntimeError("unbalanced braces")


def main() -> None:
    text = PATH.read_text(encoding="utf-8")
    for tech_id, signals in EVIDENCE.items():
        needle = f'"id": "{tech_id}"'
        idx = text.find(needle)
        if idx < 0:
            raise SystemExit(f"missing {tech_id}")
        key = '"reveal_condition":'
        ridx = text.find(key, idx)
        next_id = text.find('\n\t\t{\n\t\t\t"id":', idx + len(needle))
        if next_id != -1 and ridx > next_id:
            raise SystemExit(f"reveal_condition not in {tech_id}")
        brace, end = replace_object_after(text, ridx)
        old = json.loads(text[brace:end])
        if int(old.get("operator", -1)) == 1:
            new_children = []
            replaced = False
            for child in old.get("children", []):
                if int(child.get("kind", -1)) == 0:
                    new_children.append(child)
                else:
                    new_children.append(any_of(signals))
                    replaced = True
            if not replaced:
                new_children.append(any_of(signals))
            new_spec = {"operator": 1, "children": new_children}
        else:
            new_spec = any_of(signals)
        line_start = text.rfind("\n", 0, ridx) + 1
        indent = text[line_start:ridx]
        text = text[:brace] + dump_block(new_spec, indent) + text[end:]
        print(f"patched {tech_id} -> {signals}")
    PATH.write_text(text, encoding="utf-8", newline="\n")
    data = json.loads(PATH.read_text(encoding="utf-8"))
    ids = {n["id"] for n in data["nodes"]}
    for tech_id in EVIDENCE:
        if tech_id not in ids:
            raise SystemExit(f"lost {tech_id}")
    print("ok", PATH)


if __name__ == "__main__":
    main()
