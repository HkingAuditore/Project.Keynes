import glob
import pandas as pd

PAIRS = [
    ("20260718", "ai_l50_prb18", "ai_l50_act18", "rr_probe_20260718", "rr_active_20260718", "sf_probe_20260718", "sf_active_20260718"),
    ("20260719", "ai_l50_prb19", "ai_l50_act19", "rr_probe_20260719", "rr_active_20260719", "sf_probe_20260719", "sf_active_20260719"),
    ("3", "ai_l50_prb3", "ai_l50_act3", "rr_probe_3", "rr_active_3", "sf_probe_3", "sf_active_3"),
]
YEARS = [5, 10, 15, 20, 25]


def load(label):
    paths = sorted(glob.glob(f"tmp/country_ai_record_*_{label}.csv"))
    if not paths:
        return None
    df = pd.read_csv(paths[-1])
    return None if df.empty else df[df.day <= 9125].copy()


def snapshot(df, day):
    d = df[df.day <= day]
    return d.sort_values("day").groupby("slot").tail(1).set_index("slot")


def summarize(label):
    df = load(label)
    if df is None:
        return f"{label:20s} (no data)", None
    df["year"] = df.day // 365
    totals = [int(snapshot(df, y * 365).population.sum()) for y in YEARS]
    end = snapshot(df, 9125)
    peak = df.groupby("slot").population.max().reindex(end.index)
    collapsed = int(((end.population < 0.5 * peak) & (peak > 50)).sum())
    yearly = df.groupby(["slot", "year"]).essentials_q16.min() / 65536
    famine_share = (yearly < 0.9).mean()
    per_country = "/".join(str(int(p)) for p in end.population)
    return (f"{label:20s} total@y5/10/15/20/25={'/'.join(map(str, totals)):30s} "
            f"y25 per country={per_country:28s} collapsed={collapsed} "
            f"famine_years={famine_share:5.1%} territory={int(end.territory.sum())}"), totals[-1]


for seed, *labels in PAIRS:
    print(f"== seed {seed}")
    for label in labels:
        print("  " + summarize(label)[0])
