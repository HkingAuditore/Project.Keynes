# -*- coding: utf-8 -*-
"""Deterministic economy content rebalance & balance audit tool.

Usage:
    python tools/economy/rebalance_economy_content.py --dry-run
    python tools/economy/rebalance_economy_content.py --apply
    python tools/economy/rebalance_economy_content.py --check

Handles:
1. Hardening primary raw-material inputs (required_q16 = 65536) on all industrial
   buildings (eliminating the 32 zero-hard-input industrial buildings and
   misclassified feedstocks while keeping genuine auxiliary enhancers soft).
2. Removing excess post-stone food output inflation while preserving Stone Age
   40-person opening safety, era monotonicity, and food_output <= food_input.
3. Recalibrating industrial intermediate inputs & outputs to 45%-70% input/output
   value ratios while guaranteeing strict upgrade-family monotonicity and
   positive operating margins at default prices.
4. Raising household non-food consumption share to 35%-50% (at wealth=1x) and
   extending wealth elasticities / wealth_max_q16 up to 32x for smooth
   wealth-scaled consumption growth across 15 LUT anchors (up to 1024x).
"""
import argparse
import glob
import json
import math
import os
import re
import statistics
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJ = os.path.join(ROOT, "Project", "project-keynes")
GOODS_DIR = os.path.join(PROJ, "data", "goods")
BUILDINGS_DIR = os.path.join(PROJ, "data", "economy", "buildings")
CURATED_DIR = os.path.join(ROOT, "tools", "codegen", "economy_content", "buildings")
PLANS_DIR = os.path.join(PROJ, "data", "economy", "consumption_plans")
PROFESSIONS_DIR = os.path.join(PROJ, "data", "economy", "professions")
TECH_NETWORK = os.path.join(PROJ, "data", "technology", "technology_network.json")

Q16_ONE = 65536
GOODS_SCALE = 1000.0
MONEY_SCALE = 10000.0

ERA_IDS = [
    "stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
    "steam", "electrical", "atomic", "information", "intelligent",
]

FOOD_EQUIVALENT_GOODS = {
    "prepared_staples", "bread", "grain", "gathered_plants", "potatoes",
    "game_meat", "meat", "fish", "canned_fish", "dairy_products",
    "vegetables", "processed_food", "wheat_grain", "rice_grain",
    "corn_grain", "livestock_products", "frozen_food", "edible_oil",
}

PRIMARY_FOOD_CHAINS = {
    "production.wheat_grain", "production.rice_grain", "production.corn_grain",
    "production.potatoes", "subsistence_food",
}

# Only genuine productivity enhancers may remain soft inputs on industrial buildings.
AUXILIARY_SOFT_GOODS = {
    "chipped_stone_tools", "bronze_tools", "tools", "precision_tools",
    "industrial_machinery", "agricultural_machinery", "steam_engines",
    "electric_motor", "computers", "autonomous_systems",
    "scientific_instruments", "fertilizer", "lubricants",
}

# Stone-age / opening buildings whose base output anchors StarterEconomyPlanner (40 people @ 1.0x)
STARTER_FOOD_ANCHORS = {
    "gathering_ground", "stone_age_hunting_camp", "marine_fish_collector",
    "wild_wheat_stand", "wild_rice_marsh", "wild_maize_stand",
    "wild_tuber_patch", "pastoral_camp", "communal_hearth",
    "freshwater_fishery", "shoreline_shellfish_camp",
}

# Stone-age opening collectors (food + non-food starter anchors) were originally tuned for 1.5x global efficiency.
# Compensating their outputs (1.45x) prevents Stone Age starvation and opening logs/fur/gold shortages
# after rolling building_output_efficiency_q16 back from 1.5x to 1.0x, while staying below old 1.5x.
STARTER_FOOD_COMPENSATION = 1.45
STARTER_NONFOOD_ANCHORS = {
    "deadwood_gathering_camp", "placer_gold_working",
}

# Era-based food output scale (reversing legacy 2x food scaling gently without breaking stone start)
FOOD_ERA_SCALE = {
    "stone": 1.00,
    "agrarian": 0.65,
    "kingdom": 0.60,
    "empire": 0.56,
    "exploration": 0.52,
    "enlightenment": 0.48,
    "steam": 0.34,
    "electrical": 0.32,
    "atomic": 0.30,
    "information": 0.26,
    "intelligent": 0.20,
}

# Target need parameters for consumption plans (base_qty is per-plan scaled below)
# (wealth_elasticity_q16, wealth_min_q16, wealth_max_q16)
NEED_WEALTH_SPEC = {
    "staple_food":       (4096,  49152,   81920),   # 0.0625, max 1.25x
    "protein":           (16384, 32768,  163840),   # 0.25,   max 2.50x
    "produce":           (16384, 32768,  163840),   # 0.25,   max 2.50x
    "food_fat":          (14746, 32768,  163840),   # 0.225,  max 2.50x
    "seasoning":         (19661, 16384,  196608),   # 0.30,   max 3.00x
    "clothing":          (29491, 16384,  393216),   # 0.45,   max 6.00x
    "housing":           (29491, 16384,  393216),   # 0.45,   max 6.00x
    "hygiene":           (29491, 16384,  393216),   # 0.45,   max 6.00x
    "healthcare":        (29491, 16384,  393216),   # 0.45,   max 6.00x
    "home_energy":       (29491, 16384,  393216),   # 0.45,   max 6.00x
    "household_goods":   (36045,  8192,  655360),   # 0.55,   max 10.0x
    "domestic_wares":    (36045,  8192,  655360),   # 0.55,   max 10.0x
    "work_equipment":    (36045,  8192,  655360),   # 0.55,   max 10.0x
    "transport":         (39322,  8192,  786432),   # 0.60,   max 12.0x
    "recreation":        (39322,  8192,  786432),   # 0.60,   max 12.0x
    "communication":     (42598,  8192, 1048576),   # 0.65,   max 16.0x
    "education_culture": (42598,  8192, 1048576),   # 0.65,   max 16.0x
    "durable_goods":     (49152,  4096, 1048576),   # 0.75,   max 16.0x
    "luxury":            (55706,  1024, 2097152),   # 0.85,   max 32.0x
    "status_goods":      (55706,  1024, 2097152),   # 0.85,   max 32.0x
}

# Reference non-food base_qty_per_person (at 100% scale) targeting 36-52% non-food value share
NONFOOD_REF_BASE = {
    "clothing": 24,
    "housing": 38,
    "household_goods": 14,
    "domestic_wares": 16,
    "hygiene": 36,
    "healthcare": 18,
    "home_energy": 220,
    "transport": 14,
    "communication": 10,
    "education_culture": 14,
    "recreation": 22,
    "durable_goods": 10,
    "work_equipment": 3,
    "luxury": 12,
    "status_goods": 10,
}

# Per-plan (food_scale, nonfood_scale): keeps survival_household & plan_unemployed
# food untouched while normalizing bloated raw calories in higher plans so non-food
# reaches 36-52% at wealth=1.0 without inflating opening living costs into bankruptcy.
PLAN_SCALES = {
    "plan_unemployed":             (1.00, 0.00),  # food-only (untouched)
    "survival_household":          (1.00, 0.30),  # survival floor (food untouched, ~16% non-food)
    "hunter_household":            (0.84, 0.72),  # ~34% non-food, total ~1.46
    "agrarian_household":          (0.78, 0.85),  # ~39% non-food, total ~1.63
    "extractive_household":        (0.74, 0.96),  # ~39% non-food, total ~1.71
    "industrial_worker_household": (0.76, 0.98),  # ~40% non-food, total ~1.71
    "soldier_household":           (0.76, 0.92),  # ~38% non-food, total ~1.67
    "artisan_household":           (0.74, 1.05),  # ~42% non-food, total ~1.80
    "scholarly_household":         (0.74, 1.05),  # ~42% non-food, total ~1.80
    "technical_household":         (0.72, 1.08),  # ~50% non-food, total ~2.12
    "merchant_household":          (0.70, 1.15),  # ~51% non-food, total ~2.21
    "owner_household":             (0.68, 1.20),  # ~52% non-food, total ~2.26
}

FOOD_NEEDS = {"staple_food", "protein", "produce", "food_fat", "seasoning"}


# ─── .tres helpers ────────────────────────────────────────────────────────────

def parse_str_field(txt: str, key: str, default: str = "") -> str:
    m = re.search(rf'^{re.escape(key)}\s*=\s*&?"([^"]*)"', txt, re.M)
    return m.group(1) if m else default


def parse_int_field(txt: str, key: str, default: int = 0) -> int:
    m = re.search(rf'^{re.escape(key)}\s*=\s*(-?[0-9]+)', txt, re.M)
    return int(m.group(1)) if m else default


def parse_str_array(txt: str, key: str) -> list:
    m = re.search(rf'^{re.escape(key)}\s*=\s*PackedStringArray\(([^)]*)\)', txt, re.M)
    if not m or not m.group(1).strip():
        return []
    return re.findall(r'"([^"]*)"', m.group(1))


def parse_num_array(txt: str, key: str) -> list:
    m = re.search(rf'^{re.escape(key)}\s*=\s*PackedInt(?:32|64)Array\(([^)]*)\)', txt, re.M)
    if not m or not m.group(1).strip():
        return []
    return [int(x.strip()) for x in m.group(1).split(",") if x.strip()]


def replace_num_array(txt: str, key: str, arr_type: str, values: list) -> str:
    formatted = f"{key} = {arr_type}(" + ", ".join(str(int(v)) for v in values) + ")"
    pat = rf'(?m)^{re.escape(key)}\s*=\s*{arr_type}\([^)]*\)\r?$'
    if re.search(pat, txt):
        return re.sub(pat, formatted, txt, count=1)
    # Insert right after input_quantities_per_day if adding input_required_q16
    if key == "input_required_q16":
        anchor = r'(?m)^input_quantities_per_day\s*=\s*PackedInt64Array\([^)]*\)\r?$'
        m = re.search(anchor, txt)
        if m:
            return txt[:m.end()] + "\n" + formatted + txt[m.end():]
    return txt.rstrip() + "\n" + formatted + "\n"


def load_goods():
    goods = {}
    for p in sorted(glob.glob(os.path.join(GOODS_DIR, "*.tres"))):
        txt = open(p, encoding="utf-8").read()
        gid = parse_str_field(txt, "id", os.path.splitext(os.path.basename(p))[0])
        price = parse_int_field(txt, "default_price", 10000) / MONEY_SCALE
        cats = parse_str_array(txt, "substitution_category_ids")
        cat = parse_str_field(txt, "category_id", "misc")
        if cat and cat not in cats:
            cats.append(cat)
        qual = parse_int_field(txt, "production_quality_level", 0)
        eff = parse_int_field(txt, "production_efficiency_q16", Q16_ONE) / float(Q16_ONE)
        goods[gid] = {
            "price": price,
            "categories": cats,
            "quality": qual,
            "efficiency": max(0.01, eff),
        }
    return goods


def load_tech_eras():
    data = json.load(open(TECH_NETWORK, encoding="utf-8"))
    return {n["id"]: n["era_id"] for n in data["nodes"]}


def load_professions():
    profs = {}
    for p in sorted(glob.glob(os.path.join(PROFESSIONS_DIR, "*.tres"))):
        txt = open(p, encoding="utf-8").read()
        pid = parse_str_field(txt, "id", os.path.splitext(os.path.basename(p))[0])
        plan = parse_str_field(txt, "consumption_plan_id", "agrarian_household")
        profs[pid] = plan
    return profs


def building_era_id(b, tech_eras):
    latest = -1
    latest_id = "stone"
    for tag in b["tech_tags"] + b["req_tech_tags"]:
        if tag in tech_eras:
            eid = tech_eras[tag]
            idx = ERA_IDS.index(eid) if eid in ERA_IDS else -1
            if idx > latest:
                latest = idx
                latest_id = eid
    return latest_id


def parse_building(path, tech_eras):
    txt = open(path, encoding="utf-8").read()
    bid = parse_str_field(txt, "id", os.path.splitext(os.path.basename(path))[0])
    b = {
        "path": path,
        "txt": txt,
        "id": bid,
        "kind": parse_str_field(txt, "building_kind", "industrial"),
        "sector": parse_str_field(txt, "economic_sector_id", ""),
        "state_role": parse_str_field(txt, "state_role", "none"),
        "chain": parse_str_field(txt, "industry_chain_id", ""),
        "family": parse_str_field(txt, "upgrade_family_id", ""),
        "tier": parse_int_field(txt, "upgrade_tier", 0),
        "owner_prof": parse_str_field(txt, "owner_profession_id", "farmer"),
        "owner_slots": max(1, parse_int_field(txt, "owner_slots_per_building", 1)),
        "emp_profs": parse_str_array(txt, "employee_profession_ids"),
        "emp_slots": parse_num_array(txt, "employee_slots_per_building"),
        "in_goods": parse_str_array(txt, "input_good_ids"),
        "in_qty": parse_num_array(txt, "input_quantities_per_day"),
        "in_req": parse_num_array(txt, "input_required_q16"),
        "in_cats": parse_str_array(txt, "input_category_ids"),
        "out_goods": parse_str_array(txt, "output_good_ids"),
        "out_qty": parse_num_array(txt, "output_quantities_per_day"),
        "res_ids": parse_str_array(txt, "resource_ids"),
        "res_qty": parse_num_array(txt, "resource_quantities_per_day"),
        "res_modes": parse_str_array(txt, "resource_interaction_modes"),
        "tech_tags": parse_str_array(txt, "technology_tags"),
        "req_tech_tags": parse_str_array(txt, "required_technology_tags"),
    }
    if not b["in_req"] and b["in_goods"]:
        b["in_req"] = [Q16_ONE] * len(b["in_goods"])
    b["era"] = building_era_id(b, tech_eras)
    b["era_idx"] = ERA_IDS.index(b["era"]) if b["era"] in ERA_IDS else 0
    b["labor"] = b["owner_slots"] + sum(b["emp_slots"])
    return b


def calc_values(b, goods):
    in_val = 0.0
    hard_in_val = 0.0
    for i, g in enumerate(b["in_goods"]):
        req = b["in_req"][i] if i < len(b["in_req"]) else Q16_ONE
        if req <= 0:
            continue
        p = goods.get(g, {}).get("price", 1.0)
        v = (b["in_qty"][i] / GOODS_SCALE) * p
        in_val += v
        if req >= Q16_ONE:
            hard_in_val += v
    out_val = 0.0
    food_out = 0.0
    for i, g in enumerate(b["out_goods"]):
        p = goods.get(g, {}).get("price", 1.0)
        out_val += (b["out_qty"][i] / GOODS_SCALE) * p
        if g in FOOD_EQUIVALENT_GOODS:
            food_out += b["out_qty"][i]
    food_in = 0.0
    for i, g in enumerate(b["in_goods"]):
        req = b["in_req"][i] if i < len(b["in_req"]) else Q16_ONE
        if req > 0 and g in FOOD_EQUIVALENT_GOODS:
            food_in += b["in_qty"][i]
    return in_val, hard_in_val, out_val, food_in, food_out


def rebalance_plans(goods, apply_changes: bool):
    plan_daily_cost = {}
    summary = []
    for p in sorted(glob.glob(os.path.join(PLANS_DIR, "*.tres"))):
        txt = open(p, encoding="utf-8").read()
        pid = parse_str_field(txt, "id", os.path.splitext(os.path.basename(p))[0])
        need_ids = parse_str_array(txt, "need_ids")
        base_qty = parse_num_array(txt, "base_qty_per_person")
        w_el = parse_num_array(txt, "wealth_elasticity_q16")
        w_min = parse_num_array(txt, "wealth_min_q16")
        w_max = parse_num_array(txt, "wealth_max_q16")
        need_offsets = parse_num_array(txt, "need_variant_offsets")
        var_thr = parse_num_array(txt, "variant_class_savings_threshold_factor_q16")
        comp_offsets = parse_num_array(txt, "variant_component_offsets")
        comp_goods = parse_str_array(txt, "component_good_ids")
        comp_qty = parse_num_array(txt, "component_qty_per_need")

        f_scale, nf_scale = PLAN_SCALES.get(pid, (0.80, 1.00))
        new_base = list(base_qty)
        new_el = list(w_el)
        new_min = list(w_min)
        new_max = list(w_max)

        for i, nid in enumerate(need_ids):
            if nid in NEED_WEALTH_SPEC:
                el, mn, mx = NEED_WEALTH_SPEC[nid]
                new_el[i] = el
                new_min[i] = mn
                new_max[i] = mx
            if nid in FOOD_NEEDS:
                if f_scale < 0.999:
                    new_base[i] = max(1, int(round(base_qty[i] * f_scale)))
            elif nf_scale > 0.0 and nid in NONFOOD_REF_BASE:
                target_q = max(1, int(round(NONFOOD_REF_BASE[nid] * nf_scale)))
                new_base[i] = target_q

        # Smooth non-zero variant savings threshold factors so rich & middle cohorts
        # actively unlock comfort/durable/luxury variants rather than hoarding cash.
        new_thr = []
        for t in var_thr:
            if t <= 0:
                new_thr.append(0)
            else:
                new_thr.append(max(8192, int(round(t * 0.55))))

        # Compute base basket food vs non-food daily cost at default prices (wealth=1.0)
        food_cost = 0.0
        nonfood_cost = 0.0
        for ni, nid in enumerate(need_ids):
            vb = need_offsets[ni]
            ve = need_offsets[ni + 1]
            if ve <= vb:
                continue
            v_costs = []
            for v in range(vb, ve):
                cb = comp_offsets[v]
                ce = comp_offsets[v + 1]
                vc = 0.0
                for c in range(cb, ce):
                    gp = goods.get(comp_goods[c], {}).get("price", 1.0)
                    vc += (comp_qty[c] / GOODS_SCALE) * gp
                v_costs.append(vc)
            avg_vc = sum(v_costs) / len(v_costs)
            c_day = (new_base[ni] / GOODS_SCALE) * avg_vc
            if nid in FOOD_NEEDS:
                food_cost += c_day
            else:
                nonfood_cost += c_day
        total_cost = food_cost + nonfood_cost
        nf_share = nonfood_cost / total_cost if total_cost > 0 else 0.0
        plan_daily_cost[pid] = total_cost
        summary.append((pid, total_cost, food_cost, nonfood_cost, nf_share))

        if apply_changes:
            new_txt = txt
            new_txt = replace_num_array(new_txt, "base_qty_per_person", "PackedInt64Array", new_base)
            new_txt = replace_num_array(new_txt, "wealth_elasticity_q16", "PackedInt32Array", new_el)
            new_txt = replace_num_array(new_txt, "wealth_min_q16", "PackedInt32Array", new_min)
            new_txt = replace_num_array(new_txt, "wealth_max_q16", "PackedInt32Array", new_max)
            new_txt = replace_num_array(new_txt, "variant_class_savings_threshold_factor_q16", "PackedInt32Array", new_thr)
            if new_txt != txt:
                with open(p, "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(new_txt)

    return plan_daily_cost, summary


def is_industrial_building(b):
    return b["sector"] in ("manufacturing", "energy")


def rebalance_buildings(goods, tech_eras, profs, plan_daily_cost, apply_changes: bool):
    buildings = [
        parse_building(p, tech_eras)
        for p in sorted(glob.glob(os.path.join(BUILDINGS_DIR, "*.tres")))
    ]
    by_id = {b["id"]: b for b in buildings}

    def labor_living_cost(b):
        owner_plan = profs.get(b["owner_prof"], "agrarian_household")
        total = b["owner_slots"] * plan_daily_cost.get(owner_plan, 2.0)
        for i, ep in enumerate(b["emp_profs"]):
            slots = b["emp_slots"][i] if i < len(b["emp_slots"]) else 0
            eplan = profs.get(ep, "agrarian_household")
            total += slots * plan_daily_cost.get(eplan, 2.0)
        return total

    # ── Pass 1: Harden primary raw-material inputs on industrial buildings ──
    hardened_buildings = 0
    hardened_edges = 0
    zero_req_fixed = 0
    for b in buildings:
        if not b["in_goods"]:
            continue
        if not is_industrial_building(b):
            # Still fix any zero required_q16 entries on non-industrial buildings
            for i, req in enumerate(b["in_req"]):
                if req == 0:
                    g = b["in_goods"][i]
                    cat = b["in_cats"][i] if i < len(b["in_cats"]) else ""
                    b["in_req"][i] = 32768 if (g in AUXILIARY_SOFT_GOODS or cat == "tools") else Q16_ONE
                    zero_req_fixed += 1
            continue

        # Industrial / manufacturing / energy building
        changed = False
        new_req = list(b["in_req"])
        # First pass: determine which inputs are genuine auxiliary enhancers
        non_aux_indices = []
        for i, g in enumerate(b["in_goods"]):
            cat = b["in_cats"][i] if i < len(b["in_cats"]) else ""
            if g in AUXILIARY_SOFT_GOODS or cat == "tools":
                if new_req[i] == 0:
                    new_req[i] = 32768
                    zero_req_fixed += 1
                    changed = True
                continue
            if g == "electricity":
                # Keep electricity soft only if building has another non-aux feedstock
                continue
            non_aux_indices.append(i)

        for i in non_aux_indices:
            if new_req[i] < Q16_ONE:
                if new_req[i] == 0:
                    zero_req_fixed += 1
                new_req[i] = Q16_ONE
                hardened_edges += 1
                changed = True

        # Ensure zero industrial buildings with inputs have 0 hard inputs
        if not any(r >= Q16_ONE for r in new_req):
            # Prefer hardening electricity or the first non-tool input, else the first input
            picked = None
            for i, g in enumerate(b["in_goods"]):
                if g == "electricity":
                    picked = i
                    break
            if picked is None:
                for i, g in enumerate(b["in_goods"]):
                    cat = b["in_cats"][i] if i < len(b["in_cats"]) else ""
                    if cat != "tools" and g not in ("tools", "chipped_stone_tools", "bronze_tools", "precision_tools"):
                        picked = i
                        break
            if picked is None:
                picked = 0
            new_req[picked] = Q16_ONE
            hardened_edges += 1
            changed = True

        if changed:
            b["in_req"] = new_req
            hardened_buildings += 1

    # ── Pass 2: Food output recalibration (undo 2x food bloat safely) ──
    # Collect primary food upgrade families so we preserve strict monotonicity
    food_scaled = 0
    for b in buildings:
        if not b["out_goods"] or b["state_role"] != "none":
            continue
        if b["id"] in STARTER_NONFOOD_ANCHORS:
            new_out = [
                max(1, int(round(q * STARTER_FOOD_COMPENSATION)))
                for q in b["out_qty"]
            ]
            if new_out != b["out_qty"]:
                b["out_qty"] = new_out
                food_scaled += 1
            continue
        if any(g in ("gold", "silver", "technology_points") for g in b["out_goods"]):
            continue
        if b["id"] in STARTER_FOOD_ANCHORS:
            if b["id"] != "communal_hearth":
                new_out = [
                    max(1, int(round(q * STARTER_FOOD_COMPENSATION)))
                    if (b["out_goods"][i] in FOOD_EQUIVALENT_GOODS or b["id"] == "stone_age_hunting_camp") else q
                    for i, q in enumerate(b["out_qty"])
                ]
                if new_out != b["out_qty"]:
                    b["out_qty"] = new_out
                    food_scaled += 1
            continue
        has_food_out = any(g in FOOD_EQUIVALENT_GOODS for g in b["out_goods"])
        if not has_food_out:
            continue
        scale = FOOD_ERA_SCALE.get(b["era"], 0.50)
        if scale < 0.999:
            new_out = [
                max(1, int(round(q * scale))) if b["out_goods"][i] in FOOD_EQUIVALENT_GOODS else q
                for i, q in enumerate(b["out_qty"])
            ]
            # Scale extract resources proportionally if pure food extractor
            if b["res_modes"] and all(g in FOOD_EQUIVALENT_GOODS for g in b["out_goods"]):
                for ri, m in enumerate(b["res_modes"]):
                    if m == "extract":
                        b["res_qty"][ri] = max(1, int(round(b["res_qty"][ri] * scale)))
            b["out_qty"] = new_out
            food_scaled += 1

    # Enforce strict food upgrade family monotonicity (food_capacity = food_out / labor)
    families = {}
    for b in buildings:
        if b["family"] and b["family"] != "research_institution" and b["out_goods"]:
            families.setdefault(b["family"], []).append(b)

    for fam_id, members in families.items():
        if len(members) < 2:
            continue
        members.sort(key=lambda x: (x["tier"], x["era_idx"], x["id"]))
        is_food_fam = any(
            any(g in FOOD_EQUIVALENT_GOODS for g in m["out_goods"])
            for m in members
        )
        if is_food_fam:
            prev_cap = None
            for m in members:
                _, _, _, _, f_out = calc_values(m, goods)
                cap = f_out / float(m["labor"])
                if prev_cap is not None and cap <= prev_cap * 1.05:
                    target_f_out = math.ceil(prev_cap * 1.08 * m["labor"])
                    if f_out > 0:
                        mul = target_f_out / f_out
                        m["out_qty"] = [
                            max(1, int(math.ceil(q * mul))) if m["out_goods"][i] in FOOD_EQUIVALENT_GOODS else q
                            for i, q in enumerate(m["out_qty"])
                        ]
                        cap = sum(m["out_qty"][i] for i, g in enumerate(m["out_goods"]) if g in FOOD_EQUIVALENT_GOODS) / float(m["labor"])
                prev_cap = cap

    # Enforce monotonic era median food_capacity across primary food chains
    for _ in range(4):
        era_caps = {}
        for b in buildings:
            if b["chain"] in PRIMARY_FOOD_CHAINS and b["id"] != "gathering_ground":
                _, _, _, _, f_out = calc_values(b, goods)
                if f_out > 0:
                    era_caps.setdefault(b["era_idx"], []).append((b, f_out / float(b["labor"])))
        prev_med = 0.0
        adjusted = False
        for eidx in sorted(era_caps.keys()):
            med = statistics.median([c for _, c in era_caps[eidx]])
            if med < prev_med * 1.03:
                mul = (prev_med * 1.06) / max(1e-6, med)
                for b, _ in era_caps[eidx]:
                    if b["id"] in STARTER_FOOD_ANCHORS:
                        continue
                    b["out_qty"] = [
                        max(1, int(math.ceil(q * mul))) if b["out_goods"][i] in FOOD_EQUIVALENT_GOODS else q
                        for i, q in enumerate(b["out_qty"])
                    ]
                adjusted = True
                med = prev_med * 1.06
            prev_med = med
        if not adjusted:
            break

    # Pin Stone Age knapping_workshop to a balanced 1.0x recipe:
    # 1.2 flint (0.48) -> 0.38 chipped_stone_tools (2.85), net 2.37 > 1.69 artisan living cost,
    # keeping flint demand easily supplyable by a single flint_quarry.
    for b in buildings:
        if b["id"] == "knapping_workshop" and b["in_qty"] and b["out_qty"]:
            b["in_qty"][0] = 1200
            b["out_qty"][0] = 380

    # ── Pass 3: Industrial intermediate input/output value calibration (45%-70%) ──
    # Skip precious metals, knowledge/research, state buildings, and zero-input buildings.
    def is_calibratable_industrial(b):
        if b["state_role"] != "none" or not b["out_goods"] or not b["in_goods"]:
            return False
        if any(g in ("gold", "silver", "technology_points") for g in b["out_goods"]):
            return False
        if b["id"] in ("communal_hearth", "knapping_workshop"):
            return False
        return is_industrial_building(b)

    def exact_in_val(b):
        total = 0.0
        for idx, g in enumerate(b["in_goods"]):
            cat = b["in_cats"][idx] if idx < len(b["in_cats"]) else ""
            req = b["in_req"][idx] if idx < len(b["in_req"]) else Q16_ONE
            if req > 0 and not cat:
                total += (b["in_qty"][idx] / GOODS_SCALE) * goods.get(g, {}).get("price", 1.0)
        return total

    def calibrate_one(b, target_ratio: float, min_productivity: float = 0.0,
                      min_output_val: float = 0.0, max_exact_ratio: float = 1.0):
        in_val, hard_in_val, out_val, food_in, food_out = calc_values(b, goods)
        if in_val <= 0 or out_val <= 0:
            return
        lab_cost = labor_living_cost(b)
        # Ensure output value is large enough to cover inputs + labor + margin at target_ratio
        denom = max(0.18, 0.95 - target_ratio)
        required_out_val = max(
            out_val,
            (1.32 * lab_cost) / denom,
            min_productivity * b["labor"],
            min_output_val,
        )
        if required_out_val > out_val * 1.0001:
            o_mul = required_out_val / out_val
            b["out_qty"] = [max(1, int(math.ceil(q * o_mul))) for q in b["out_qty"]]
            in_val, hard_in_val, out_val, food_in, food_out = calc_values(b, goods)

        # Allocate target input value primarily to hard raw feedstocks (~85-90%),
        # capping soft/category auxiliaries at <= 12% of output value so factories
        # primarily consume real raw materials and exact-good yield stays monotonic.
        target_in_val = target_ratio * out_val
        soft_in_val = max(0.0, in_val - hard_in_val)
        if hard_in_val > 0 and soft_in_val > 0:
            max_soft_val = min(target_in_val * 0.22, out_val * 0.12)
            soft_mul = min(target_in_val / in_val, max_soft_val / soft_in_val)
            new_soft_val = soft_in_val * soft_mul
            target_hard_val = max(0.0, target_in_val - new_soft_val)
            hard_mul = target_hard_val / hard_in_val
            b["in_qty"] = [
                max(1, int(round(q * (hard_mul if b["in_req"][i] >= Q16_ONE else soft_mul))))
                for i, q in enumerate(b["in_qty"])
            ]
        else:
            in_mul = target_in_val / in_val
            b["in_qty"] = [max(1, int(round(q * in_mul))) for q in b["in_qty"]]

        # Guarantee exact-good input/output ratio stays strictly below max_exact_ratio
        # (ensures upgrade_input_yield_gap > 1.0 in technology_industry_chain_balance_test)
        cur_exact = exact_in_val(b)
        if max_exact_ratio < 0.99 and cur_exact > out_val * max_exact_ratio:
            e_mul = (out_val * max_exact_ratio) / cur_exact
            for i, g in enumerate(b["in_goods"]):
                cat = b["in_cats"][i] if i < len(b["in_cats"]) else ""
                if not cat and b["in_req"][i] > 0:
                    b["in_qty"][i] = max(1, int(math.floor(b["in_qty"][i] * e_mul)))

        # Food-processing invariant (PRIMARY_FOOD_CHAINS): food_output <= food_input
        in_val, _, out_val, food_in, food_out = calc_values(b, goods)
        if b["chain"] in PRIMARY_FOOD_CHAINS and food_in > 0 and food_out > food_in:
            f_mul = (food_out * 1.05) / food_in
            for i, g in enumerate(b["in_goods"]):
                if g in FOOD_EQUIVALENT_GOODS and b["in_req"][i] > 0:
                    b["in_qty"][i] = max(1, int(math.ceil(b["in_qty"][i] * f_mul)))

    # First handle industrial upgrade families in tier order with gently decreasing target_ratio
    # (so output_val / input_val strictly increases per tier while staying in [0.46, 0.68]!)
    handled = set()
    for fam_id, members in families.items():
        ind_members = [m for m in members if is_calibratable_industrial(m)]
        if not ind_members:
            continue
        members.sort(key=lambda x: (x["tier"], x["era_idx"], x["id"]))
        n = len(members)
        # Assign target input/output value ratios linearly from 0.66 -> 0.48
        if n == 1:
            ratios = [0.56]
        else:
            hi = min(0.68, 0.62 + 0.02 * (n - 2))
            lo = max(0.47, 0.52 - 0.015 * (n - 2))
            ratios = [hi - (hi - lo) * (idx / float(n - 1)) for idx in range(n)]

        prev_prod = 0.0
        prev_out = 0.0
        prev_yield = 0.0
        prev_exact_ratio = 1.0
        for idx, m in enumerate(members):
            if is_calibratable_industrial(m):
                tr = ratios[idx]
                if prev_yield > 0:
                    max_tr = 1.0 / (prev_yield * 1.04)
                    tr = min(tr, max(0.45, max_tr))
                max_er = prev_exact_ratio * 0.94 if prev_exact_ratio < 0.99 else 1.0
                calibrate_one(
                    m,
                    target_ratio=tr,
                    min_productivity=prev_prod * 1.06 if prev_prod > 0 else 0.0,
                    min_output_val=prev_out * 1.06 if prev_out > 0 else 0.0,
                    max_exact_ratio=max_er,
                )
                handled.add(m["id"])
            in_v, _, out_v, _, _ = calc_values(m, goods)
            ex_v = exact_in_val(m)
            prev_prod = out_v / float(m["labor"])
            prev_out = out_v
            if in_v > 0:
                prev_yield = out_v / in_v
            if ex_v > 0 and out_v > 0:
                prev_exact_ratio = ex_v / out_v

    # Standalone industrial buildings (not in an upgrade family)
    for b in buildings:
        if b["id"] in handled or not is_calibratable_industrial(b):
            continue
        # Slightly lower ratio for late-era precision/high-tech goods, higher for primary processing
        if b["era_idx"] <= 2:
            tr = 0.60
        elif b["era_idx"] <= 5:
            tr = 0.58
        elif b["era_idx"] <= 7:
            tr = 0.55
        else:
            tr = 0.52
        calibrate_one(b, target_ratio=tr)

    # Final safety pass: enforce food_output <= food_input on PRIMARY_FOOD_CHAINS
    for b in buildings:
        if b["chain"] not in PRIMARY_FOOD_CHAINS:
            continue
        _, _, _, food_in, food_out = calc_values(b, goods)
        if food_in > 0 and food_out > food_in:
            f_mul = (food_out * 1.05) / food_in
            for i, g in enumerate(b["in_goods"]):
                if g in FOOD_EQUIVALENT_GOODS and b["in_req"][i] > 0:
                    b["in_qty"][i] = max(1, int(math.ceil(b["in_qty"][i] * f_mul)))

    # Write updated building .tres files (and sync matching curated templates)
    written = 0
    curated_synced = 0
    for b in buildings:
        new_txt = b["txt"]
        if b["in_goods"]:
            new_txt = replace_num_array(new_txt, "input_quantities_per_day", "PackedInt64Array", b["in_qty"])
            new_txt = replace_num_array(new_txt, "input_required_q16", "PackedInt32Array", b["in_req"])
        if b["out_goods"]:
            new_txt = replace_num_array(new_txt, "output_quantities_per_day", "PackedInt64Array", b["out_qty"])
        if b["res_qty"]:
            new_txt = replace_num_array(new_txt, "resource_quantities_per_day", "PackedInt64Array", b["res_qty"])
        if new_txt != b["txt"]:
            written += 1
            if apply_changes:
                with open(b["path"], "w", encoding="utf-8", newline="\n") as fh:
                    fh.write(new_txt)
            # Sync curated template if one exists
            cur_path = os.path.join(CURATED_DIR, f"{b['id']}.tres")
            if os.path.isfile(cur_path):
                cur_txt = open(cur_path, encoding="utf-8").read()
                cur_new = cur_txt
                if b["in_goods"]:
                    cur_new = replace_num_array(cur_new, "input_quantities_per_day", "PackedInt64Array", b["in_qty"])
                    cur_new = replace_num_array(cur_new, "input_required_q16", "PackedInt32Array", b["in_req"])
                if b["out_goods"]:
                    cur_new = replace_num_array(cur_new, "output_quantities_per_day", "PackedInt64Array", b["out_qty"])
                if cur_new != cur_txt:
                    curated_synced += 1
                    if apply_changes:
                        with open(cur_path, "w", encoding="utf-8", newline="\n") as fh:
                            fh.write(cur_new)

    return buildings, {
        "hardened_buildings": hardened_buildings,
        "hardened_edges": hardened_edges,
        "zero_req_fixed": zero_req_fixed,
        "food_scaled": food_scaled,
        "written": written,
        "curated_synced": curated_synced,
    }


def audit_state(buildings, goods, plan_summary, tech_eras):
    failures = []
    # 1. Zero-hard-input industrial buildings
    zero_hard_ind = []
    ind_ratios = []
    ind_by_era = {}
    for b in buildings:
        if is_industrial_building(b) and b["in_goods"] and b["state_role"] == "none":
            hard_cnt = sum(1 for r in b["in_req"] if r >= Q16_ONE)
            if hard_cnt == 0:
                zero_hard_ind.append(b["id"])
            in_v, _, out_v, f_in, f_out = calc_values(b, goods)
            if out_v > 0 and not any(g in ("gold", "silver", "technology_points") for g in b["out_goods"]):
                r = in_v / out_v
                ind_ratios.append(r)
                ind_by_era.setdefault(b["era"], []).append(r)
            if b["chain"] in PRIMARY_FOOD_CHAINS and f_in > 0 and f_out > f_in:
                failures.append(f"food_processing_amplification: {b['id']} ({f_out}/{f_in})")

    if zero_hard_ind:
        failures.append(f"zero_hard_input_industrial ({len(zero_hard_ind)}): {zero_hard_ind[:10]}")

    med_io = statistics.median(ind_ratios) if ind_ratios else 0.0
    if not (0.45 <= med_io <= 0.70):
        failures.append(f"industrial_median_io_out_of_range: {med_io:.3f} (expected 0.45-0.70)")

    # 2. Check upgrade family monotonicity
    families = {}
    for b in buildings:
        if b["family"] and b["family"] != "research_institution" and b["out_goods"]:
            families.setdefault(b["family"], []).append(b)
    fam_fails = 0
    for fam_id, members in families.items():
        if len(members) < 2:
            continue
        members.sort(key=lambda x: x["tier"])
        is_food = any(any(g in FOOD_EQUIVALENT_GOODS for g in m["out_goods"]) for m in members)
        for i in range(1, len(members)):
            e, l = members[i - 1], members[i]
            ei, _, eo, _, ef = calc_values(e, goods)
            li, _, lo, _, lf = calc_values(l, goods)
            # Match technology_industry_chain_balance_test.gd: exact-good (non-category) inputs
            def exact_in_val(b):
                total = 0.0
                for idx, g in enumerate(b["in_goods"]):
                    cat = b["in_cats"][idx] if idx < len(b["in_cats"]) else ""
                    req = b["in_req"][idx] if idx < len(b["in_req"]) else Q16_ONE
                    if req > 0 and not cat:
                        total += (b["in_qty"][idx] / GOODS_SCALE) * goods.get(g, {}).get("price", 1.0)
                return total
            e_exact = exact_in_val(e)
            l_exact = exact_in_val(l)
            if is_food:
                if (lf / l["labor"]) <= (ef / e["labor"]):
                    failures.append(f"food_upgrade_gap: {fam_id} {e['id']}->{l['id']}")
                    fam_fails += 1
            else:
                if (lo / l["labor"]) <= (eo / e["labor"]):
                    failures.append(f"upgrade_prod_gap: {fam_id} {e['id']}->{l['id']}")
                    fam_fails += 1
                if lo <= eo:
                    failures.append(f"upgrade_out_gap: {fam_id} {e['id']}->{l['id']}")
                    fam_fails += 1
                if e_exact > 0 and l_exact > 0 and (lo / l_exact) <= (eo / e_exact):
                    failures.append(f"upgrade_yield_gap: {fam_id} {e['id']}->{l['id']}")
                    fam_fails += 1

    # 3. Check household non-food share
    print("\n=== CONSUMPTION PLANS (BASE WEALTH=1.0) ===")
    for pid, tot, fc, nfc, share in plan_summary:
        print(f"  {pid:30s}: total={tot:5.2f}  food={fc:5.2f}  nonfood={nfc:5.2f}  nonfood_share={share*100:5.1f}%")
        if pid in ("agrarian_household", "extractive_household", "industrial_worker_household", "artisan_household", "technical_household", "merchant_household", "owner_household"):
            if share < 0.34 or share > 0.58:
                failures.append(f"plan_nonfood_share_out_of_range: {pid} = {share:.3f}")

    print("\n=== INDUSTRIAL INPUT/OUTPUT VALUE RATIO BY ERA ===")
    for eid in ERA_IDS:
        vals = ind_by_era.get(eid, [])
        if vals:
            print(f"  {eid:14s}: n={len(vals):3d}  median={statistics.median(vals):.3f}  min={min(vals):.3f}  max={max(vals):.3f}")
    print(f"  OVERALL       : n={len(ind_ratios):3d}  median={med_io:.3f}  zero_hard_ind={len(zero_hard_ind)}  fam_fails={fam_fails}")

    # 4. Print food people-per-worker ladder (survival_food = 484*0.8 + 158 + 264 + 31 + 5 ≈ 845 units/day)
    print("\n=== PRIMARY FOOD PEOPLE-PER-WORKER BY ERA (at 1.0x) ===")
    for eid in ERA_IDS:
        caps = []
        for b in buildings:
            if b["era"] == eid and b["chain"] in PRIMARY_FOOD_CHAINS and b["id"] != "gathering_ground":
                _, _, _, _, fo = calc_values(b, goods)
                if fo > 0:
                    caps.append(fo / float(b["labor"]) / 845.0)
        if caps:
            print(f"  {eid:14s}: n={len(caps):2d}  median={statistics.median(caps):5.2f}  min={min(caps):5.2f}  max={max(caps):5.2f}")

    return failures


def main():
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--dry-run", action="store_true")
    group.add_argument("--apply", action="store_true")
    group.add_argument("--check", action="store_true")
    args = parser.parse_args()

    goods = load_goods()
    tech_eras = load_tech_eras()
    profs = load_professions()

    if args.check:
        # Read-only audit of current files on disk
        plan_daily_cost = {}
        plan_summary = []
        for p in sorted(glob.glob(os.path.join(PLANS_DIR, "*.tres"))):
            txt = open(p, encoding="utf-8").read()
            pid = parse_str_field(txt, "id", os.path.splitext(os.path.basename(p))[0])
            need_ids = parse_str_array(txt, "need_ids")
            base_qty = parse_num_array(txt, "base_qty_per_person")
            need_offsets = parse_num_array(txt, "need_variant_offsets")
            comp_offsets = parse_num_array(txt, "variant_component_offsets")
            comp_goods = parse_str_array(txt, "component_good_ids")
            comp_qty = parse_num_array(txt, "component_qty_per_need")
            fc = nfc = 0.0
            for ni, nid in enumerate(need_ids):
                vb, ve = need_offsets[ni], need_offsets[ni + 1]
                if ve <= vb:
                    continue
                v_costs = []
                for v in range(vb, ve):
                    vc = sum((comp_qty[c] / GOODS_SCALE) * goods.get(comp_goods[c], {}).get("price", 1.0)
                             for c in range(comp_offsets[v], comp_offsets[v + 1]))
                    v_costs.append(vc)
                c_day = (base_qty[ni] / GOODS_SCALE) * (sum(v_costs) / len(v_costs))
                if nid in FOOD_NEEDS:
                    fc += c_day
                else:
                    nfc += c_day
            tot = fc + nfc
            plan_daily_cost[pid] = tot
            plan_summary.append((pid, tot, fc, nfc, nfc / tot if tot > 0 else 0.0))
        buildings = [
            parse_building(p, tech_eras)
            for p in sorted(glob.glob(os.path.join(BUILDINGS_DIR, "*.tres")))
        ]
        failures = audit_state(buildings, goods, plan_summary, tech_eras)
        print(f"\nAUDIT FAILURES: {len(failures)}")
        for f in failures:
            print("  FAIL:", f)
        return 1 if failures else 0

    plan_daily_cost, plan_summary = rebalance_plans(goods, apply_changes=args.apply)
    buildings, stats = rebalance_buildings(goods, tech_eras, profs, plan_daily_cost, apply_changes=args.apply)
    print(f"STATS ({'APPLY' if args.apply else 'DRY-RUN'}):", stats)
    failures = audit_state(buildings, goods, plan_summary, tech_eras)
    print(f"\nPOST-REBALANCE FAILURES: {len(failures)}")
    for f in failures:
        print("  FAIL:", f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
