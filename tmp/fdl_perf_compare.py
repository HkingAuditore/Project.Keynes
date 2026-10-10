import csv
import sys

base_path, head_path = sys.argv[1], sys.argv[2]


def load(path):
    return list(csv.DictReader(open(path, encoding="utf-8", errors="replace")))


def stats(rows, col):
    values = []
    for r in rows:
        try:
            values.append(float(r[col]))
        except (KeyError, ValueError):
            pass
    if not values:
        return None
    values.sort()
    p95 = values[min(len(values) - 1, int(round(0.95 * (len(values) - 1))))]
    return sum(values) / len(values), p95, values[-1]


base, head = load(base_path), load(head_path)
cols = [c for c in head[0].keys() if c.startswith("t_") or "family" in c or "economy" in c and c.endswith("_ms")]
print(f"{'column':48s} {'base avg/p95/max':>28s} {'head avg/p95/max':>28s}")
for col in cols:
    b, h = stats(base, col), stats(head, col)
    if h is None or b is None or (h[2] == 0 and b[2] == 0):
        continue
    fmt = lambda s: f"{s[0]:8.3f}/{s[1]:8.3f}/{s[2]:8.3f}"
    print(f"{col:48s} {fmt(b):>28s} {fmt(h):>28s}")
