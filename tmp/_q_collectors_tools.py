# -*- coding: utf-8 -*-
import csv
from pathlib import Path
from collections import defaultdict, Counter

PREFIX = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260924_004708_v25_cell1734_q40_r28")
REJ = {
    "0": "NONE", "1": "PENDING", "2": "SUSPENDED", "3": "VACANCY",
    "4": "CAPACITY_OK", "5": "LIVELIHOOD", "6": "SELL_THROUGH", "7": "DISCARD",
    "8": "INPUT_CHAIN", "9": "MARGIN", "10": "PAYBACK", "11": "SPONSOR",
    "12": "MATERIALS", "13": "RESOURCE", "14": "PROB", "15": "MARKET_SIGNAL",
    "16": "GROWTH", "17": "UNSUPPORTED", "18": "NO_COST_ADV",
}

# Prior map from earlier sessions + infer from drivers
# type ids from buildings.csv
bld = PREFIX.with_name(PREFIX.name + "_buildings.csv")
by = defaultdict(list)
with bld.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        by[r["type_id"]].append(r)

print("=== ALL TYPES in cell1734 ===")
for tid in sorted(by, key=int):
    rs = by[tid]
    # prefer rows with count>0 for identity
    active = [r for r in rs if int(r["count"] or 0) > 0]
    sample = active[0] if active else rs[0]
    reasons = Counter(REJ.get(r.get("investment_rejection_reason"), r.get("investment_rejection_reason")) for r in rs)
    cand = sum(1 for r in rs if r.get("investment_candidate") == "1")
    drivers = Counter(r.get("investment_driver_good_id") for r in rs if r.get("investment_candidate") == "1")
    print(f"type={tid} n={len(rs)} cand={cand} count0={sample['count']} state0={sample['operating_state']} "
          f"out0={sample['last_output']} sold0={sample['last_sold']} disc0={sample['last_discarded']} "
          f"rev0={sample['last_revenue']} margin0={sample['realized_profit_margin_q16']}")
    print(f"  reasons={dict(reasons.most_common(6))} drivers={drivers.most_common(4)}")
    # last day with count>0
    lasts = [r for r in rs if int(r["day_index"]) == int(rs[-1]["day_index"])]
    for r in lasts:
        print(f"  last d={r['day_index']} count={r['count']} state={r['operating_state']} "
              f"filled={r['filled_owner']}/{r['owner_required']} cand={r.get('investment_candidate')} "
              f"rej={REJ.get(r.get('investment_rejection_reason'))} driver={r.get('investment_driver_good_id')} "
              f"short={r.get('investment_shortage_q16')} util={r.get('investment_utilization_q16')} "
              f"proj={r.get('investment_projected_profit_per_day')} out={r.get('last_output')} "
              f"sold={r.get('last_sold')} disc={r.get('last_discarded')}")

# market goods that look like gatherer outputs
mkt = PREFIX.with_name(PREFIX.name + "_market.csv")
want = set()
# read first day all goods with stock or demand
first_day = None
goods_first = {}
goods_last = {}
with mkt.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        d = int(r["day_index"])
        if first_day is None:
            first_day = d
        if d == first_day:
            goods_first[r["good_id"]] = r
        goods_last[r["good_id"]] = r  # ends at last

print("\n=== GOODS with stock/dem/biz (first day) top by stock ===")
def g(v): return float(v)/1000
def m(v): return float(v)/10000
rows = []
for gid, r in goods_first.items():
    stock = g(r["stock"]); dem=g(r["demand_ema"]); biz=g(r["business_demand_ema"])
    if stock > 0 or dem > 0 or biz > 0:
        rows.append((stock, dem, biz, gid, m(r["price"]), float(r["price_pressure_total_q16"])/65536))
rows.sort(reverse=True)
for t in rows[:25]:
    print(f"  {t[3]}: stock={t[0]:.1f} dem={t[1]:.3f} biz={t[2]:.3f} p={t[4]:.2f} press={t[5]:.3f}")

print("\n=== SAME goods last day ===")
rows2 = []
for gid, r in goods_last.items():
    stock = g(r["stock"]); dem=g(r["demand_ema"]); biz=g(r["business_demand_ema"])
    if stock > 0 or dem > 0 or biz > 0 or gid in ("chipped_stone_tools","tools","bronze_tools","copper_tools","flint","game_meat","gathered_plants","fur","hides","logs"):
        rows2.append((stock+dem+biz, gid, stock, dem, biz, m(r["price"]), float(r["shortage_q16"])/65536, float(r["price_pressure_total_q16"])/65536, g(r.get("desired_business_demand") or 0)))
rows2.sort(reverse=True)
for t in rows2[:30]:
    print(f"  {t[1]}: stock={t[2]:.1f} dem={t[3]:.3f} biz={t[4]:.3f} des={t[8]:.3f} p={t[5]:.2f} short={t[6]:.3f} press={t[7]:.3f}")
