import glob, math, sys
import numpy as np
import pandas as pd

RUNS = sys.argv[1:] or ["ai_c15_prb", "ai_c15_act", "ai_l25_none", "ai_l25_nores",
                        "ai_l25_nocol", "ai_l50_prb18", "ai_l50_act18"]
BIRTH, DEATH, REF = 0.20, 0.025, 45875 / 65536

for run in RUNS:
    path = glob.glob(f"tmp/country_ai_record_*_{run}.csv")[0]
    df = pd.read_csv(path)
    df = df[df.day <= 9125]
    df["year"] = df.day // 365
    out = []
    for (slot, year), g in df.groupby(["slot", "year"]):
        g = g.sort_values("day")
        p0, p1 = g.population.iloc[0], g.population.iloc[-1]
        if p0 < 20 or p1 <= 0:
            continue
        span = (g.day.iloc[-1] - g.day.iloc[0]) / 365.0
        if span < 0.5:
            continue
        actual = math.log(p1 / p0) / span
        birth_mult = np.minimum(1.0, (g.satisfaction_q16 / 65536) / REF).mean()
        expected = BIRTH * birth_mult - DEATH
        out.append((slot, year, p0, actual, expected, birth_mult,
                    (g.essentials_q16 / 65536).min()))
    o = pd.DataFrame(out, columns=["slot", "year", "pop0", "actual", "expected",
                                   "birth_mult", "ess_min"])
    w = o.pop0
    gap = o.expected - o.actual
    print(f"{run:14s} country-years={len(o):4d} "
          f"actual={np.average(o.actual, weights=w):+.3f} "
          f"expected(no-starve)={np.average(o.expected, weights=w):+.3f} "
          f"birth_mult={np.average(o.birth_mult, weights=w):.3f} "
          f"gap(extra death/outflow)={np.average(gap, weights=w):+.3f} "
          f"years_ess_min<0.9={(o.ess_min < 0.9).mean():.1%}")
