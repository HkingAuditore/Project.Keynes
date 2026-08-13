#!/usr/bin/env python3
"""Audit technology reveal conditions against node identity/role."""
from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(r"d:\Godot\ProjectKeynes\Project.Keynes")
NET = ROOT / "Project/project-keynes/data/technology/technology_network.json"

KIND = {0: "TECH_COMPLETED", 1: "SIGNAL_PRESENT", 2: "SIGNAL_COUNT"}
OP = {0: "ATOM", 1: "ALL_OF", 2: "ANY_OF", 3: "AT_LEAST", 4: "NONE_OF", 5: "NOT"}

SEMANTIC_RULES = [
    (["cotton"], ["bio.cotton", "contact.cotton"]),
    (["flax", "fiber", "weaving", "loom", "spinning", "textile"],
     ["bio.flax", "bio.cotton", "contact.flax"]),
    (["spice"], ["bio.spice", "contact.spice", "resource.plantation_land"]),
    (["rubber", "latex"], ["bio.rubber", "contact.rubber", "landform.forest"]),
    (["maize"], ["bio.maize", "contact.maize", "breakthrough.maize_selection"]),
    (["wheat", "grain", "cereal", "rainfed", "dryland"],
     ["bio.wheat", "contact.wheat", "breakthrough.rainfed_adaptation"]),
    (["rice", "paddy"], ["bio.rice", "contact.rice", "breakthrough.paddy_control"]),
    (["potato", "tuber", "terrace", "highland"],
     ["bio.potato", "contact.potato", "breakthrough.terrace_maintenance"]),
    (["horse", "pastoral", "livestock", "herd", "wool", "dairy", "meat"],
     ["resource.pasture", "landform.grassland", "bio.horse"]),
    (["hide", "leather", "fur", "hunting", "animal"],
     ["resource.wild_game", "bio.sheep", "landform.grassland"]),
    (["forest", "timber", "wood", "lumber", "paper", "bark", "charcoal"],
     ["resource.timber", "landform.forest", "breakthrough.forest_management"]),
    (["fish", "fishing"],
     ["resource.freshwater_fish", "resource.marine_fish", "landform.coast"]),
    (["maritime", "ocean", "ship", "port", "navigation", "logistics", "coast"],
     ["landform.coast", "resource.marine_fish", "breakthrough.maritime_operations"]),
    (["clay", "pottery", "kiln", "brick", "adobe"],
     ["resource.clay", "resource.silica_sand", "breakthrough.kiln_temperature"]),
    (["flint", "stone", "masonry", "earth", "construction", "cement", "concrete"],
     ["resource.stone", "resource.flint", "resource.clay"]),
    (["glass", "silica"],
     ["resource.silica_sand", "resource.limestone", "breakthrough.kiln_temperature"]),
    (["copper"], ["resource.copper_ore", "resource.tin_ore", "breakthrough.metalworking"]),
    (["tin"], ["resource.tin_ore", "contact.tin", "breakthrough.metalworking"]),
    (["bronze", "alloy", "metallurgy", "metal"],
     ["resource.copper_ore", "resource.tin_ore", "breakthrough.metalworking"]),
    (["iron", "steel", "coal", "mine", "mining", "shaft"],
     ["resource.iron_ore", "resource.coal", "breakthrough.mine_support"]),
    (["gold", "silver"],
     ["resource.gold_ore", "resource.silver_ore", "landform.freshwater_access"]),
    (["salt"], ["resource.salt", "resource.saltpeter", "resource.sulfur"]),
    (["sulfur", "phosphate", "fertilizer", "gunpowder", "explosive", "chemistry", "chemical"],
     ["resource.sulfur", "resource.phosphate_rock", "resource.saltpeter"]),
    (["oil", "petroleum", "fuel", "combustion", "gas", "plastic", "synthetic"],
     ["resource.oil", "resource.natural_gas", "resource.coal"]),
    (["irrigation", "hydraulic", "canal", "water", "hydro", "watershed"],
     ["landform.freshwater_access", "landform.river_valley", "breakthrough.hydraulic_engineering"]),
    (["wind"],
     ["landform.stable_wind_corridor", "landform.freshwater_access", "breakthrough.hydraulic_engineering"]),
]

# Subject expected for identification / named crop-or-ore techs.
SUBJECT_BY_TOKEN = {
    "cotton": {"bio.cotton", "contact.cotton"},
    "flax": {"bio.flax", "contact.flax", "bio.bast_fiber"},
    "spice": {"bio.spice", "contact.spice"},
    "rubber": {"bio.rubber", "contact.rubber"},
    "latex": {"bio.rubber", "contact.rubber"},
    "maize": {"bio.maize", "contact.maize"},
    "wheat": {"bio.wheat", "contact.wheat"},
    "rice": {"bio.rice", "contact.rice"},
    "potato": {"bio.potato", "contact.potato"},
    "tuber": {"bio.potato", "contact.potato"},
    "copper": {"resource.copper_ore"},
    "tin": {"resource.tin_ore", "contact.tin"},
    "iron": {"resource.iron_ore"},
    "coal": {"resource.coal"},
    "gold": {"resource.gold_ore"},
    "silver": {"resource.silver_ore"},
    "salt": {"resource.salt"},
    "clay": {"resource.clay"},
    "timber": {"resource.timber"},
    "fish": {"resource.freshwater_fish", "resource.marine_fish"},
}

LAND_CAPACITY = {
    "resource.plantation_land", "resource.arable_land", "resource.paddy_land",
    "resource.pasture", "resource.fertile_soil",
}

CROSS_SPECIES = {
    ("cotton", "bio.flax"), ("cotton", "bio.spice"), ("cotton", "bio.rubber"),
    ("flax", "bio.cotton"), ("spice", "bio.cotton"), ("maize", "bio.wheat"),
    ("wheat", "bio.maize"), ("wheat", "bio.rice"), ("rice", "bio.wheat"),
    ("copper", "resource.tin_ore"), ("tin", "resource.copper_ore"),
    ("iron", "resource.coal"), ("coal", "resource.iron_ore"),
}


def collect_signals(spec, out):
    if not spec:
        return
    if "kind" in spec:
        kind = int(spec.get("kind", -1))
        if kind in (1, 2):
            sid = spec.get("id", "")
            if sid and sid not in out:
                out.append(sid)
        return
    for child in spec.get("children", []) or []:
        if isinstance(child, dict):
            collect_signals(child, out)


def collect_techs(spec, out):
    if not spec:
        return
    if "kind" in spec:
        if int(spec.get("kind", -1)) == 0:
            tid = spec.get("id", "")
            if tid and tid not in out:
                out.append(tid)
        return
    for child in spec.get("children", []) or []:
        if isinstance(child, dict):
            collect_techs(child, out)


def source_tokens(node):
    hay = " ".join([
        node.get("id", ""),
        node.get("display_name", ""),
        node.get("effect_profile", ""),
        " ".join(node.get("secondary_route_tags", []) or []),
        node.get("main_lane", ""),
    ]).lower()
    return hay.replace(".", " ").replace("-", " ").replace("_", " ")


def matching_rule(node):
    hay = source_tokens(node)
    tokens = set(hay.split())
    for rule_tokens, signals in SEMANTIC_RULES:
        for tok in rule_tokens:
            if (len(tok) <= 3 and tok in tokens) or (len(tok) > 3 and tok in hay):
                return tok, signals
    return None, None


def signal_kind(sid):
    return sid.split(".", 1)[0] if "." in sid else sid


def main():
    data = json.loads(NET.read_text(encoding="utf-8"))
    nodes = data["nodes"]
    findings = defaultdict(list)
    signal_freq = Counter()
    triple_freq = Counter()
    role_counts = Counter()
    era_issue = Counter()
    source_kind_counts = Counter()
    empty_reveal = 0
    researchable = 0

    identification = []
    for node in nodes:
        if node.get("is_milestone") or node.get("is_starting"):
            continue
        researchable += 1
        spec = node.get("reveal_condition") or {}
        signals = []
        techs = []
        collect_signals(spec, signals)
        collect_techs(spec, techs)
        role = node.get("node_role", "")
        role_counts[role] += 1
        for s in signals:
            signal_freq[s] += 1
            source_kind_counts[signal_kind(s)] += 1
        if signals:
            triple_freq[tuple(sorted(signals))] += 1
        if not spec:
            empty_reveal += 1
            continue

        nid = node["id"]
        name = node.get("display_name", nid)
        era = node.get("era_id", "")
        lane = node.get("main_lane", "")
        profile = node.get("effect_profile", "")
        rec = {
            "id": nid,
            "name": name,
            "era": era,
            "lane": lane,
            "role": role,
            "profile": profile,
            "signals": signals,
            "techs": techs,
        }

        matched_token, rule_signals = matching_rule(node)
        if rule_signals and list(signals) == list(rule_signals):
            rec["generated_by"] = f"token:{matched_token}"
        elif set(signals) == set(rule_signals or []) and rule_signals:
            rec["generated_by"] = f"token:{matched_token}"
        else:
            rec["generated_by"] = "explicit_or_lane"

        # 1. identification / named-subject vs unrelated land capacity
        if role == "identification":
            identification.append(rec)
            if LAND_CAPACITY & set(signals):
                findings["land_capacity_on_identification"].append(rec)
                era_issue[era] += 1

        # 2. token overmatch: rule signals contain a species the node isn't about
        hay = source_tokens(node)
        for token, expected in SUBJECT_BY_TOKEN.items():
            if token not in hay:
                continue
            extras = [s for s in signals if s.startswith("bio.") or s.startswith("resource.") or s.startswith("contact.")]
            foreign = [s for s in extras if s not in expected and not (
                s.startswith("resource.") and token in s
            )]
            # only flag if this token is the primary subject (in id)
            if token.replace("_", "") in nid.replace("_", "") or f".{token}" in nid or f"_{token}" in nid:
                if foreign:
                    rec2 = dict(rec)
                    rec2["foreign"] = foreign
                    rec2["subject_token"] = token
                    findings["foreign_subject_signal"].append(rec2)
                    era_issue[era] += 1
                break

        # 3. chicken-egg: identification revealed by a practice breakthrough
        if role == "identification" and any(s.startswith("breakthrough.") for s in signals):
            findings["identification_via_breakthrough"].append(rec)
            era_issue[era] += 1

        # 4. flax/textile rule contaminating non-flax techs with bio.cotton AND bio.flax
        if "bio.flax" in signals and "bio.cotton" in signals:
            if "cotton" not in nid and "flax" not in nid:
                findings["fiber_token_overmatch"].append(rec)
                era_issue[era] += 1
            elif ("cotton" in nid and "flax" not in nid) or ("flax" in nid and "cotton" not in nid):
                findings["fiber_cross_species"].append(rec)
                era_issue[era] += 1

        # 5. copper revealed by tin, iron by coal, etc.
        if "copper" in nid and "tin" not in nid and "resource.tin_ore" in signals:
            findings["ore_proxy_swap"].append(rec)
            era_issue[era] += 1
        if re.search(r"(iron|steel)", nid) and "coal" not in nid and "resource.coal" in signals and role in (
            "identification", "handling"
        ):
            findings["ore_proxy_swap"].append(rec)
            era_issue[era] += 1

        # 6. generic late knowledge dump
        if set(signals) >= {"breakthrough.digital_control", "breakthrough.automation", "resource.rare_earth"} \
                or set(signals) >= {"breakthrough.electrification", "breakthrough.automation", "resource.rare_earth"}:
            if "rare" not in nid and "digital" not in nid and "automat" not in nid:
                findings["generic_knowledge_dump"].append(rec)
                era_issue[era] += 1

        # 7. observation/science using weather monsoon/frost/river as if it were natural observation
        if profile in ("observation",) and role == "identification":
            weather_geo = [s for s in signals if s.startswith("weather.") or s.startswith("landform.")]
            if weather_geo and not any(s.startswith("bio.") or s.startswith("resource.") for s in signals):
                findings["generic_observation_geo"].append(rec)

        # 8. spice still using plantation as species proxy
        if role == "identification" and "spice" in nid and "resource.plantation_land" in signals:
            findings["land_capacity_on_identification"].append(rec)

        # 9. hunting/hide using sheep as if wild game
        if any(k in nid for k in ("hunting", "hide", "fur", "leather")) and "bio.sheep" in signals:
            findings["livestock_as_wild_game"].append(rec)
            era_issue[era] += 1

        # 10. maritime ops revealed by marine_fish
        if any(k in nid for k in ("ship", "port", "navigation", "cartography")) and "resource.marine_fish" in signals:
            findings["fish_as_maritime_proxy"].append(rec)
            era_issue[era] += 1

        # 11. printing/paper revealed only by timber/forest
        if any(k in nid for k in ("print", "paper", "writing", "manuscript")) and "resource.timber" in signals:
            findings["timber_as_literacy_proxy"].append(rec)

        # 12. rainfed/dryland token matching non-wheat techs
        if matched_token in ("rainfed", "dryland", "grain", "cereal") and "wheat" not in nid and "bio.wheat" in signals:
            findings["wheat_token_overmatch"].append(rec)
            era_issue[era] += 1

        # 13. mine_support on every iron/coal/steel/shaft tech including non-mining
        if "breakthrough.mine_support" in signals and "mine" not in nid and "shaft" not in nid and "coal" not in nid:
            findings["mine_support_overmatch"].append(rec)

        # 14. kiln_temperature on clay/pottery AND glass AND brick - maybe ok; flag adobe/earth
        if "breakthrough.kiln_temperature" in signals and any(k in nid for k in ("adobe", "earth_building")):
            findings["kiln_on_unfired_earth"].append(rec)

        # 15. same cloned triple used by many roles
        rec["signal_set"] = tuple(sorted(signals))

    # cloned triples across roles
    by_triple = defaultdict(list)
    for node in nodes:
        if node.get("is_milestone") or node.get("is_starting"):
            continue
        signals = []
        collect_signals(node.get("reveal_condition") or {}, signals)
        if len(signals) >= 2:
            by_triple[tuple(sorted(signals))].append({
                "id": node["id"],
                "name": node.get("display_name"),
                "role": node.get("node_role"),
                "era": node.get("era_id"),
            })
    cloned = []
    for triple, members in by_triple.items():
        roles = {m["role"] for m in members}
        if len(members) >= 4 and len(roles) >= 2:
            cloned.append({
                "signals": list(triple),
                "count": len(members),
                "roles": sorted(roles),
                "examples": members[:8],
            })
    cloned.sort(key=lambda x: -x["count"])

    # identification inventory
    ident_rows = []
    for rec in identification:
        ident_rows.append({
            "id": rec["id"],
            "name": rec["name"],
            "era": rec["era"],
            "signals": rec["signals"],
            "generated_by": rec.get("generated_by", ""),
        })

    # unique finding ids
    for key, rows in list(findings.items()):
        seen = set()
        uniq = []
        for row in rows:
            if row["id"] in seen:
                continue
            seen.add(row["id"])
            uniq.append(row)
        findings[key] = uniq

    summary = {
        "researchable": researchable,
        "empty_reveal": empty_reveal,
        "identification_count": len(identification),
        "finding_counts": {k: len(v) for k, v in findings.items()},
        "top_signals": signal_freq.most_common(20),
        "source_kinds": source_kind_counts.most_common(),
        "role_counts": role_counts.most_common(),
        "cloned_triples": cloned[:12],
        "ident_rows": ident_rows,
        "findings": {
            k: [
                {
                    "id": r["id"],
                    "name": r["name"],
                    "era": r["era"],
                    "role": r["role"],
                    "signals": r["signals"],
                    "foreign": r.get("foreign", []),
                    "generated_by": r.get("generated_by", ""),
                }
                for r in v
            ]
            for k, v in findings.items()
        },
    }
    out = ROOT / "tmp/reveal_condition_audit.json"
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print("researchable", researchable)
    print("empty_reveal", empty_reveal)
    print("identification", len(identification))
    print("finding_counts", summary["finding_counts"])
    print("top_signals", summary["top_signals"][:10])
    print("cloned", [(c["count"], c["signals"]) for c in cloned[:8]])
    print("wrote", out)


if __name__ == "__main__":
    main()
