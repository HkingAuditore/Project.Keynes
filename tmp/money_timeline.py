import glob, sys
import pandas as pd

run = sys.argv[1] if len(sys.argv) > 1 else "ai_sv15b_act"
df = pd.read_csv(glob.glob(f"tmp/country_ai_record_*_{run}.csv")[0])
df["year"] = df.day // 365
cols = ["population", "cash", "research_budget", "tax_paid", "household_income",
        "essentials_q16", "satisfaction_q16", "queued_techs", "completed_milestones"]
for slot, g in df.groupby("slot"):
    y = g.groupby("year").agg({c: "last" for c in cols}
                              | {"research_budget": "mean", "tax_paid": "mean",
                                 "household_income": "mean", "essentials_q16": "min"})
    print(f"--- slot {slot}")
    for year, r in y.iterrows():
        if year % 2:
            continue
        print(f"y{year:2d} pop={int(r.population):5d} cash={int(r.cash):>14,d} "
              f"research={int(r.research_budget):>12,d} tax={int(r.tax_paid):>12,d} "
              f"hh_income={int(r.household_income):>12,d} ess_min={r.essentials_q16/65536:.2f} "
              f"sat={r.satisfaction_q16/65536:.2f} milestones={int(r.completed_milestones)}")
