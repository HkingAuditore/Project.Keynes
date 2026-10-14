import glob
import sys
import pandas as pd

SEEDS = ["20260718", "20260719", "3"]
YEARS = [5, 10, 15, 20, 25]
END = 9125


def load(label):
    paths = sorted(glob.glob(f"tmp/country_ai_record_*_{label}.csv"))
    if not paths:
        return None
    df = pd.read_csv(paths[-1])
    return None if df.empty else df[df.day <= END].copy()


def snapshot(df, day):
    return df[df.day <= day].sort_values("day").groupby("slot").tail(1).set_index("slot")


def summarize(label):
    df = load(label)
    if df is None:
        return None
    df["year"] = df.day // 365
    totals = [int(snapshot(df, y * 365).population.sum()) for y in YEARS]
    end = snapshot(df, END)
    famine = (df.groupby(["slot", "year"]).essentials_q16.min() / 65536 < 0.9).mean()
    extra = ""
    if "hungry_share_q16" in df:
        extra = (f" hungry_mean={df.hungry_share_q16.mean() / 65536:5.1%}"
                 f" subsidy_on={(df.food_subsidy_bp != 0).mean():5.1%}")
    research = (df.research_budget > 0).mean()
    return totals, (f"{label:24s} pop@5/10/15/20/25={'/'.join(map(str, totals)):28s} "
                    f"famine_years={famine:5.1%} territory={int(end.territory.sum()):3d} "
                    f"research_on={research:5.1%}{extra}")


prefixes = sys.argv[1:] or ["bl"]
for seed in SEEDS:
    print(f"== seed {seed}")
    probe = None
    for prefix in prefixes:
        for mode in ("probe", "active"):
            result = summarize(f"{prefix}_{mode}_{seed}")
            if result is None:
                continue
            totals, line = result
            if mode == "probe":
                probe = totals[-1]
            ratio = f" ratio={totals[-1] / probe:4.2f}" if mode == "active" and probe else ""
            print("  " + line + ratio)
