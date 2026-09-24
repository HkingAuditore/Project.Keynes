# -*- coding: utf-8 -*-
"""Map dense type_id -> building by matching recorded last_output / count to recipe qty."""
import csv, re
from pathlib import Path
from collections import defaultdict

bdir = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\Project\project-keynes\data\economy\buildings")
recipes = {}
for p in bdir.glob("*.tres"):
    t = p.read_text(encoding="utf-8")
    bid = re.search(r'^id = &\"([^\"]+)\"', t, re.M)
    oq = re.search(r"output_quantities_per_day = PackedInt64Array\(([^)]*)\)", t)
    oid = re.search(r"output_good_ids = PackedStringArray\(([^)]*)\)", t)
    mq = re.search(r"input_min_quality_levels = PackedInt32Array\(([^)]*)\)", t)
    iq = re.search(r"input_quantities_per_day = PackedInt64Array\(([^)]*)\)", t)
    ic = re.search(r"input_category_ids = PackedStringArray\(([^)]*)\)", t)
    if not bid:
        continue
    qtys = []
    if oq and oq.group(1).strip():
        qtys = [int(x.strip()) for x in oq.group(1).split(",") if x.strip()]
    goods = []
    if oid and oid.group(1).strip():
        goods = re.findall(r'\"([^\"]+)\"', oid.group(1))
    minq = []
    if mq and mq.group(1).strip():
        minq = [int(x.strip()) for x in mq.group(1).split(",") if x.strip()]
    inqty = []
    if iq and iq.group(1).strip():
        inqty = [int(x.strip()) for x in iq.group(1).split(",") if x.strip()]
    recipes[bid.group(1)] = {
        "qtys": qtys, "goods": goods, "minq": minq, "inqty": inqty,
        "sum_out": sum(qtys) if qtys else 0,
        "first_out": qtys[0] if qtys else 0,
    }

# from CSV: for each type, when count>0, last_output / (count * epoch_days?)
# epoch might be 1 day in recorder sample
bld = Path(r"d:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260924_004708_v25_cell1734_q40_r28_buildings.csv")
samples = {}
with bld.open(encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        c = int(r["count"] or 0)
        if c <= 0:
            continue
        out = int(r["last_output"] or 0)
        tid = r["type_id"]
        # per building per day estimate
        per = out / c if c else 0
        samples.setdefault(tid, []).append((int(r["day_index"]), c, out, per, r["operating_state"]))

print("=== type_id -> likely building (by first_out match) ===")
for tid, rows in sorted(samples.items(), key=lambda x: int(x[0])):
    # use early row with output
    rows_out = [x for x in rows if x[2] > 0]
    if not rows_out:
        print(f"type {tid}: no output samples, states={set(x[4] for x in rows)} counts={[x[1] for x in rows[:3]]}")
        continue
    d, c, out, per, st = rows_out[0]
    # match first_out within 5% or exact
    hits = []
    for bid, rec in recipes.items():
        if rec["first_out"] <= 0:
            continue
        # last_output may be sum of all outputs * days * util
        if abs(rec["first_out"] - per) / max(rec["first_out"], 1) < 0.08:
            hits.append((bid, rec["first_out"], rec["goods"], rec["minq"], rec["inqty"]))
        elif abs(rec["sum_out"] - per) / max(rec["sum_out"], 1) < 0.08:
            hits.append((bid + "(sum)", rec["sum_out"], rec["goods"], rec["minq"], rec["inqty"]))
    print(f"type {tid}: early d={d} count={c} out={out} per={per:.1f} state={st}")
    if hits:
        for h in hits[:8]:
            print(f"  ~ {h[0]} first/sum={h[1]} goods={h[2]} minq={h[3]} inqty={h[4]}")
    else:
        # nearest
        nearest = sorted(recipes.items(), key=lambda kv: abs(kv[1]["first_out"] - per) if kv[1]["first_out"] else 1e18)[:5]
        for bid, rec in nearest:
            print(f"  ? {bid} first={rec['first_out']} goods={rec['goods']} minq={rec['minq']}")

# also list active buildings needing tools and their minq from hits
print("\n=== operating collectors that need tools (inferred) ===")
