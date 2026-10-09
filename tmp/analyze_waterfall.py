import csv
import sys
from collections import defaultdict

path = sys.argv[1]
min_day = int(sys.argv[2]) if len(sys.argv) > 2 else 2000
cost_path = sys.argv[3] if len(sys.argv) > 3 else None

rows = []
with open(path, newline="") as f:
    reader = csv.DictReader(f)
    header = reader.fieldnames
    for r in reader:
        try:
            if int(r["day"]) >= min_day:
                rows.append(r)
        except (TypeError, ValueError):
            pass

segs = header[4:-2]
committed = [r for r in rows if r["committed"] == "1"]
failed = [r for r in rows if r["committed"] != "1"]
days = len({r["day"] for r in committed})
print(f"rows={len(rows)} committed={len(committed)} failed_attempts={len(failed)} days={days}")

totals = defaultdict(float)
for r in rows:
    for s in segs + ["total", "residual"]:
        totals[s] += float(r[s])

grand = totals["total"] / max(days, 1)
print(f"\nper committed day (all attempts) total={grand:.3f} ms")
for s in sorted(segs, key=lambda k: -totals[k]):
    v = totals[s] / max(days, 1)
    if v >= 0.01:
        print(f"  {s:28s} {v:8.3f} ms  {100*v/grand:5.1f}%")
print(f"  {'residual':28s} {totals['residual']/max(days,1):8.3f}")

if failed:
    ft = defaultdict(float)
    for r in failed:
        for s in segs + ["total"]:
            ft[s] += float(r[s])
    print(f"\nfailed attempts: {len(failed)}, total per day {ft['total']/max(days,1):.3f} ms")
    for s in sorted(segs, key=lambda k: -ft[k])[:8]:
        print(f"  {s:28s} {ft[s]/max(days,1):8.3f}")

def pct(vals, p):
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(p * len(vals)))] if vals else 0

print("\ncommitted-row distribution (p50/p90/max):")
for s in ["total"] + sorted(segs, key=lambda k: -totals[k])[:10]:
    vals = [float(r[s]) for r in committed]
    print(f"  {s:28s} {pct(vals,.5):8.3f} {pct(vals,.9):8.3f} {max(vals) if vals else 0:8.3f}")

if cost_path:
    agg = defaultdict(lambda: [0.0, 0, 0])
    with open(cost_path, newline="") as f:
        for r in csv.reader(f):
            if len(r) < 4:
                continue
            try:
                day = int(r[0])
                ms = float(r[3])
                work = int(float(r[2]))
            except ValueError:
                continue
            if day < min_day:
                continue
            a = agg[r[1]]
            a[0] += ms
            a[1] += 1
            a[2] += work
    print("\ncost probes (ms per committed day, calls):")
    for name, (ms, n, units) in sorted(agg.items(), key=lambda kv: -kv[1][0]):
        if ms / max(days, 1) >= 0.05 or name.startswith("mirror."):
            print(f"  {name:44s} {ms/max(days,1):8.3f}  n={n:5d}  units/call={units//max(n,1)}")
