# -*- coding: utf-8 -*-
import json
from pathlib import Path

d = json.loads(Path("tmp/reveal_habitat_audit.json").read_text(encoding="utf-8"))
empty = [r for r in d["bypass"] if not r["hard"]]
gated = [r for r in d["bypass"] if r["hard"]]
print("BYPASS", d["bypass_count"], "empty_hard", len(empty), "has_hard", len(gated))
print("EMPTY")
for r in empty:
    print(r["era"], r["id"], r["name"], "start", int(r["starting"]), "proxy", r["habitats"], "obj", r["objects"])
print("GATED")
for r in gated:
    print(r["era"], r["id"], r["name"], "hard", r["hard"], "proxy", r["habitats"])
print("HORSE")
for r in d["horse_pack"]:
    print(r["era"], r["id"], r["name"], r["pack"], "hard", r["hard"])
print("HIDE_SHEEP")
for r in d["hide_sheep_pack"]:
    print(r["era"], r["id"], r["name"], r["pack"])
print("CROSS")
for r in d["cross_species"]:
    print(r["era"], r["id"], "expected", r["expected"], "extras", r["extras"], "miss", r.get("missing_expected", False))
print("CLONED")
for r in d["cloned"]:
    print(r["n"], r["pack"], r["users"][:5])
