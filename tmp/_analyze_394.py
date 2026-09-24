# -*- coding: utf-8 -*-
import csv, re
from pathlib import Path
from collections import defaultdict, Counter

PREFIX = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260924_012547_v25_cell632_q27_r10")
bld = PREFIX.with_name(PREFIX.name + "_buildings.csv")

rows394 = []
with bld.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        if r["type_id"] == "394":
            rows394.append(r)

print("type394 n", len(rows394))
by_day = {}
for r in rows394:
    d = int(r["day_index"])
    by_day.setdefault(d, []).append(r)

days = sorted(by_day)
series = []
for d in days:
    total = sum(int(r["count"] or 0) for r in by_day[d])
    ok = any(r.get("investment_candidate") == "1" and r.get("investment_rejection_reason") == "0"
             for r in by_day[d])
    series.append((d, total, ok))

prev = -1
changes = []
for d, total, ok in series:
    if total != prev:
        changes.append((d, prev, total, ok))
        prev = total
print("count changes first 50:")
for c in changes[:50]:
    print(" ", c)
print("total changes", len(changes), "last5", changes[-5:])

print("rej", Counter(r.get("investment_rejection_reason")
                     for r in rows394 if r.get("investment_candidate") == "1"))

r_last = None
for r in rows394:
    if int(r["count"] or 0) > 0:
        r_last = r
keys = ["day_index", "count", "filled_owner", "owner_required", "owner_capacity",
        "last_output", "last_sold", "last_discarded", "last_revenue", "last_input",
        "last_input_cost", "realized_profit_margin_q16", "operating_state",
        "investment_driver_good_id", "planned_utilization_q16", "capacity_q16",
        "purchase_intent_capacity_q16", "investment_projected_profit_per_day",
        "investment_score_q16", "investment_selected_material_good_ids"]
print("sample operating", {k: r_last.get(k) for k in keys})
per = int(r_last["last_output"]) / int(r_last["count"]) if r_last else 0
print("per building output", per)

bdir = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\economy\buildings")
hits = []
for p in bdir.glob("*.tres"):
    t = p.read_text(encoding="utf-8")
    bid = re.search(r'^id = &\"([^\"]+)\"', t, re.M)
    oq = re.search(r"output_quantities_per_day = PackedInt64Array\(([^)]*)\)", t)
    oid = re.search(r"output_good_ids = PackedStringArray\(([^)]*)\)", t)
    dn = re.search(r'display_name = \"([^\"]*)\"', t)
    if not bid or not oq or not oq.group(1).strip():
        continue
    qtys = [int(x.strip()) for x in oq.group(1).split(",") if x.strip()]
    goods = re.findall(r'\"([^\"]+)\"', oid.group(1)) if oid else []
    if qtys and abs(qtys[0] - per) / max(qtys[0], 1) < 0.12:
        hits.append((bid.group(1), dn.group(1) if dn else "", qtys[0], goods))
print("hits:")
for h in hits[:20]:
    print(" ", h)

# growth rate: buildings per day when growing
growing = [(a, b) for a, b in zip(changes, changes[1:]) if b[2] > b[1] and b[1] >= 0]
print("growth steps sample:")
for (d0, p0, c0, _), (d1, p1, c1, ok) in growing[:20]:
    print(f"  {d0}->{d1}: {c0}->{c1} (+{c1-c0}) over {d1-d0}d ok_flag={ok}")

# owners vs pop
coh = PREFIX.with_name(PREFIX.name + "_cohorts.csv")
pop_by_day = {}
with coh.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        d = int(r["day_index"])
        pop_by_day[d] = pop_by_day.get(d, 0) + int(r["population"] or 0)

print("\ncount vs pop at milestones:")
for d, _, total, _ in changes[:: max(1, len(changes)//10)]:
    print(f"  d={d} buildings={total} pop={pop_by_day.get(d)} filled_rows=",
          [(r["filled_owner"], r["owner_required"], r["count"]) for r in by_day[d]])
