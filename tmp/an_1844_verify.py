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
by_day = defaultdict(dict)
for r in cohorts:
    by_day[i(r, "day_index")][i(r, "signature_id")] = r
days = sorted(by_day)

print("=" * 92)
print("Is the unemployed 'income' just the owner cohort's income carried in by churn?")
print("=" * 92)
print("  day | sig13 own inc  pop | sig26 own inc  pop | sig43 unemp inc  pop |"
      " 43/13 | 43/(13/2)")
for d in days[::80] + days[-1:]:
    a = by_day[d].get(13)
    b = by_day[d].get(26)
    c = by_day[d].get(43)
    if not (a and b and c):
        continue
    i13, i26, i43 = i(a, "epoch_income"), i(b, "epoch_income"), i(c, "epoch_income")
    ratio = i43 / i13 if i13 else 0
    half = i43 / (i13 / 2) if i13 else 0
    print(f"{d:5d} | {i13:>13,} {i(a,'population'):3d} | {i26:>13,} "
          f"{i(b,'population'):3d} | {i43:>15,} {i(c,'population'):3d} |"
          f" {ratio:5.3f} | {half:6.3f}")

print()
print("=" * 92)
print("Cell-level totals: is money conserved inside the cell?")
print("=" * 92)
tot_first = sum(i(r, "funds") for r in by_day[days[0]].values())
tot_last = sum(i(r, "funds") for r in by_day[days[-1]].values())
pop_first = sum(i(r, "population") for r in by_day[days[0]].values())
pop_last = sum(i(r, "population") for r in by_day[days[-1]].values())
print(f"  total funds  {tot_first:,} -> {tot_last:,}  (delta {tot_last-tot_first:,})")
print(f"  total pop    {pop_first} -> {pop_last}")
print(f"  per-capita   {tot_first//pop_first:,} -> {tot_last//pop_last:,}")
print()
print("  So the unemployed cohort's +684k is NOT 50M of new money; the 50M")
print("  'residual' means epoch_income/epoch_expense do not describe the")
print("  actual funds movement for this cohort.")

print()
print("=" * 92)
print("Per-capita funds by cohort: who is getting richer per head?")
print("=" * 92)
for sig in (13, 26, 43):
    a = by_day[days[0]].get(sig)
    b = by_day[days[-1]].get(sig)
    if not (a and b):
        continue
    p0 = max(1, i(a, "population"))
    p1 = max(1, i(b, "population"))
    print(f"  sig{sig}: pop {i(a,'population')}->{i(b,'population')}  "
          f"per-capita {i(a,'funds')//p0:>12,} -> {i(b,'funds')//p1:>12,}  "
          f"({100.0*(i(b,'funds')/p1)/(i(a,'funds')/p0)-100:+.1f}%)")

print()
print("=" * 92)
print("Expense vs realized: is epoch_expense actually leaving the cohort?")
print("=" * 92)
rows43 = [(d, by_day[d][43]) for d in days if 43 in by_day[d]]
tot_inc = sum(i(r, "epoch_income") for _, r in rows43)
tot_exp = sum(i(r, "epoch_expense") for _, r in rows43)
tot_ink = sum(i(r, "epoch_in_kind_income") for _, r in rows43)
d_funds = i(rows43[-1][1], "funds") - i(rows43[0][1], "funds")
print(f"  sum epoch_income      {tot_inc:>15,}")
print(f"  sum epoch_expense     {tot_exp:>15,}")
print(f"  sum in_kind_income    {tot_ink:>15,}")
print(f"  implied funds change  {tot_inc-tot_exp:>15,}")
print(f"  actual funds change   {d_funds:>15,}")
print(f"  discrepancy           {d_funds-(tot_inc-tot_exp):>15,}")
print()
print("  If epoch_expense were realized cash outflow, this cohort would have")
print("  gone bankrupt long ago. It did not, so a large part of that 'expense'")
print("  is demand that was never fulfilled (goods unavailable).")

print()
print("=" * 92)
print("Market: can the unemployed actually buy anything?")
print("=" * 92)
market = load("market")
mk = defaultdict(list)
for r in market:
    mk[r["good_id"]].append(r)
short = []
for good, rows in mk.items():
    rows.sort(key=lambda r: i(r, "day_index"))
    days_short = sum(1 for r in rows if i(r, "shortage_q16") > 32768)
    stock = [i(r, "stock") for r in rows]
    short.append((days_short / len(rows), good, sum(stock) / len(stock),
                  i(rows[-1], "shortage_q16")))
short.sort(reverse=True)
print("  worst goods by share of days in shortage:")
for frac, good, avg_stock, last_short in short[:12]:
    print(f"    {good:<24} shortage_days={frac*100:5.1f}%  "
          f"avg_stock={avg_stock:12.1f}  last_shortage_q16={last_short:,}")
