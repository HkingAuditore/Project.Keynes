import csv
from collections import defaultdict

BASE = "tmp/economy_record_20260829_003706_v25_cell1844_q29_r30_"


def load(name):
    with open(BASE + name + ".csv", newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def i(row, key, default=0):
    v = row.get(key, "")
    return int(v) if v not in ("", None) else default


print("=" * 70)
print("COHORTS: unemployed funds trajectory")
print("=" * 70)
cohorts = load("cohorts")
by_sig = defaultdict(list)
for r in cohorts:
    by_sig[i(r, "signature_id")].append(r)

for sig in sorted(by_sig):
    rows = sorted(by_sig[sig], key=lambda r: i(r, "day_index"))
    first, last = rows[0], rows[-1]
    print(f"\n-- signature {sig} (profession {i(first,'profession_id')}) "
          f"{len(rows)} days --")
    print(f"   population {i(first,'population')} -> {i(last,'population')}")
    print(f"   funds      {i(first,'funds'):,} -> {i(last,'funds'):,} "
          f"(delta {i(last,'funds')-i(first,'funds'):,})")
    print(f"   owner_employed {i(first,'owner_employed')} -> {i(last,'owner_employed')}"
          f"   employee {i(first,'employee_employed')} -> {i(last,'employee_employed')}"
          f"   unemployed {i(first,'unemployed')} -> {i(last,'unemployed')}")
    inc = sum(i(r, "epoch_income") for r in rows)
    exp = sum(i(r, "epoch_expense") for r in rows)
    print(f"   sum epoch_income {inc:,}   sum epoch_expense {exp:,}   "
          f"net {inc-exp:,}")
    # per-day funds delta
    deltas = [i(rows[k], "funds") - i(rows[k - 1], "funds")
              for k in range(1, len(rows))]
    pos = [d for d in deltas if d > 0]
    neg = [d for d in deltas if d < 0]
    print(f"   funds delta/day: +{len(pos)} days (sum {sum(pos):,}), "
          f"-{len(neg)} days (sum {sum(neg):,}), 0 on {len(deltas)-len(pos)-len(neg)}")
    if pos:
        print(f"   typical positive delta: {sorted(pos)[len(pos)//2]:,}")
    print("   first 8 days:")
    for r in rows[:8]:
        print(f"     day {i(r,'day_index')} pop={i(r,'population'):3d} "
              f"funds={i(r,'funds'):>14,} inc={i(r,'epoch_income'):>10,} "
              f"exp={i(r,'epoch_expense'):>10,} "
              f"own={i(r,'owner_employed')} emp={i(r,'employee_employed')} "
              f"unemp={i(r,'unemployed')}")

print()
print("=" * 70)
print("BUILDINGS: real group state (does filled_owner ever move?)")
print("=" * 70)
buildings = [r for r in load("buildings")
             if i(r, "group_index", -99) >= 0 and r.get("is_construction") == "0"]
groups = defaultdict(list)
for r in buildings:
    groups[(i(r, "group_index"), i(r, "type_id"))].append(r)
for key in sorted(groups):
    rows = sorted(groups[key], key=lambda r: i(r, "day_index"))
    f0, fl = rows[0], rows[-1]
    fo = {i(r, "filled_owner") for r in rows}
    oo = {i(r, "owner_openings") for r in rows}
    ef = {i(r, "employee_filled") for r in rows}
    print(f"  group{key[0]} type{key[1]}: count={i(f0,'count')} "
          f"filled_owner {i(f0,'filled_owner')}->{i(fl,'filled_owner')} "
          f"uniq={sorted(fo)}")
    print(f"      owner_required={i(fl,'owner_required')} "
          f"owner_openings uniq={sorted(oo)} employee_filled uniq={sorted(ef)}")

print()
print("=" * 70)
print("SUMMARY: global employment + money")
print("=" * 70)
summary = sorted(load("summary"), key=lambda r: i(r, "day_index"))
cols = ["filled_owner_jobs", "filled_employee_jobs", "unemployed_population",
        "cohort_count", "births", "deaths", "building_wages_paid",
        "producer_support_money_issued", "bullion_money_issued",
        "gold_money_issued", "silver_money_issued", "money_error",
        "building_owner_mobility", "building_owner_job_reallocations",
        "building_employee_to_owner_reallocations",
        "building_investment_owner_population_moved"]
for c in cols:
    vals = [i(r, c) for r in summary]
    uniq = sorted(set(vals))
    print(f"  {c:<45} first={vals[0]:>12,} last={vals[-1]:>12,} "
          f"uniq={len(uniq)} "
          f"{'CONST' if len(uniq)==1 else f'range[{uniq[0]:,}..{uniq[-1]:,}]'}")
