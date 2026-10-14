import glob
import re
import sys
from collections import defaultdict

LINE = re.compile(r"\[headless-perf/watch\] day=(\d+) cell=(\d+) pop=(\d+) access=([\d.]+) "
                  r"load=([\d.]+) living_cost=(\d+) jobs=(\S*) goods=(\S*)")


def parse(label):
    path = sorted(glob.glob(f"tmp/headless_perf_*_{label}.log"))[-1]
    rows = {}
    head = open(path, "rb").read(2)
    encoding = "utf-16" if head in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
    for line in open(path, encoding=encoding, errors="replace"):
        m = LINE.search(line)
        if not m:
            continue
        day, cell, pop = int(m[1]) // 365, int(m[2]), int(m[3])
        jobs = {}
        for item in m[7].split(","):
            parts = item.split(":")
            if len(parts) >= 4:
                jobs[parts[0]] = (int(parts[1]), float(parts[2]), float(parts[3]))
        goods = {}
        for item in m[8].split(","):
            g = re.match(r"(\w+):p(-?\d+)/s(-?\d+)/d(-?\d+)", item)
            if g:
                goods[g[1]] = (int(g[2]), int(g[3]), int(g[4]))
        rows[(day, cell)] = dict(pop=pop, load=float(m[5]), living=int(m[6]), jobs=jobs, goods=goods)
    return rows


def weighted(jobs, idx):
    people = sum(v[0] for v in jobs.values())
    return sum(v[0] * v[idx] for v in jobs.values()) / people if people else 0.0


base, fix = parse(sys.argv[1]), parse(sys.argv[2])
days = sorted({d for d, _ in base} & {d for d, _ in fix})
print("day   pop b/f      load b/f    sat_all b/f  forager n b/f   forager sat b/f  forager save b/f  living b/f   plants_p b/f")
for day in days:
    cells = sorted({c for d, c in base if d == day} & {c for d, c in fix if d == day})
    agg = defaultdict(float)
    for c in cells:
        for tag, rows in (("b", base), ("f", fix)):
            r = rows[(day, c)]
            agg[tag + "pop"] += r["pop"]
            agg[tag + "load"] += r["load"] / len(cells)
            agg[tag + "satw"] += weighted(r["jobs"], 2) * r["pop"]
            fo = r["jobs"].get("forager", (0, 0.0, 0.0))
            agg[tag + "fn"] += fo[0]
            agg[tag + "fsat"] += fo[2] * fo[0]
            agg[tag + "fsave"] += fo[1] * fo[0]
            agg[tag + "living"] += r["living"] / len(cells)
            agg[tag + "pp"] += r["goods"].get("gathered_plants", (0, 0, 0))[0] / len(cells)
    def ratio(tag, key, denom):
        return agg[tag + key] / agg[tag + denom] if agg[tag + denom] else 0.0
    print(f"{day:5d} {agg['bpop']:5.0f}/{agg['fpop']:<5.0f}  {agg['bload']:4.2f}/{agg['fload']:<4.2f}  "
          f"{ratio('b','satw','pop'):4.2f}/{ratio('f','satw','pop'):<4.2f}    "
          f"{agg['bfn']:5.0f}/{agg['ffn']:<5.0f}     {ratio('b','fsat','fn'):4.2f}/{ratio('f','fsat','fn'):<4.2f}       "
          f"{ratio('b','fsave','fn'):6.0f}/{ratio('f','fsave','fn'):<6.0f}   "
          f"{agg['bliving']:6.0f}/{agg['fliving']:<6.0f} {agg['bpp']:7.0f}/{agg['fpp']:<7.0f}")
