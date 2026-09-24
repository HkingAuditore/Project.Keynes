# -*- coding: utf-8 -*-
import csv
from collections import defaultdict, Counter
from pathlib import Path

PREFIX = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260924_004708_v25_cell1734_q40_r28")
GOODS = [
    "soft_tools", "chipped_stone_tools", "flint", "wood", "firewood",
    "grain", "meat", "hides", "knowledge", "raw_clay",
]
TYPES = [
    "knapping_workshop", "flint_quarry", "carpenter_workshop",
    "logging_camp", "farmstead", "hunter_camp", "scribe_house",
]

def money(v):
    return float(v) / 10000.0 if v not in (None, "") else 0.0

def goods(v):
    return float(v) / 1000.0 if v not in (None, "") else 0.0

def q16(v):
    return float(v) / 65536.0 if v not in (None, "") else 0.0

# --- summary investment trajectory ---
sum_path = PREFIX.with_name(PREFIX.name + "_summary.csv")
with sum_path.open(encoding="utf-8", newline="") as f:
    rows = list(csv.DictReader(f))
print("=== SUMMARY ===")
print(f"epochs={len(rows)} days={rows[0]['day_index']}..{rows[-1]['day_index']}")
keys = [
    "building_investments_started",
    "building_investment_blocked_funds",
    "building_investment_blocked_materials",
    "building_investment_blocked_sponsor_capital",
    "building_investment_blocked_resources",
    "building_investment_probability_skips",
    "building_investment_demand_limited",
    "building_investment_material_limited",
    "building_investment_capital_limited",
    "building_investment_owner_population_limited",
]
for k in keys:
    vals = [int(r[k]) for r in rows]
    print(f"  {k}: sum={sum(vals)} first={vals[0]} last={vals[-1]} max={max(vals)}")

# --- market focus ---
mkt_path = PREFIX.with_name(PREFIX.name + "_market.csv")
mkt = defaultdict(list)
with mkt_path.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        gid = r["good_id"]
        if gid in GOODS:
            mkt[gid].append(r)

print("\n=== MARKET (selected goods) first/mid/last ===")
for gid in GOODS:
    rs = mkt.get(gid, [])
    if not rs:
        print(f"  {gid}: MISSING")
        continue
    for label, r in [("first", rs[0]), ("mid", rs[len(rs)//2]), ("last", rs[-1])]:
        print(
            f"  {gid} {label} d={r['day_index']} price={money(r['price']):.4f} "
            f"stock={goods(r['stock']):.3f} dem={goods(r['demand_ema']):.3f} "
            f"biz={goods(r['business_demand_ema']):.3f} "
            f"des={goods(r.get('desired_business_demand','0')):.3f} "
            f"fund={goods(r.get('funded_business_demand','0')):.3f} "
            f"unfund={goods(r.get('unfunded_business_demand','0')):.3f} "
            f"short={q16(r['shortage_q16']):.3f} press={q16(r['price_pressure_total_q16']):.3f} "
            f"cost={money(r['cost_anchor_price']):.4f} "
            f"proc_sf={goods(r['merchant_procurement_shortfall']):.3f}"
        )

# price series extremes for flint / tools
print("\n=== PRICE SERIES extrema ===")
for gid in ["flint", "chipped_stone_tools", "soft_tools", "knowledge"]:
    rs = mkt.get(gid, [])
    if not rs:
        continue
    prices = [(int(r["day_index"]), money(r["price"]), q16(r["price_pressure_total_q16"]), goods(r["business_demand_ema"]), goods(r.get("desired_business_demand","0"))) for r in rs]
    pmin = min(prices, key=lambda x: x[1])
    pmax = max(prices, key=lambda x: x[1])
    press_max = max(prices, key=lambda x: x[2])
    print(f"  {gid}: n={len(prices)} pmin={pmin} pmax={pmax} press_max={press_max}")
    # first 10 and last 10 price
    print(f"    early: {[round(p[1],4) for p in prices[:8]]}")
    print(f"    late:  {[round(p[1],4) for p in prices[-8:]]}")
    print(f"    press early: {[round(p[2],3) for p in prices[:8]]}")
    print(f"    press late:  {[round(p[2],3) for p in prices[-8:]]}")
    print(f"    biz early: {[round(p[3],3) for p in prices[:8]]}")
    print(f"    des early: {[round(p[4],3) for p in prices[:8]]}")

# --- buildings ---
bld_path = PREFIX.with_name(PREFIX.name + "_buildings.csv")
rej = Counter()
type_stats = defaultdict(lambda: Counter())
candidates = []
with bld_path.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        tid = r["type_id"]
        if tid not in TYPES and not r.get("investment_candidate") == "1":
            # still count rejection for all
            pass
        reason = r.get("investment_rejection_reason") or ""
        if reason:
            rej[reason] += 1
            if tid in TYPES or r.get("investment_candidate") == "1":
                type_stats[tid][reason] += 1
        if tid in TYPES:
            candidates.append(r)

print("\n=== INVESTMENT REJECTIONS (all types, top) ===")
for k, v in rej.most_common(20):
    print(f"  {k}: {v}")

print("\n=== FOCUS TYPES rejection + sample rows ===")
# group by type, take first/last appearance
by_type = defaultdict(list)
for r in candidates:
    by_type[r["type_id"]].append(r)
for tid in TYPES:
    rs = by_type.get(tid, [])
    if not rs:
        print(f"  {tid}: no rows")
        continue
    reasons = Counter(r.get("investment_rejection_reason") or "(empty)" for r in rs)
    print(f"  {tid}: n={len(rs)} reasons={dict(reasons)}")
    for label, r in [("first", rs[0]), ("last", rs[-1])]:
        print(
            f"    {label} d={r['day_index']} cand={r.get('investment_candidate')} "
            f"rej={r.get('investment_rejection_reason')} score={q16(r.get('investment_score_q16') or 0):.3f} "
            f"short={q16(r.get('investment_shortage_q16') or 0):.3f} "
            f"driver={r.get('investment_driver_good_id')} "
            f"drv_press={q16(r.get('investment_driver_pressure_q16') or 0):.3f} "
            f"cap={r.get('investment_required_capital')} "
            f"proj={r.get('investment_projected_profit_per_day')} "
            f"opp={r.get('opportunity_owner_income_per_day')} "
            f"own_liv={r.get('owner_livelihood_required')} "
            f"own_inc={r.get('projected_owner_income_per_day')} "
            f"filled_o={r.get('filled_owner')} open={r.get('owner_openings')} "
            f"state={r.get('operating_state')}"
        )

# soft_tools / chipped producers present?
print("\n=== ALL type_ids with investment_candidate=1 (top) ===")
cand_types = Counter()
cand_rej = Counter()
with bld_path.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        if r.get("investment_candidate") == "1":
            cand_types[r["type_id"]] += 1
            cand_rej[(r["type_id"], r.get("investment_rejection_reason") or "(ok)")] += 1
for tid, n in cand_types.most_common(30):
    print(f"  {tid}: {n}")
print("top cand+rej:")
for (tid, reason), n in cand_rej.most_common(25):
    print(f"  {tid} | {reason}: {n}")
