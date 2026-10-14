import re, sys
from collections import defaultdict

def load(path, days):
    out = defaultdict(list)
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^(\[[\w\-]+\])\s.*?\bday=(-?\d+)", line)
        if not m:
            continue
        d = int(m.group(2))
        if d in days:
            out[(m.group(1), d)].append(line.rstrip("\n"))
    return out

a_path, b_path = sys.argv[1], sys.argv[2]
days = set(int(x) for x in sys.argv[3].split(","))
a = load(a_path, days)
b = load(b_path, days)
for key in sorted(set(a) | set(b), key=lambda k: (k[1], k[0])):
    la, lb = a.get(key, []), b.get(key, [])
    if la == lb:
        continue
    print("==", key, len(la), len(lb))
    for x, y in zip(la, lb):
        if x == y:
            continue
        ta, tb = x.split(), y.split()
        diffs = [(p, q) for p, q in zip(ta, tb) if p != q]
        print("  ", [p.split("=")[0] for p, _ in diffs][:40])
        if len(diffs) <= 6:
            print("    A:", [p for p, _ in diffs])
            print("    B:", [q for _, q in diffs])
