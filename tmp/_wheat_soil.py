# -*- coding: utf-8 -*-
import csv
from pathlib import Path

PREFIX = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260924_012547_v25_cell632_q27_r10")
mkt = PREFIX.with_name(PREFIX.name + "_market.csv")
res = PREFIX.with_name(PREFIX.name + "_resources.csv")

def goods(v):
    return float(v) / 1000
def q16(v):
    return float(v) / 65536

rows = []
with mkt.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        if r["good_id"] == "wheat_grain":
            rows.append(r)
print("wheat_grain", len(rows))
for target in [7652, 10039, 10621, 12000, 13590]:
    r = min(rows, key=lambda x: abs(int(x["day_index"]) - target))
    print(
        f"  d={r['day_index']} p={float(r['price'])/10000:.3f} stock={goods(r['stock']):.2f} "
        f"dem={goods(r['demand_ema']):.3f} biz={goods(r['business_demand_ema']):.3f} "
        f"des={goods(r['desired_business_demand']):.3f} short={q16(r['shortage_q16']):.3f} "
        f"press={q16(r['price_pressure_total_q16']):.3f} supply={goods(r['offered_supply_ema']):.3f}"
    )

rows = []
with res.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        if r["resource_id"] == "fertile_soil":
            rows.append(r)
print("fertile_soil", len(rows))
for target in [7652, 10039, 10621, 13590]:
    r = min(rows, key=lambda x: abs(int(r["day_index"]) - target))
    print(
        f"  d={r['day_index']} reserve={r['reserve']} safe={r['safe_yield']} "
        f"extract_app={r['artificial_extraction_applied']} dens={r['stock_density_q16']}"
    )
