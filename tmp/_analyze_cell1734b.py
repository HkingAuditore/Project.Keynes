# -*- coding: utf-8 -*-
import csv, json
from pathlib import Path
from collections import defaultdict, Counter

BASE = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp")
PREFIX = BASE / "economy_record_20260924_004708_v25_cell1734_q40_r28"
mkt = PREFIX.with_name(PREFIX.name + "_market.csv")
bld = PREFIX.with_name(PREFIX.name + "_buildings.csv")

want = {
    "tools", "chipped_stone_tools", "flint", "bronze_tools", "copper_tools",
    "precision_tools", "logs", "clay", "raw_stone", "technology_points",
    "limestone", "advanced_chips",
}
series = defaultdict(list)
with mkt.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        if r["good_id"] in want:
            series[r["good_id"]].append(r)

def money(v):
    return float(v) / 10000
def goods(v):
    return float(v) / 1000
def q16(v):
    return float(v) / 65536

for gid in sorted(series):
    rs = series[gid]
    print(f"=== {gid} n={len(rs)} ===")
    for lab, r in [("first", rs[0]), ("mid", rs[len(rs) // 2]), ("last", rs[-1])]:
        print(
            f"  {lab} d={r['day_index']} p={money(r['price']):.4f} "
            f"stock={goods(r['stock']):.3f} dem={goods(r['demand_ema']):.3f} "
            f"biz={goods(r['business_demand_ema']):.3f} "
            f"des={goods(r['desired_business_demand']):.3f} "
            f"fund={goods(r['funded_business_demand']):.3f} "
            f"short={q16(r['shortage_q16']):.3f} "
            f"press={q16(r['price_pressure_total_q16']):.4f} "
            f"cost={money(r['cost_anchor_price']):.4f} "
            f"avail={goods(r['household_available_stock']):.3f} "
            f"tgt={goods(r['merchant_inventory_target']):.3f} "
            f"sf={goods(r['merchant_procurement_shortfall']):.3f} "
            f"supply={goods(r['offered_supply_ema']):.3f}"
        )

# buildings detail for candidates
print("\n=== BUILDING CANDIDATES by type_id ===")
by_type = defaultdict(list)
with bld.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        by_type[r["type_id"]].append(r)

REASONS = {
    "0": "NONE", "1": "PENDING", "2": "SUSPENDED", "3": "VACANCY",
    "4": "CAPACITY", "5": "LIVELIHOOD", "6": "SELL_THROUGH", "7": "DISCARD",
    "8": "INPUT_CHAIN", "9": "TARGET_MARGIN", "10": "PAYBACK",
    "11": "SPONSOR", "12": "MATERIALS", "13": "RESOURCE", "14": "PROB",
    "15": "MARKET_SIGNAL", "16": "GROWTH", "17": "UNSUPPORTED", "18": "NO_COST_ADV",
}

for tid in sorted(by_type, key=lambda x: int(x)):
    rs = by_type[tid]
    reasons = Counter(r.get("investment_rejection_reason") or "?" for r in rs)
    r0, r1 = rs[0], rs[-1]
    print(f"type={tid} n={len(rs)} reasons=" +
          ", ".join(f"{REASONS.get(k,k)}={v}" for k, v in reasons.most_common()))
    for lab, r in [("first", r0), ("last", r1)]:
        print(
            f"  {lab} d={r['day_index']} count={r['count']} "
            f"filled_o={r['filled_owner']}/{r['owner_required']} open={r['owner_openings']} "
            f"emp={r['employee_filled']}/{r['employee_required']} "
            f"state={r['operating_state']} cand={r.get('investment_candidate')} "
            f"rej={REASONS.get(r.get('investment_rejection_reason'), r.get('investment_rejection_reason'))} "
            f"driver={r.get('investment_driver_good_id')} "
            f"drv_p={q16(r.get('investment_driver_pressure_q16') or 0):.3f} "
            f"short={q16(r.get('investment_shortage_q16') or 0):.3f} "
            f"score={q16(r.get('investment_score_q16') or 0):.3f} "
            f"cap={r.get('investment_required_capital')} "
            f"proj={r.get('investment_projected_profit_per_day')} "
            f"opp={r.get('opportunity_owner_income_per_day')} "
            f"own_liv={r.get('owner_livelihood_required')} "
            f"own_inc={r.get('projected_owner_income_per_day')} "
            f"in={r.get('last_input')} out={r.get('last_output')} "
            f"sold={r.get('last_sold')} disc={r.get('last_discarded')} "
            f"rev={r.get('last_revenue')} margin={q16(r.get('realized_profit_margin_q16') or 0):.3f}"
        )

# cohort snapshot
coh = PREFIX.with_name(PREFIX.name + "_cohorts.csv")
print("\n=== COHORTS first/last day aggregate ===")
days = defaultdict(list)
with coh.open(encoding="utf-8", newline="") as f:
    reader = csv.DictReader(f)
    cols = reader.fieldnames
    print("cohort cols sample:", cols[:20])
    for r in reader:
        days[int(r["day_index"])].append(r)
d0, d1 = min(days), max(days)
for d in (d0, d1):
    rs = days[d]
    pop = sum(int(r.get("population") or 0) for r in rs)
    print(f"  day={d} cohorts={len(rs)} pop={pop}")
    # top professions if present
    if "profession_id" in cols:
        pc = Counter()
        for r in rs:
            pc[r["profession_id"]] += int(r.get("population") or 0)
        print("    professions:", pc.most_common(8))
