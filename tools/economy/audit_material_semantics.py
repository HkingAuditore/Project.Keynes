# -*- coding: utf-8 -*-
"""Read-only material-semantics audit for the modern economy content.

The 2026-11-28 manuscript fix came from one defect class: a raw material is
turned into a finished good directly while the same material also makes the
intermediate that a *competing* finished good is built from.  This script looks
for that class and its neighbours across the whole catalog.

Input slots are expanded the way the runtime expands them: an exact good is one
material, an explicit candidate list is its own set, and a category slot accepts
every good that carries that category.  A slot that only accepts food is the
strongest signal; a food good that merely leads a list with non-food
alternatives is reported separately.

Checks:
  food    a hard input slot whose materials are all household food
          ("gathered_plants -> cloth" class)
  feed    a food good used as feed/agent in a soft slot or as a small additive
  bypass  material M makes C directly, M also makes intermediate A, A feeds D,
          C competes with D in the same need, and C's producers do not accept A
          ("hide -> paper / hide -> manuscripts" class)
  twins   two non-extraction buildings with the same accepted hard materials and
          a similar output rate but different products
  era     no accepted hard material is producible by the building's effective
          unlock era
  claim   a good's own technology tags open its availability gate in an earlier
          era than any building can produce it
  ghost   a hard input, or a household component, has no producer building
  ratio   hard-input value / output value outside 30%-90%, excluding extraction
          and technology_points producers
  cycle   a building consumes its own output as a hard input
  prefer  the declared primary material is at least twice as expensive per
          effective unit as an alternative that already exists in the
          building's own era

Usage:
    python tools/economy/audit_material_semantics.py
    python tools/economy/audit_material_semantics.py --json out.json
    python tools/economy/audit_material_semantics.py --only food,bypass
"""
import argparse
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJ = os.path.join(ROOT, "Project", "project-keynes")
GOODS_DIR = os.path.join(PROJ, "data", "goods")
BUILDINGS_DIR = os.path.join(PROJ, "data", "economy", "buildings")
PLANS_DIR = os.path.join(PROJ, "data", "economy", "consumption_plans")
TECH_NETWORK = os.path.join(PROJ, "data", "technology", "technology_network.json")

Q16_ONE = 65536
GOODS_SCALE = 1000.0
FOOD_NEEDS = {"staple_food", "protein", "produce", "food_fat", "seasoning"}
CALORIE_NEEDS = {"staple_food", "protein", "produce"}
DRINK_GOODS = {"beverages"}


def _str_field(txt, key, default=""):
    m = re.search(rf'^{re.escape(key)}\s*=\s*(?:&)?"([^"]*)"', txt, re.M)
    return m.group(1) if m else default


def _int_field(txt, key, default=0):
    m = re.search(rf'^{re.escape(key)}\s*=\s*(-?\d+)', txt, re.M)
    return int(m.group(1)) if m else default


def _str_array(txt, key):
    m = re.search(rf'^{re.escape(key)}\s*=\s*PackedStringArray\(([^)]*)\)', txt, re.M)
    if not m or not m.group(1).strip():
        return []
    return re.findall(r'"([^"]*)"', m.group(1))


def _num_array(txt, key):
    m = re.search(rf'^{re.escape(key)}\s*=\s*PackedInt(?:32|64)Array\(([^)]*)\)', txt, re.M)
    if not m or not m.group(1).strip():
        return []
    return [int(x) for x in re.findall(r"-?\d+", m.group(1))]


def load_goods():
    goods = {}
    for path in sorted(glob.glob(os.path.join(GOODS_DIR, "*.tres"))):
        txt = open(path, encoding="utf-8").read()
        gid = _str_field(txt, "id", os.path.splitext(os.path.basename(path))[0])
        goods[gid] = {
            "id": gid,
            "path": os.path.relpath(path, ROOT).replace("\\", "/"),
            "name": _str_field(txt, "display_name", gid),
            "category": _str_field(txt, "category_id"),
            "subs": _str_array(txt, "substitution_category_ids"),
            "tech_tags": _str_array(txt, "technology_tags"),
            # GoodProfile.default_price defaults to 10000; an absent field is
            # authored content, not a free good.
            "price": float(_int_field(txt, "default_price", 10000)),
            "quality": _int_field(txt, "production_quality_level", 0),
        }
    return goods


def load_tech_eras():
    with open(TECH_NETWORK, encoding="utf-8") as handle:
        network = json.load(handle)
    eras = [str(row.get("id", "")) for row in network.get("eras", [])]
    nodes = {str(node.get("id", "")): str(node.get("era_id", ""))
             for node in network.get("nodes", [])}
    return nodes, eras


def _era_of_tags(tags, tech_eras, eras, default=0):
    best = len(eras)
    for tag in tags:
        if tag in tech_eras and tech_eras[tag] in eras:
            best = min(best, eras.index(tech_eras[tag]))
    return best if best < len(eras) else default


def load_buildings(tech_eras, eras):
    buildings = []
    for path in sorted(glob.glob(os.path.join(BUILDINGS_DIR, "*.tres"))):
        txt = open(path, encoding="utf-8").read()
        bid = _str_field(txt, "id", os.path.splitext(os.path.basename(path))[0])
        in_goods = _str_array(txt, "input_good_ids")
        in_req = _num_array(txt, "input_required_q16")
        if not in_req and in_goods:
            in_req = [Q16_ONE] * len(in_goods)
        tech_tags = _str_array(txt, "technology_tags")
        required_tags = _str_array(txt, "required_technology_tags")
        direct_era_idx = _era_of_tags(tech_tags, tech_eras, eras)
        effective_era_idx = direct_era_idx
        for tag in required_tags:
            if tag in tech_eras and tech_eras[tag] in eras:
                effective_era_idx = max(effective_era_idx, eras.index(tech_eras[tag]))
        building = {
            "id": bid,
            "path": os.path.relpath(path, ROOT).replace("\\", "/"),
            "name": _str_field(txt, "display_name", bid),
            "kind": _str_field(txt, "building_kind", "industrial"),
            "sector": _str_field(txt, "economic_sector_id", ""),
            "state_role": _str_field(txt, "state_role", "none"),
            "chain": _str_field(txt, "industry_chain_id", ""),
            "owner": _str_field(txt, "owner_profession_id", ""),
            "era": eras[direct_era_idx] if eras else "",
            "era_idx": effective_era_idx,
            "effective_era": eras[effective_era_idx] if eras else "",
            "in_goods": in_goods,
            "in_qty": _num_array(txt, "input_quantities_per_day"),
            "in_req": in_req,
            "in_cats": _str_array(txt, "input_category_ids"),
            "cand_offsets": _num_array(txt, "input_candidate_offsets"),
            "cand_goods": _str_array(txt, "input_candidate_good_ids"),
            "cand_eff": _num_array(txt, "input_candidate_efficiency_q16"),
            "out_goods": _str_array(txt, "output_good_ids"),
            "out_qty": _num_array(txt, "output_quantities_per_day"),
            "construction_goods": _str_array(txt, "construction_good_ids"),
            "construction_qty": _num_array(txt, "construction_quantities"),
            "res_ids": _str_array(txt, "resource_ids"),
            "tech_tags": tech_tags,
            "req_tech_tags": required_tags,
        }
        buildings.append(building)
    return buildings


def expand_slots(buildings, goods):
    by_category = {}
    for gid, good in goods.items():
        for cat in {good["category"], *good["subs"]}:
            if cat:
                by_category.setdefault(cat, set()).add(gid)
    for b in buildings:
        slots = []
        for slot in range(len(b["in_goods"])):
            category = b["in_cats"][slot] if slot < len(b["in_cats"]) else ""
            materials = []
            if category:
                materials = sorted(by_category.get(category, []))
            elif b["cand_offsets"] and slot + 1 < len(b["cand_offsets"]):
                begin, end = b["cand_offsets"][slot], b["cand_offsets"][slot + 1]
                if end > begin:
                    materials = b["cand_goods"][begin:end]
            if not materials:
                materials = [b["in_goods"][slot]]
            slots.append(sorted(set(materials)))
        b["slot_materials"] = slots
        hard_materials = set()
        for slot, materials in enumerate(slots):
            req = b["in_req"][slot] if slot < len(b["in_req"]) else Q16_ONE
            if req >= Q16_ONE:
                hard_materials.update(materials)
        b["hard_materials"] = sorted(hard_materials)
        b["accepted"] = sorted({g for materials in slots for g in materials})


def load_plans():
    plans = []
    good_needs = {}
    for path in sorted(glob.glob(os.path.join(PLANS_DIR, "*.tres"))):
        txt = open(path, encoding="utf-8").read()
        need_ids = _str_array(txt, "need_ids")
        need_variant_offsets = _num_array(txt, "need_variant_offsets")
        variant_comp_offsets = _num_array(txt, "variant_component_offsets")
        components = _str_array(txt, "component_good_ids")
        plan = {"id": _str_field(txt, "id"), "needs": {}}
        for i, need in enumerate(need_ids):
            if i + 1 >= len(need_variant_offsets):
                break
            comps = []
            for v in range(need_variant_offsets[i], need_variant_offsets[i + 1]):
                if v + 1 >= len(variant_comp_offsets):
                    continue
                for c in range(variant_comp_offsets[v], variant_comp_offsets[v + 1]):
                    if 0 <= c < len(components):
                        comps.append(components[c])
                        good_needs.setdefault(components[c], set()).add(need)
            plan["needs"][need] = comps
        plans.append(plan)
    return plans, good_needs


def indexes(buildings, plans, good_needs):
    producers, hard_consumers = {}, {}
    for b in buildings:
        for g in b["out_goods"]:
            producers.setdefault(g, []).append(b)
        for g in b["hard_materials"]:
            hard_consumers.setdefault(g, []).append(b)
    need_components = {}
    for plan in plans:
        for need, comps in plan["needs"].items():
            need_components.setdefault(need, set()).update(comps)
    return producers, hard_consumers, need_components


def out_mass(b):
    return sum(b["out_qty"]) / GOODS_SCALE


def check_food(buildings, goods, good_needs):
    """Slots whose accepted materials are all food, and food-led slots."""
    rows = []
    for b in buildings:
        if b["sector"] == "agriculture":
            continue
        out_needs = set()
        for g in b["out_goods"]:
            out_needs |= good_needs.get(g, set())
        if out_needs & FOOD_NEEDS or set(b["out_goods"]) & DRINK_GOODS:
            continue
        total_out = out_mass(b)
        for slot, materials in enumerate(b["slot_materials"]):
            req = b["in_req"][slot] if slot < len(b["in_req"]) else Q16_ONE
            foods = [g for g in materials if good_needs.get(g, set()) & FOOD_NEEDS]
            if not foods:
                continue
            if req <= 0:
                continue
            qty = b["in_qty"][slot] / GOODS_SCALE if slot < len(b["in_qty"]) else 0.0
            all_food = len(foods) == len(materials)
            calorie = any(good_needs.get(g, set()) & CALORIE_NEEDS for g in foods)
            if req >= Q16_ONE and all_food and calorie:
                cls = "food-only-hard"
            elif req >= Q16_ONE and all_food:
                cls = "food-agent-hard"
            elif calorie and total_out and qty / total_out >= 0.2:
                cls = "bulk-food"
            else:
                cls = "feed-or-agent"
            rows.append({
                "kind": "food", "class": cls,
                "building": b["id"], "name": b["name"], "era": b["era"],
                "slot": slot, "hard": req >= Q16_ONE,
                "materials": materials, "food_materials": foods,
                "food_need": sorted({n for g in foods for n in good_needs.get(g, set()) & FOOD_NEEDS}),
                "qty_per_day": round(qty, 3),
                "mass_share": round(qty / total_out, 3) if total_out else 0.0,
                "output": b["out_goods"], "path": b["path"],
            })
    order = {"food-only-hard": 0, "food-agent-hard": 1, "bulk-food": 2, "feed-or-agent": 3}
    rows.sort(key=lambda row: (order[row["class"]], -row["mass_share"]))
    return rows


def check_buildfood(buildings, good_needs):
    """Construction bills that charge calorie food goods (food as building stuff)."""
    rows = []
    food_goods = {g for g, needs in good_needs.items() if needs & CALORIE_NEEDS}
    for b in buildings:
        hits = []
        for i, g in enumerate(b["construction_goods"]):
            if g in food_goods:
                qty = b["construction_qty"][i] / GOODS_SCALE if i < len(b["construction_qty"]) else 0.0
                hits.append({"good": g, "qty": round(qty, 3)})
        if hits:
            rows.append({"kind": "buildfood", "building": b["id"], "era": b["era"],
                         "food_materials": hits, "path": b["path"]})
    return rows


def check_bypass(buildings, good_needs, hard_consumers):
    """Same-era parallel: M -> C, and M -> A -> D where C competes with D.

    Only same-era methods count: a later tier is allowed to refine what an
    earlier direct method already made, that is the normal progression.  A hit
    means two contemporaneous routes split one material, one through the
    intermediate that the other route's product competes against, and the
    direct route deliberately does not accept that intermediate.
    """
    rows = []
    by_id = {b["id"]: b for b in buildings}
    for material, consumers in sorted(hard_consumers.items()):
        direct = {g for b in consumers for g in b["out_goods"]}
        for a in sorted(direct):
            for bridge in hard_consumers.get(a, []):
                for d in bridge["out_goods"]:
                    for c in sorted(direct - {a, d}):
                        if {c, d} & {"technology_points"}:
                            continue
                        if not (good_needs.get(c, set()) & good_needs.get(d, set())):
                            continue
                        c_producers = [b for b in consumers if c in b["out_goods"]]
                        a_producers = [b for b in consumers if a in b["out_goods"]]
                        if not c_producers or not a_producers:
                            continue
                        if all(a in b["accepted"] for b in c_producers):
                            continue
                        if any(b["era_idx"] != a_producers[0]["era_idx"] for b in c_producers):
                            continue
                        if any(b["era_idx"] != a_producers[0]["era_idx"] for b in a_producers):
                            continue
                        rows.append({
                            "kind": "bypass", "material": material,
                            "era": a_producers[0]["effective_era"],
                            "direct_product": c, "intermediate": a,
                            "intermediate_product": d,
                            "shared_needs": sorted(good_needs[c] & good_needs[d]),
                            "c_producers": [b["id"] for b in c_producers],
                            "a_producers": [b["id"] for b in a_producers],
                            "bridge": bridge["id"],
                        })
    seen, unique = set(), []
    for row in rows:
        key = (row["material"], row["direct_product"], row["intermediate"],
               row["intermediate_product"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(row)
    return unique


def check_twins(buildings):
    rows = []
    groups = {}
    for b in buildings:
        if b["res_ids"] or "technology_points" in b["out_goods"]:
            continue
        key = tuple(b["hard_materials"])
        if not key:
            continue
        groups.setdefault(key, []).append(b)
    for key, members in groups.items():
        for i in range(len(members)):
            for j in range(i + 1, len(members)):
                a, b = members[i], members[j]
                if set(a["out_goods"]) == set(b["out_goods"]):
                    continue
                qa, qb = out_mass(a), out_mass(b)
                if not qa or not qb:
                    continue
                ratio = min(qa, qb) / max(qa, qb)
                if ratio < 0.85:
                    continue
                rows.append({
                    "kind": "twins", "materials": list(key),
                    "a": a["id"], "a_out": a["out_goods"], "a_qty": round(qa, 2),
                    "a_era": a["era"], "a_path": a["path"],
                    "b": b["id"], "b_out": b["out_goods"], "b_qty": round(qb, 2),
                    "b_era": b["era"], "b_path": b["path"],
                    "ratio": round(ratio, 3),
                })
    return rows


def check_era(buildings, producers, eras):
    rows = []
    for b in buildings:
        if not b["slot_materials"]:
            continue
        best_era = len(eras)
        best_good = ""
        for slot, materials in enumerate(b["slot_materials"]):
            req = b["in_req"][slot] if slot < len(b["in_req"]) else Q16_ONE
            if req < Q16_ONE:
                continue
            slot_best = None
            for g in materials:
                made = producers.get(g, [])
                if not made:
                    continue
                earliest = min(x["era_idx"] for x in made)
                if slot_best is None or earliest < slot_best:
                    slot_best = earliest
            if slot_best is None:
                # Unproducible material: the ghost check reports it.
                continue
            if slot_best > b["era_idx"]:
                first = min([x for g in materials for x in producers.get(g, [])],
                            key=lambda x: x["era_idx"])
                rows.append({
                    "kind": "era", "building": b["id"], "building_era": b["effective_era"],
                    "slot": slot, "materials": materials,
                    "material_first_era": eras[slot_best],
                    "first_producer": first["id"], "gap": slot_best - b["era_idx"],
                    "path": b["path"],
                })
                break
    return rows


def check_claim(goods, buildings, producers, tech_eras, eras):
    rows = []
    for gid, good in goods.items():
        claim_era = _era_of_tags(good["tech_tags"], tech_eras, eras, default=None)
        made = producers.get(gid, [])
        if claim_era is None or not made:
            continue
        producer_era = min(x["era_idx"] for x in made)
        if producer_era > claim_era:
            first = min(made, key=lambda x: x["era_idx"])
            rows.append({
                "kind": "claim", "good": gid, "name": good["name"],
                "claim_era": eras[claim_era], "producer_era": eras[producer_era],
                "gap": producer_era - claim_era, "first_producer": first["id"],
                "path": good["path"],
            })
    rows.sort(key=lambda row: -row["gap"])
    return rows


def check_ghost(buildings, producers, good_needs):
    rows = []
    for b in buildings:
        for g in b["hard_materials"]:
            if g not in producers:
                rows.append({"kind": "ghost", "role": "hard input", "good": g,
                             "building": b["id"], "path": b["path"]})
    for g in sorted(good_needs):
        if g not in producers:
            rows.append({"kind": "ghost", "role": "household component", "good": g,
                         "needs": sorted(good_needs[g])})
    unique = {}
    for row in rows:
        unique.setdefault((row.get("role"), row["good"]), row)
    return list(unique.values())


def check_ratio(buildings, goods):
    rows = []
    for b in buildings:
        if b["res_ids"] or "technology_points" in b["out_goods"]:
            continue
        if not b["out_qty"] or not b["out_goods"]:
            continue
        out_value = 0.0
        for i, g in enumerate(b["out_goods"]):
            if i < len(b["out_qty"]):
                out_value += (b["out_qty"][i] / GOODS_SCALE) * goods.get(g, {}).get("price", 1)
        in_value = 0.0
        for i, g in enumerate(b["in_goods"]):
            req = b["in_req"][i] if i < len(b["in_req"]) else Q16_ONE
            if req < Q16_ONE:
                continue
            in_value += (b["in_qty"][i] / GOODS_SCALE) * goods.get(g, {}).get("price", 1)
        if out_value <= 0 or in_value <= 0:
            continue
        ratio = in_value / out_value
        if ratio > 0.90 or ratio < 0.30:
            rows.append({"kind": "ratio", "building": b["id"], "era": b["era"],
                         "sector": b["sector"],
                         "ratio": round(ratio, 3), "in_value": round(in_value),
                         "out_value": round(out_value), "path": b["path"]})
    rows.sort(key=lambda row: row["ratio"])
    return rows


def check_cycle(buildings):
    rows = []
    for b in buildings:
        overlap = set(b["hard_materials"]) & set(b["out_goods"])
        if overlap:
            rows.append({"kind": "cycle", "building": b["id"], "goods": sorted(overlap),
                         "path": b["path"]})
    return rows


def check_prefer(buildings, goods, tech_eras, eras):
    rows = []
    for b in buildings:
        for slot, materials in enumerate(b["slot_materials"]):
            if len(materials) < 2:
                continue
            if slot + 1 >= len(b["cand_offsets"]):
                continue
            begin, end = b["cand_offsets"][slot], b["cand_offsets"][slot + 1]
            if end <= begin:
                continue
            preferred = b["in_goods"][slot]
            costs = {}
            for c in range(begin, end):
                g = b["cand_goods"][c]
                eff = b["cand_eff"][c] if c < len(b["cand_eff"]) else Q16_ONE
                if eff <= 0 or g not in goods:
                    continue
                good_era = _era_of_tags(goods[g]["tech_tags"], tech_eras, eras, default=0)
                if good_era > b["era_idx"]:
                    continue
                costs[g] = goods[g]["price"] / (eff / Q16_ONE)
            if preferred not in costs or len(costs) < 2:
                continue
            cheapest = min(costs.values())
            if cheapest <= 0:
                continue
            ratio = costs[preferred] / cheapest
            if ratio >= 2.0:
                rows.append({
                    "kind": "prefer", "building": b["id"], "slot": slot,
                    "preferred": preferred, "preferred_cost": round(costs[preferred]),
                    "cheapest": min(costs, key=costs.get),
                    "cheapest_cost": round(cheapest), "ratio": round(ratio, 2),
                    "path": b["path"],
                })
    rows.sort(key=lambda row: -row["ratio"])
    return rows


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", default="")
    parser.add_argument("--only", default="")
    args = parser.parse_args()
    wanted = {x.strip() for x in args.only.split(",") if x.strip()}

    goods = load_goods()
    tech_eras, eras = load_tech_eras()
    buildings = load_buildings(tech_eras, eras)
    expand_slots(buildings, goods)
    plans, good_needs = load_plans()
    producers, hard_consumers, need_components = indexes(buildings, plans, good_needs)

    checks = {
        "food": lambda: check_food(buildings, goods, good_needs),
        "buildfood": lambda: check_buildfood(buildings, good_needs),
        "bypass": lambda: check_bypass(buildings, good_needs, hard_consumers),
        "twins": lambda: check_twins(buildings),
        "era": lambda: check_era(buildings, producers, eras),
        "claim": lambda: check_claim(goods, buildings, producers, tech_eras, eras),
        "ghost": lambda: check_ghost(buildings, producers, good_needs),
        "ratio": lambda: check_ratio(buildings, goods),
        "cycle": lambda: check_cycle(buildings),
        "prefer": lambda: check_prefer(buildings, goods, tech_eras, eras),
    }
    report = {}
    for name, run in checks.items():
        if wanted and name not in wanted:
            continue
        report[name] = run()

    print(f"goods={len(goods)} buildings={len(buildings)} plans={len(plans)} "
          f"household goods={len(good_needs)}")
    for name, rows in report.items():
        print(f"\n== {name}: {len(rows)} ==")
        for row in rows[:80]:
            print("  " + json.dumps(row, ensure_ascii=False, sort_keys=True))
        if len(rows) > 80:
            print(f"  ... {len(rows) - 80} more")
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
