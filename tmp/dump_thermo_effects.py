#!/usr/bin/env python3
import json
from collections import defaultdict
from pathlib import Path

data = json.loads(Path("Project/project-keynes/data/technology/technology_network.json").read_text(encoding="utf-8"), strict=False)
by = {n["id"]: n for n in data["nodes"]}

ids = [
    "tech.thermodynamics", "tech.experimental_science", "tech.industrial_research",
    "tech.machine_tools", "tech.factory_system", "tech.industrial_organization",
    "tech.steam_power", "tech.steam_sealing", "tech.atmospheric_engine",
    "tech.steam_pumping", "tech.natural_philosophy", "tech.precision_instruments",
]
print("=== comparison ===")
for i in ids:
    n = by.get(i)
    if not n:
        print("MISSING", i)
        continue
    terms = n.get("modifier_terms") or []
    ttxt = "; ".join(f"{t.get('subject_display_name') or t.get('stat')} {t.get('operation')} {t.get('value')}" for t in terms)
    binds = [f"{b.get('kind')}:{b.get('id')}" for b in (n.get("expected_bindings") or [])]
    print(f"{n['era_id']:14} {n.get('anchor_kind',''):16} {n['cost_points']:8} {n['display_name']:12} profile={n.get('effect_profile'):12} binds={binds or '-'} | {ttxt}")

print("\n=== family stacks ===")
fam = defaultdict(float)
broad = defaultdict(float)
for n in data["nodes"]:
    for t in n.get("modifier_terms") or []:
        stat = t.get("stat") or ""
        val = float(t.get("value") or 0)
        if t.get("operation") != 0:
            continue
        if stat.startswith("country.output.family."):
            fam[stat] += val
        elif any(stat.startswith(p) for p in (
            "country.output.agriculture_factor", "country.output.extractive_factor",
            "country.output.manufacturing_factor", "country.output.energy_factor",
            "country.output.knowledge_factor", "country.research.", "country.trade.")):
            broad[stat] += val
print("families near cap:")
for k, v in sorted(fam.items(), key=lambda kv: -kv[1])[:15]:
    print(f"  {v:.3f} {k}")
print("broad:")
for k, v in sorted(broad.items(), key=lambda kv: -kv[1]):
    print(f"  {v:.3f} {k}")

print("\n=== steam buildings with steam/heat/engine/boiler/lab ===")
# peek content_effects / bindings containing steam
for n in data["nodes"]:
    if n["era_id"] not in ("enlightenment", "steam"):
        continue
    blob = json.dumps(n.get("expected_bindings") or [], ensure_ascii=False)
    if any(s in blob for s in ("steam", "boiler", "engine", "heat", "lab", "research")):
        print(f"  {n['id']:42} {n['display_name']:16} {blob[:180]}")
