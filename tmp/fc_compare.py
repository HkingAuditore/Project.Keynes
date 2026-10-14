import glob
import sys
import pandas as pd

END = 9125
prefix = sys.argv[1] if len(sys.argv) > 1 else "F"
variants = sys.argv[2:] or ["default", "v2c", "nores", "nocol"]
SEEDS = ["20260718", "20260719", "3", "7", "11", "42"]


def load(label):
    paths = sorted(glob.glob(f"tmp/country_ai_record_*_{label}.csv"))
    if not paths:
        return None
    df = pd.read_csv(paths[-1])
    df = df[df.day <= END]
    return df if not df.empty and df.day.max() >= END - 30 else None


def stats(df):
    end = df.sort_values("day").groupby("slot").tail(1)
    df = df.assign(year=df.day // 365)
    famine = (df.groupby(["slot", "year"]).essentials_q16.min() / 65536 < 0.9).mean()
    hungry = df.hungry_share_q16.mean() / 65536 if "hungry_share_q16" in df else 0.0
    return int(end.population.sum()), famine, int(end.territory.sum()), hungry


rows = []
for seed in SEEDS:
    probe = load(f"{prefix}default_probe_{seed}")
    if probe is None:
        continue
    p_pop, p_fam, _, _ = stats(probe)
    line = f"seed {seed:9s} PROBE pop={p_pop:5d} famine={p_fam:4.0%} |"
    for v in variants:
        df = load(f"{prefix}{v}_active_{seed}")
        if df is None:
            line += f" {v}: -- |"
            continue
        pop, fam, terr, hungry = stats(df)
        rows.append((v, pop / p_pop, fam, terr, hungry))
        line += f" {v}: {pop / p_pop:4.2f} fam={fam:4.0%} terr={terr:2d} |"
    print(line)

if rows:
    df = pd.DataFrame(rows, columns=["variant", "ratio", "famine", "territory", "hungry"])
    print(df.groupby("variant").agg(n=("ratio", "size"), ratio_mean=("ratio", "mean"),
                                    ratio_min=("ratio", "min"), famine=("famine", "mean"),
                                    territory=("territory", "mean"),
                                    hungry=("hungry", "mean")).round(3).to_string())
