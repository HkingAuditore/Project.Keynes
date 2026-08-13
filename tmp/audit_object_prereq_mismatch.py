#!/usr/bin/env python3
"""Scan technology_network.json for cotton-gardening-class mismatches.

Reveal conditions name the observed object; hard prerequisites must be the
knowledge chain for that object, not a same-lane sibling of a disjoint object.
"""
from __future__ import annotations

import json
import re
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NETWORK = ROOT / "Project/project-keynes/data/technology/technology_network.json"
OUT = ROOT / "tmp/object_prereq_mismatch.json"

ERA_ORDER = [
    "stone", "agrarian", "kingdom", "empire", "exploration",
    "enlightenment", "steam", "electrical", "atomic", "information", "intelligent",
]

# Canonical object families. A node "owns" a family if its reveal signals
# or stable ID clearly belong to that family. Shared/generic families are
# excluded from mismatch scoring when they are the only overlap.
OBJECT_ALIASES = {
    "maize": "maize",
    "wheat": "wheat",
    "rice": "rice",
    "potato": "potato",
    "tuber": "potato",
    "cotton": "cotton",
    "flax": "flax",
    "bast_fiber": "flax",
    "spice": "spice",
    "rubber": "rubber",
    "latex": "rubber",
    "clay": "clay",
    "copper_ore": "copper",
    "copper": "copper",
    "tin_ore": "tin",
    "tin": "tin",
    "iron_ore": "iron",
    "iron": "iron",
    "coal": "coal",
    "salt": "salt",
    "sulfur": "sulfur",
    "gold": "gold",
    "silver": "silver",
    "precious": "precious",
    "flint": "flint",
    "timber": "timber",
    "silica_sand": "silica",
    "limestone": "limestone",
    "phosphate": "phosphate",
    "oil": "oil",
    "natural_gas": "gas",
    "bauxite": "bauxite",
    "rare_earth": "rare_earth",
    "lead": "lead",
    "zinc": "zinc",
    "manganese": "manganese",
    "sheep": "sheep",
    "cattle": "cattle",
    "cow": "cattle",
    "horse": "horse",
    "freshwater_fish": "freshwater_fish",
    "marine_fish": "marine_fish",
    "wild_game": "game",
    "reed": "reed",
    "wool": "sheep",
}

GENERIC_OBJECTS = {
    "fertile_soil", "arable_land", "paddy_land", "plantation_land", "pasture",
    "timber",  # too common as fuel/construction; still used for forestry nodes
}

KNOWLEDGE_ROLES = {
    "identification", "handling", "production_system", "applied_method",
}

SKIP_ANCHOR = {"route_anchor", "backbone_anchor", "milestone"}

ID_OBJECT_RE = re.compile(
    r"(maize|wheat|rice|potato|tuber|cotton|flax|spice|rubber|latex|"
    r"clay|copper|tin|iron|coal|salt|gold|silver|flint|reed|"
    r"sheep|cattle|horse|wool|oil|bauxite|phosphate|limestone|"
    r"silica|sulfur|lead|zinc|manganese)"
)


def collect_signals(spec, out: set[str]) -> None:
    if not isinstance(spec, dict) or not spec:
        return
    sid = str(spec.get("id") or "")
    if sid:
        out.add(sid)
    for child in spec.get("children") or []:
        collect_signals(child, out)


def object_from_signal(sid: str) -> str | None:
    for prefix in ("bio.", "resource.", "contact."):
        if sid.startswith(prefix):
            stem = sid[len(prefix):]
            return OBJECT_ALIASES.get(stem, stem)
    return None


def objects_of(node: dict) -> set[str]:
    sigs: set[str] = set()
    collect_signals(node.get("reveal_condition") or {}, sigs)
    objs = set()
    for sid in sigs:
        obj = object_from_signal(sid)
        if obj:
            objs.add(obj)
    # ID token as fallback only when reveal has no object signal.
    if not objs:
        for match in ID_OBJECT_RE.finditer(str(node.get("id") or "")):
            objs.add(OBJECT_ALIASES.get(match.group(1), match.group(1)))
    return objs


def specific_objects(objs: set[str]) -> set[str]:
    return {o for o in objs if o not in GENERIC_OBJECTS and not o.startswith(("landform", "weather", "breakthrough"))}


def main() -> None:
    data = json.loads(NETWORK.read_text(encoding="utf-8"), strict=False)
    nodes = data["nodes"]
    by_id = {n["id"]: n for n in nodes}
    hard_of = {n["id"]: list(n.get("hard_prerequisite_ids") or []) for n in nodes}
    era_index = {e: i for i, e in enumerate(ERA_ORDER)}

    obj_map = {n["id"]: objects_of(n) for n in nodes}

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

    # Index earlier same-object knowledge nodes.
    knowledge_by_obj: dict[str, list[str]] = defaultdict(list)
    for n in nodes:
        role = str(n.get("node_role") or "")
        if role not in KNOWLEDGE_ROLES:
            continue
        if n.get("is_milestone") or n.get("is_starting"):
            continue
        for obj in specific_objects(obj_map[n["id"]]):
            knowledge_by_obj[obj].append(n["id"])
    for obj in knowledge_by_obj:
        knowledge_by_obj[obj].sort(key=lambda tid: int(by_id[tid]["layout_order"]))

    same_lane_disjoint = []
    missing_own_chain = []
    wrong_ident = []
    ident_empty_ok = []

    for n in nodes:
        nid = n["id"]
        if n.get("is_starting") or n.get("is_milestone"):
            continue
        nobjs = specific_objects(obj_map[nid])
        if not nobjs:
            continue
        hard = hard_of[nid]
        cl = closure(nid)
        layout = int(n["layout_order"])
        role = str(n.get("node_role") or "")
        anchor = str(n.get("anchor_kind") or "")

        # 1) same-lane disjoint-object hard prereq (generator chain artifact)
        for hid in hard:
            h = by_id[hid]
            if h.get("is_milestone"):
                continue
            if h.get("main_lane") != n.get("main_lane"):
                continue
            hobjs = specific_objects(obj_map[hid])
            if not hobjs:
                continue
            if nobjs.isdisjoint(hobjs):
                same_lane_disjoint.append({
                    "id": nid,
                    "name": n.get("display_name"),
                    "era": n["era_id"],
                    "role": role,
                    "anchor": anchor,
                    "lane": n.get("main_lane"),
                    "layout": layout,
                    "objs": sorted(nobjs),
                    "prereq": hid,
                    "prereq_name": h.get("display_name"),
                    "prereq_role": h.get("node_role"),
                    "prereq_anchor": h.get("anchor_kind"),
                    "prereq_objs": sorted(hobjs),
                    "prereq_layout": int(h["layout_order"]),
                    "hard": [by_id[x]["display_name"] for x in hard],
                })

        # 2) wrong-object identification as hard prereq
        for hid in hard:
            h = by_id[hid]
            if h.get("node_role") != "identification":
                continue
            hobjs = specific_objects(obj_map[hid])
            if hobjs and nobjs.isdisjoint(hobjs):
                wrong_ident.append({
                    "id": nid,
                    "name": n.get("display_name"),
                    "objs": sorted(nobjs),
                    "ident": hid,
                    "ident_name": h.get("display_name"),
                    "ident_objs": sorted(hobjs),
                })

        # 3) own-object earlier knowledge exists but is not in hard/closure;
        #    skip route/backbone anchors (two slots already used by era gate).
        if anchor in SKIP_ANCHOR:
            continue
        if role not in KNOWLEDGE_ROLES:
            continue
        candidates = []
        for obj in nobjs:
            for kid in knowledge_by_obj.get(obj, []):
                if kid == nid:
                    continue
                kn = by_id[kid]
                if int(kn["layout_order"]) >= layout:
                    continue
                if era_index[kn["era_id"]] > era_index[n["era_id"]]:
                    continue
                # Prefer immediate same-object predecessor of a "lower" role:
                # identification < handling < applied/production.
                candidates.append(kid)
        own_in_graph = [kid for kid in candidates if kid in hard or kid in cl]
        nearest = None
        if candidates:
            # nearest earlier same-object node by layout
            nearest = max(candidates, key=lambda tid: int(by_id[tid]["layout_order"]))
        if nearest and nearest not in hard and nearest not in cl:
            # If a same-object node is already a direct hard prereq, skip.
            if own_in_graph:
                continue
            missing_own_chain.append({
                "id": nid,
                "name": n.get("display_name"),
                "era": n["era_id"],
                "role": role,
                "anchor": anchor,
                "lane": n.get("main_lane"),
                "layout": layout,
                "objs": sorted(nobjs),
                "hard": [
                    f"{by_id[x]['display_name']} ({x})" for x in hard
                ],
                "nearest_own": f"{by_id[nearest]['display_name']} ({nearest})",
                "nearest_own_role": by_id[nearest].get("node_role"),
                "nearest_own_era": by_id[nearest]["era_id"],
                "nearest_own_layout": int(by_id[nearest]["layout_order"]),
                "hard_count": len(hard),
            })

    # Crop/mineral designed chains: ident -> first handling/collection -> later same-object
    families = {
        "maize": ["tech.maize_identification"],
        "wheat": ["tech.wheat_identification"],
        "rice": ["tech.rice_identification"],
        "potato": ["tech.potato_identification"],
        "cotton": ["tech.cotton_identification"],
        "flax": ["tech.flax_identification"],
        "spice": ["tech.spice_identification"],
        "rubber": ["tech.rubber_identification"],
        "clay": ["tech.clay_identification"],
        "copper": ["tech.natural_copper_identification"],
        "tin": ["tech.tin_identification"],
        "iron": ["tech.iron_ore_identification"],
        "coal": ["tech.coal_outcrop_identification"],
        "gold": ["tech.gold_identification"] if "tech.gold_identification" in by_id else [],
        "silver": ["tech.silver_identification"] if "tech.silver_identification" in by_id else [],
        "flint": ["tech.flint_identification"] if "tech.flint_identification" in by_id else [],
        "salt": ["tech.salt_identification"] if "tech.salt_identification" in by_id else [],
        "reed": ["tech.reed_identification"] if "tech.reed_identification" in by_id else [],
        "sheep": ["tech.sheep_identification"] if "tech.sheep_identification" in by_id else [],
    }

    family_first_handling = []
    for n in nodes:
        if n.get("is_starting") or n.get("is_milestone"):
            continue
        if str(n.get("anchor_kind") or "") in SKIP_ANCHOR:
            continue
        role = str(n.get("node_role") or "")
        if role not in ("handling", "applied_method", "production_system"):
            continue
        nobjs = specific_objects(obj_map[n["id"]])
        if len(nobjs) != 1:
            continue  # multi-object nodes are shared methods
        obj = next(iter(nobjs))
        idents = families.get(obj) or []
        if not idents:
            continue
        ident = idents[0]
        if ident not in by_id:
            continue
        if int(by_id[ident]["layout_order"]) >= int(n["layout_order"]):
            continue
        cl = closure(n["id"])
        hard = hard_of[n["id"]]
        if ident in hard or ident in cl:
            continue
        family_first_handling.append({
            "id": n["id"],
            "name": n.get("display_name"),
            "era": n["era_id"],
            "role": role,
            "anchor": n.get("anchor_kind"),
            "lane": n.get("main_lane"),
            "obj": obj,
            "hard": [f"{by_id[x]['display_name']} ({x})" for x in hard],
            "missing_ident": ident,
            "layout": int(n["layout_order"]),
            "ident_layout": int(by_id[ident]["layout_order"]),
        })

    # Print compact review tables
    def fmt_row(r, keys):
        return " | ".join(str(r.get(k, "")) for k in keys)

    print("=== SAME-LANE DISJOINT OBJECT (all eras) ===")
    print(f"count={len(same_lane_disjoint)}")
    for r in sorted(same_lane_disjoint, key=lambda x: (ERA_ORDER.index(x["era"]), x["layout"])):
        print(
            f"[{r['era']:14}] {r['anchor']:8} {r['name']:18} <- {r['prereq_name']:18} "
            f"objs {r['objs']} vs {r['prereq_objs']}  hard={r['hard']}"
        )

    print("\n=== MISSING OWN-OBJECT CHAIN (support knowledge nodes) ===")
    print(f"count={len(missing_own_chain)}")
    for r in sorted(missing_own_chain, key=lambda x: (ERA_ORDER.index(x["era"]), x["layout"])):
        print(
            f"[{r['era']:14}] {r['role']:18} {r['name']:18} hard={r['hard']} "
            f"nearest={r['nearest_own']} objs={r['objs']}"
        )

    print("\n=== WRONG-OBJECT IDENTIFICATION PREREQ ===")
    print(f"count={len(wrong_ident)}")
    for r in wrong_ident:
        print(f"{r['name']} objs={r['objs']} <- {r['ident_name']} {r['ident_objs']}")

    print("\n=== SINGLE-OBJECT NODE MISSING IDENT IN CLOSURE ===")
    print(f"count={len(family_first_handling)}")
    for r in sorted(family_first_handling, key=lambda x: (ERA_ORDER.index(x["era"]), x["layout"])):
        print(
            f"[{r['era']:14}] {r['name']:22} obj={r['obj']:10} hard={r['hard']}"
        )

    payload = {
        "same_lane_disjoint": same_lane_disjoint,
        "missing_own_chain": missing_own_chain,
        "wrong_ident": wrong_ident,
        "family_first_handling": family_first_handling,
    }
    OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nwrote {OUT}")


if __name__ == "__main__":
    main()
