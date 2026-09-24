# -*- coding: utf-8 -*-
import csv
from pathlib import Path
from collections import defaultdict, Counter

PREFIX = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260924_012547_v25_cell632_q27_r10")
REJ = {
    "0": "NONE", "1": "PENDING", "2": "SUSPENDED", "3": "VACANCY",
    "4": "CAPACITY_OK", "5": "LIVELIHOOD", "6": "SELL_THROUGH", "7": "DISCARD",
    "8": "INPUT_CHAIN", "9": "MARGIN", "10": "PAYBACK", "11": "SPONSOR",
    "12": "MATERIALS", "13": "RESOURCE", "14": "PROB", "15": "MARKET_SIGNAL",
    "16": "GROWTH", "17": "UNSUPPORTED", "18": "NO_COST_ADV",
}

def money(v): return float(v)/10000 if v else 0
def goods(v): return float(v)/1000 if v else 0
def q16(v): return float(v)/65536 if v else 0

# summary
sum_path = PREFIX.with_name(PREFIX.name + "_summary.csv")
with sum_path.open(encoding="utf-8", newline="") as f:
    srows = list(csv.DictReader(f))
print(f"SUMMARY epochs={len(srows)} days={srows[0]['day_index']}..{srows[-1]['day_index']}")
for k in ["building_investments_started","building_investment_buildings_started",
          "building_investment_types_started","building_investment_demand_limited",
          "building_investment_material_limited","building_investment_capital_limited",
          "building_investment_owner_population_limited","building_investment_probability_skips"]:
    vals=[int(r.get(k) or 0) for r in srows]
    print(f"  {k}: sum={sum(vals)} max={max(vals)} last={vals[-1]}")

# buildings trajectory by type
bld = PREFIX.with_name(PREFIX.name + "_buildings.csv")
by_day_type = defaultdict(lambda: defaultdict(lambda: {"count":0,"cand":0,"rej":Counter(),"out":0,"sold":0,"disc":0,"driver":Counter()}))
type_all = defaultdict(list)
with bld.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        tid=r["type_id"]; d=int(r["day_index"])
        type_all[tid].append(r)
        slot=by_day_type[d][tid]
        c=int(r["count"] or 0)
        slot["count"]+=c
        slot["out"]+=int(r["last_output"] or 0)
        slot["sold"]+=int(r["last_sold"] or 0)
        slot["disc"]+=int(r["last_discarded"] or 0)
        if r.get("investment_candidate")=="1":
            slot["cand"]+=1
            slot["rej"][REJ.get(r.get("investment_rejection_reason"), r.get("investment_rejection_reason"))]+=1
            slot["driver"][r.get("investment_driver_good_id")]+=1

days=sorted(by_day_type)
print(f"\nBUILDING days={days[0]}..{days[-1]} types={sorted(type_all,key=int)}")

# pick types that ever had high count
print("\n=== COUNT TRAJECTORY (types with max count>=5) ===")
for tid in sorted(type_all, key=int):
    series=[(d, by_day_type[d][tid]["count"]) for d in days]
    mx=max(c for _,c in series)
    if mx < 5 and tid not in ("134","94","22","45","113"):
        # still show tool-related candidates
        pass
    if mx < 5:
        continue
    first=series[0]; last=series[-1]
    # find when jumped
    jumps=[]
    prev=series[0][1]
    for d,c in series[1:]:
        if c-prev>=10:
            jumps.append((d,prev,c))
        prev=c
    print(f"type={tid} first={first} last={last} max={mx} jumps(>=+10)={jumps[:8]}{'...' if len(jumps)>8 else ''}")

print("\n=== FOCUS CANDIDATE REJECTIONS (all days aggregated) ===")
for tid in sorted(type_all, key=int):
    rs=type_all[tid]
    cand=[r for r in rs if r.get("investment_candidate")=="1"]
    if not cand and max(int(r["count"] or 0) for r in rs)<1:
        continue
    reasons=Counter(REJ.get(r.get("investment_rejection_reason"),"?") for r in cand) if cand else Counter()
    counts=[int(r["count"] or 0) for r in rs]
    print(f"type={tid} max_count={max(counts)} cand_n={len(cand)} rej={dict(reasons.most_common(5))}")
    if cand:
        r=cand[0]; r2=cand[-1]
        for lab,rr in [("first",r),("last",r2)]:
            print(f"  {lab} d={rr['day_index']} count={rr['count']} rej={REJ.get(rr.get('investment_rejection_reason'))} "
                  f"driver={rr.get('investment_driver_good_id')} short={q16(rr.get('investment_shortage_q16') or 0):.3f} "
                  f"util={q16(rr.get('investment_utilization_q16') or 0):.4f} proj={rr.get('investment_projected_profit_per_day')} "
                  f"score={q16(rr.get('investment_score_q16') or 0):.3f} mats={rr.get('investment_selected_material_good_ids')}")

# market tools / food
mkt=PREFIX.with_name(PREFIX.name+"_market.csv")
want={"chipped_stone_tools","bronze_tools","copper_tools","tools","precision_tools","flint",
      "gathered_plants","game_meat","logs","prepared_staples","grain"}
series=defaultdict(list)
with mkt.open(encoding="utf-8",newline="") as f:
    for r in csv.DictReader(f):
        if r["good_id"] in want:
            series[r["good_id"]].append(r)

print("\n=== MARKET first/mid/last ===")
for gid in sorted(series):
    rs=series[gid]
    for lab,r in [("first",rs[0]),("mid",rs[len(rs)//2]),("last",rs[-1])]:
        print(f"  {gid} {lab} d={r['day_index']} p={money(r['price']):.3f} stock={goods(r['stock']):.1f} "
              f"dem={goods(r['demand_ema']):.3f} biz={goods(r['business_demand_ema']):.3f} "
              f"des={goods(r['desired_business_demand']):.3f} fund={goods(r['funded_business_demand']):.3f} "
              f"short={q16(r['shortage_q16']):.3f} press={q16(r['price_pressure_total_q16']):.3f}")

# cohort pop
coh=PREFIX.with_name(PREFIX.name+"_cohorts.csv")
day_pop=defaultdict(int)
with coh.open(encoding="utf-8",newline="") as f:
    for r in csv.DictReader(f):
        # handle BOM
        d=int(r.get("day_index") or r.get("\ufeffepoch_row_id") and r["day_index"])
        day_pop[int(r["day_index"])]+=int(r["population"] or 0)
print(f"\nPOP first={day_pop[min(day_pop)]} last={day_pop[max(day_pop)]} days={min(day_pop)}..{max(day_pop)}")
