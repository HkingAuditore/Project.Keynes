import collections
import csv
import glob
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else max(
    glob.glob(os.path.join(os.path.dirname(__file__), "family_probe_*")), key=os.path.getmtime)
print("probe", root)
rows = list(csv.DictReader(open(os.path.join(root, "families.csv"), encoding="utf-8", errors="replace")))
f = lambda r, k: int(r[k] or 0)
by = collections.defaultdict(list)
for r in rows:
    by[r["family_handle"]].append(r)
for h, rs in by.items():
    a, b = rs[0], rs[-1]
    print(h, a["day"], "pop", f(a, "population"), "->", f(b, "population"),
          "cash", f(a, "cash_claim") // 10**6, "->", f(b, "cash_claim") // 10**6,
          "nw", f(a, "net_worth") // 10**6, "->", f(b, "net_worth") // 10**6,
          "own", f(a, "owned_buildings"), "->", f(b, "owned_buildings"),
          "s", round(f(a, "home_share_q16") / 65536, 3), "->", round(f(b, "home_share_q16") / 65536, 3),
          "t", round(f(b, "home_target_share_q16") / 65536, 3),
          "D", round(f(b, "home_distress_q16") / 65536, 3))
days = sorted({int(r["day"]) for r in rows})
mx, md = 0.0, None
for d in days:
    s = collections.defaultdict(float)
    t = collections.defaultdict(float)
    for r in rows:
        if int(r["day"]) == d:
            s[r["home_cell"]] += f(r, "home_share_q16") / 65536
            t[r["home_cell"]] += f(r, "home_target_share_q16") / 65536
    cell = max(s, key=s.get)
    if s[cell] > mx:
        mx, md = s[cell], (d, cell, round(t[cell], 3))
print("max home-cell share sum", round(mx, 3), "(day, cell, target sum)", md)
first = [r for r in rows if int(r["day"]) == days[0]]
last = [r for r in rows if int(r["day"]) == days[-1]]
print("families", len(first), "->", len(last),
      "people", sum(f(r, "population") for r in first), "->", sum(f(r, "population") for r in last))
events = collections.Counter(r["event"] for r in csv.DictReader(open(os.path.join(root, "events.csv"))))
print("events", dict(events))
