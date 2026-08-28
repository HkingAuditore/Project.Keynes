import csv
from collections import defaultdict

BASE = "tmp/economy_record_20260829_003706_v25_cell1844_q29_r30_"


def load(name):
    with open(BASE + name + ".csv", newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def i(row, key, default=0):
    v = row.get(key, "")
    return int(v) if v not in ("", None) else default


cohorts = load("cohorts")
summary = {i(r, "day_index"): r for r in load("summary")}

by_sig = defaultdict(dict)
for r in cohorts:
    by_sig[i(r, "signature_id")][i(r, "day_index")] = r

print("=" * 78)
print("Is epoch_income cumulative or per-epoch? (compare consecutive days)")
print("=" * 78)
rows = sorted(by_sig[43].items())
print(" day   pop     funds        d_funds     income    expense  inc-exp   "
      "residual")
for k in range(1, 12):
    d0, r0 = rows[k - 1]
    d1, r1 = rows[k]
    df = i(r1, "funds") - i(r0, "funds")
    ie = i(r1, "epoch_income") - i(r1, "epoch_expense")
    print(f"{d1:5d} {i(r1,'population'):4d} {i(r1,'funds'):>13,} "
          f"{df:>11,} {i(r1,'epoch_income'):>10,} {i(r1,'epoch_expense'):>10,} "
          f"{ie:>9,} {df-ie:>10,}")

print()
print("=" * 78)
print("Unemployed cohort: full residual accounting")
print("=" * 78)
resid_total = 0
resid_days = []
for k in range(1, len(rows)):
    d0, r0 = rows[k - 1]
    d1, r1 = rows[k]
    df = i(r1, "funds") - i(r0, "funds")
    ie = i(r1, "epoch_income") - i(r1, "epoch_expense")
    resid = df - ie
    resid_total += resid
    resid_days.append((d1, resid, df, ie, i(r1, "population"),
                       i(r1, "population") - i(r0, "population")))
print(f"total residual (funds change not explained by income-expense): "
      f"{resid_total:,}")
nonzero = [x for x in resid_days if x[1] != 0]
print(f"days with nonzero residual: {len(nonzero)} / {len(resid_days)}")
big = sorted(resid_days, key=lambda x: -abs(x[1]))[:12]
print("\nlargest residual days:")
print("  day   residual      d_funds     inc-exp   pop  dpop")
for d, resid, df, ie, pop, dpop in big:
    print(f"{d:5d} {resid:>11,} {df:>12,} {ie:>11,} {pop:5d} {dpop:5d}")

print()
print("=" * 78)
print("Per-capita funds and satisfaction over time (unemployed)")
print("=" * 78)
for d, r in rows[::90]:
    pop = max(1, i(r, "population"))
    print(f"  day {d:4d} pop={pop:3d} funds={i(r,'funds'):>13,} "
          f"per_capita={i(r,'funds')//pop:>10,} "
          f"income={i(r,'epoch_income'):>9,} expense={i(r,'epoch_expense'):>9,} "
          f"sat={i(r,'satisfaction_q16'):>7,} "
          f"cover={i(r,'livelihood_coverage_q16'):>7,} "
          f"worst_need={i(r,'worst_need_id')}")

print()
print("=" * 78)
print("Cohort count / churn: does an extra cohort appear on some days?")
print("=" * 78)
days = sorted(by_sig[43])
counts = defaultdict(int)
for d in days:
    n = sum(1 for sig in by_sig if d in by_sig[sig])
    counts[n] += 1
print(f"  cohorts present in cell 1844 per day: {dict(counts)}")
gc = [(d, i(summary[d], "cohort_count")) for d in days if d in summary]
uniq = sorted({c for _, c in gc})
print(f"  global cohort_count values: {uniq}")
changes = [(d, c) for k, (d, c) in enumerate(gc)
           if k and c != gc[k - 1][1]][:20]
print(f"  first global cohort_count changes: {changes}")

print()
print("=" * 78)
print("Where does the money come from? global money-side counters")
print("=" * 78)
sdays = sorted(summary)
for c in ["producer_support_money_issued", "producer_revenue",
          "owner_output_consumed", "production_output_supported",
          "merchant_cash", "building_wages_paid", "building_wages_unpaid",
          "money_error", "population_error", "goods_error"]:
    vals = [i(summary[d], c) for d in sdays]
    print(f"  {c:<35} first={vals[0]:>14,} last={vals[-1]:>14,} "
          f"sum={sum(vals):>16,}")
