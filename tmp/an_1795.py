# Analyze cell1795 recorder: employment after family-partition removal,
# remaining vacancies, and unemployed funds.
import csv
from collections import defaultdict

PREFIX = (
    r"d:\Godot\ProjectKeynes\Project.Keynes\tmp"
    r"\economy_record_20260829_022021_v25_cell1795_q41_r29"
)

def load(name):
    with open(PREFIX + "_" + name + ".csv", newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

summary = load("summary")
cohorts = load("cohorts")
buildings = load("buildings")

def i(row, key):
    v = row.get(key, "")
    return int(v) if v not in ("", None) else 0

print("=== scope ===")
print(f"summary days {summary[0]['day_index']}..{summary[-1]['day_index']} "
      f"n={len(summary)}")
print(f"detail cell {cohorts[0]['cell_idx']} q={cohorts[0]['q']} r={cohorts[0]['r']}")

print("\n=== global employment trajectory ===")
def dump_sum(idx):
    r = summary[idx]
    print(f"  day {r['day_index']}: owners={r['filled_owner_jobs']} "
          f"emp={r['filled_employee_jobs']} unemp={r['unemployed_population']} "
          f"cohorts={r['cohort_count']} investments_started={r['building_investments_started']} "
          f"owner_mobility={r['building_owner_mobility']} "
          f"owner_realloc={r['building_owner_job_reallocations']} "
          f"emp2owner={r['building_employee_to_owner_reallocations']}")

dump_sum(0)
dump_sum(len(summary)//4)
dump_sum(len(summary)//2)
dump_sum(-1)

unemp_series = [i(r, "unemployed_population") for r in summary]
owner_series = [i(r, "filled_owner_jobs") for r in summary]
print(f"  unemp min/max {min(unemp_series)}/{max(unemp_series)} "
      f"owners {owner_series[0]}->{owner_series[-1]}")
print(f"  births={sum(i(r,'births') for r in summary)} "
      f"deaths={sum(i(r,'deaths') for r in summary)}")
print(f"  investments_started sum={sum(i(r,'building_investments_started') for r in summary)}")
print(f"  owner_mobility sum={sum(i(r,'building_owner_mobility') for r in summary)}")
print(f"  owner_realloc sum={sum(i(r,'building_owner_job_reallocations') for r in summary)}")
print(f"  emp2owner sum={sum(i(r,'building_employee_to_owner_reallocations') for r in summary)}")

print("\n=== cell1795 cohort stocks (first vs last day present) ===")
by_sig = defaultdict(list)
for r in cohorts:
    by_sig[int(r["signature_id"])].append(r)
for sig in sorted(by_sig):
    rows = by_sig[sig]
    a, b = rows[0], rows[-1]
    print(f"  sig{sig} prof{a['profession_id']} merch={a['is_merchant']} "
          f"days {a['day_index']}..{b['day_index']} "
          f"pop {a['population']}->{b['population']} "
          f"unemp {a['unemployed']}->{b['unemployed']} "
          f"owner {a['owner_employed']}->{b['owner_employed']} "
          f"emp {a['employee_employed']}->{b['employee_employed']} "
          f"funds {a['funds']}->{b['funds']} "
          f"inc {a['epoch_income']}->{b['epoch_income']}")

print("\n=== unemployed cohort daily (pop, funds, income, expense) ===")
unemp_rows = [r for r in cohorts if int(r["unemployed"]) > 0 or int(r["profession_id"]) == 43]
# profession 43 was unemployed in the profile; also catch any unemployed>0
unemp_days = []
seen = set()
for r in cohorts:
    if int(r.get("unemployed") or 0) <= 0:
        continue
    d = int(r["day_index"])
    if d in seen:
        continue
    # sum all unemployed-marked rows that day
    pop = funds = inc = exp = 0
    n = 0
    for x in cohorts:
        if int(x["day_index"]) == d and int(x["unemployed"]) > 0:
            pop += int(x["population"])
            funds += int(x["funds"])
            inc += int(x["epoch_income"])
            exp += int(x["epoch_expense"])
            n += 1
    unemp_days.append((d, pop, funds, inc, exp, n))
    seen.add(d)

print(f"  days with unemployed>0: {len(unemp_days)} "
      f"[{unemp_days[0][0] if unemp_days else '-'}.."
      f"{unemp_days[-1][0] if unemp_days else '-'}]")
if unemp_days:
    print(f"  first: day={unemp_days[0][0]} pop={unemp_days[0][1]} "
          f"funds={unemp_days[0][2]} inc={unemp_days[0][3]} exp={unemp_days[0][4]}")
    print(f"  last:  day={unemp_days[-1][0]} pop={unemp_days[-1][1]} "
          f"funds={unemp_days[-1][2]} inc={unemp_days[-1][3]} exp={unemp_days[-1][4]}")
    # sample every ~100 days
    for d, pop, funds, inc, exp, n in unemp_days:
        if d == unemp_days[0][0] or d == unemp_days[-1][0] or d % 50 == 0:
            pc = funds // pop if pop else 0
            print(f"    d{d}: pop={pop} funds={funds} per_cap={pc} inc={inc} exp={exp}")

    # residual: funds change not explained by income-expense
    print("  funds residual (delta_funds - income + expense), first 15 deltas and last 5:")
    residuals = []
    for a, b in zip(unemp_days, unemp_days[1:]):
        d_funds = b[2] - a[2]
        # income/expense on row b is that day's flow
        residual = d_funds - b[3] + b[4]
        residuals.append((b[0], a[1], b[1], d_funds, b[3], b[4], residual))
    for row in residuals[:15] + residuals[-5:]:
        print(f"    d{row[0]} pop {row[1]}->{row[2]} d_funds={row[3]} "
              f"inc={row[4]} exp={row[5]} residual={row[6]}")
    pos = sum(1 for r in residuals if r[6] > 1000)
    neg = sum(1 for r in residuals if r[6] < -1000)
    print(f"  residual >1k: {pos}/{len(residuals)}  residual <-1k: {neg}/{len(residuals)}")

print("\n=== diagnostic hires (take>0) ===")
diag = [r for r in buildings if r.get("employment_candidate") == "1"]
hires = [r for r in diag if i(r, "employment_take") > 0]
print(f"  hire rows={len(hires)}")
for r in hires:
    print(f"    d{r['day_index']} type{r['type_id']} role={r['employment_role']} "
          f"take={r['employment_take']} group={r['employment_group']} "
          f"vac={r['employment_vacancy']} budget={r['employment_budget']} "
          f"pool_pop={r['employment_pool_population']} "
          f"reason={r['employment_rejection_reason']}")

print("\n=== rejection over time (POOL_MISSING vs NO_ALLOCATION) ===")
by_day_reason = defaultdict(lambda: defaultdict(int))
budget_by_day = {}
pool_by_day = {}
for r in diag:
    d = int(r["day_index"])
    by_day_reason[d][int(r["employment_rejection_reason"])] += 1
    budget_by_day[d] = max(budget_by_day.get(d, 0), i(r, "employment_budget"))
    pool_by_day[d] = max(pool_by_day.get(d, 0), i(r, "employment_pool_population"))

def window(lo, hi):
    c = defaultdict(int)
    days = 0
    bsum = psum = 0
    for d in range(lo, hi + 1):
        if d not in by_day_reason:
            continue
        days += 1
        for k, v in by_day_reason[d].items():
            c[k] += v
        bsum += budget_by_day.get(d, 0)
        psum += pool_by_day.get(d, 0)
    return days, c, (bsum / days if days else 0), (psum / days if days else 0)

for lo, hi, label in [(20, 120, "early"), (200, 400, "mid"), (500, 960, "late")]:
    days, c, bavg, pavg = window(lo, hi)
    print(f"  {label} d{lo}-{hi} days={days} reasons={dict(c)} "
          f"avg_budget={bavg:.2f} avg_pool={pavg:.2f}")

print("\n=== building openings (non-diagnostic, last vs first) ===")
real = [r for r in buildings if r.get("employment_candidate") != "1"
        and r.get("is_construction") != "1"]
by_g = defaultdict(list)
for r in real:
    by_g[int(r["group_index"])].append(r)
for g in sorted(by_g):
    rows = by_g[g]
    a, b = rows[0], rows[-1]
    print(f"  g{g} type{a['type_id']} days {a['day_index']}..{b['day_index']} "
          f"count {a['count']}->{b['count']} "
          f"owner {a['filled_owner']}/{a['owner_required']} -> "
          f"{b['filled_owner']}/{b['owner_required']} "
          f"open {a['owner_openings']}->{b['owner_openings']} "
          f"emp {a['employee_filled']}/{a['employee_required']} -> "
          f"{b['employee_filled']}/{b['employee_required']} "
          f"state {a['operating_state']}->{b['operating_state']} "
          f"opp_disp {a['opportunity_disposable_survival_power_per_day']}->"
          f"{b['opportunity_disposable_survival_power_per_day']}")

print("\n=== cell openings vs unemployed (sampled) ===")
open_by_day = defaultdict(lambda: [0, 0, 0])  # owner_open, emp_req-filled, unemp
for r in real:
    d = int(r["day_index"])
    open_by_day[d][0] += i(r, "owner_openings")
    open_by_day[d][1] += max(0, i(r, "employee_required") - i(r, "employee_filled"))
unemp_by_day = defaultdict(int)
for r in cohorts:
    unemp_by_day[int(r["day_index"])] += i(r, "unemployed")
days_all = sorted(open_by_day)
for d in days_all:
    if d in (days_all[0], days_all[-1]) or d % 100 == 0:
        o, e = open_by_day[d]
        print(f"  d{d}: owner_open={o} emp_open={e} unemp={unemp_by_day[d]}")

print("\n=== type72 target_disp (why vacancy never fills?) ===")
t72 = [r for r in diag if r["type_id"] == "72"]
if t72:
    disp = [i(r, "employment_target_disposable") for r in t72]
    print(f"  n={len(t72)} disp min/max {min(disp)}/{max(disp)} "
          f"last={disp[-1]} eligible last={t72[-1]['employment_eligible']}")
    pos = sum(1 for x in disp if x > 0)
    print(f"  days with positive owner disposable: {pos}/{len(disp)}")
