#!/usr/bin/env python3
"""Show source tokens that match SEMANTIC rules by prefix, not equality."""
from pathlib import Path
import json

NET = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\technology\technology_network.json")
RULES = [
    ["cotton"],
    ["flax", "fiber", "weaving", "loom", "spinning", "textile"],
    ["spice"],
    ["rubber", "latex"],
    ["maize"],
    ["wheat", "grain", "cereal", "rainfed", "dryland"],
    ["rice", "paddy"],
    ["potato", "tuber", "terrace", "highland"],
    ["horse", "pastoral", "livestock", "herd", "wool", "dairy", "meat"],
    ["hide", "leather", "fur", "hunting", "animal"],
    ["forest", "timber", "wood", "lumber", "paper", "bark", "charcoal"],
    ["fish", "fishing"],
    ["maritime", "ocean", "ship", "port", "navigation", "logistics", "coast"],
    ["clay", "pottery", "kiln", "brick", "adobe"],
    ["flint", "stone", "masonry", "earth", "construction", "cement", "concrete"],
    ["glass", "silica"],
    ["copper"],
    ["tin"],
    ["bronze", "alloy", "metallurgy", "metal"],
    ["iron", "steel", "coal", "mine", "mining", "shaft"],
    ["gold", "silver"],
    ["salt"],
    ["sulfur", "phosphate", "fertilizer", "gunpowder", "explosive", "chemistry", "chemical"],
    ["oil", "petroleum", "fuel", "combustion", "gas", "plastic", "synthetic"],
    ["irrigation", "hydraulic", "canal", "water", "hydro", "watershed"],
    ["wind"],
]

data = json.loads(NET.read_text(encoding="utf-8"))
rows = []
for node in data["nodes"]:
    tokens = [t for t in node["id"].replace("tech.", "").split("_") if t]
    for token in tokens:
        for rule in RULES:
            for rule_token in rule:
                if token == rule_token:
                    continue
                if token.startswith(rule_token):
                    rows.append(f"{node['id']}\t{token}\tprefix={rule_token}")
Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\prefix_token_hits.txt").write_text(
    "\n".join(rows), encoding="utf-8")
print("hits", len(rows))
print("\n".join(rows[:80]))
