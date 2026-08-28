import csv

P = (
    r"d:\Godot\ProjectKeynes\Project.Keynes\tmp"
    r"\economy_record_20260829_022021_v25_cell1795_q41_r29"
)

def load(n):
    with open(P + "_" + n + ".csv", newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

C = load("cohorts")
B = load("buildings")
S = load("summary")

print("=== d410-460 cell cohorts ===")
want_d = {410, 416, 420, 425, 426, 440, 444, 445, 446, 450, 460}
for r in C:
    d = int(r["day_index"])
    if d not in want_d:
        continue
    print(
        f"  d{d} sig{r['signature_id']} prof{r['profession_id']} "
        f"pop={r['population']} unemp={r['unemployed']} "
        f"owner={r['owner_employed']} emp={r['employee_employed']} "
        f"funds={r['funds']} inc={r['epoch_income']} exp={r['epoch_expense']}"
    )

print("\n=== d410-460 buildings ===")
want_b = {410, 416, 425, 426, 444, 445, 446, 450}
for r in B:
    if r.get("employment_candidate") == "1":
        continue
    d = int(r["day_index"])
    g = int(r["group_index"])
    if g < 0 or d not in want_b:
        continue
    print(
        f"  d{d} g{g} type{r['type_id']} count={r['count']} "
        f"filled_owner={r['filled_owner']}/{r['owner_required']} "
        f"open={r['owner_openings']} "
        f"emp={r['employee_filled']}/{r['employee_required']} "
        f"state={r['operating_state']}"
    )

print("\n=== global around 445 ===")
for r in S:
    d = int(r["day_index"])
    if d not in (420, 425, 426, 440, 444, 445, 446, 450, 500, 700, 960):
        continue
    print(
        f"  d{d} owners={r['filled_owner_jobs']} emp={r['filled_employee_jobs']} "
        f"unemp={r['unemployed_population']} "
        f"realloc={r['building_owner_job_reallocations']} "
        f"emp2o={r['building_employee_to_owner_reallocations']} "
        f"inv={r['building_investments_started']} "
        f"inv_jobs={r['building_investment_jobs_started']} "
        f"displace={r['building_investment_displacement_starts']}"
    )

print("\n=== type357 fill whenever count or fill changes ===")
prev = None
for r in B:
    if r.get("employment_candidate") == "1" or r["type_id"] != "357":
        continue
    if int(r["group_index"]) < 0:
        continue
    key = (r["count"], r["filled_owner"], r["owner_required"])
    if key != prev:
        print(
            f"  d{r['day_index']} count={r['count']} "
            f"filled={r['filled_owner']}/{r['owner_required']} "
            f"open={r['owner_openings']}"
        )
        prev = key

print("\n=== type62 fill whenever count or fill changes ===")
prev = None
for r in B:
    if r.get("employment_candidate") == "1" or r["type_id"] != "62":
        continue
    if int(r["group_index"]) < 0:
        continue
    key = (r["count"], r["filled_owner"], r["owner_required"])
    if key != prev:
        print(
            f"  d{r['day_index']} count={r['count']} "
            f"filled={r['filled_owner']}/{r['owner_required']} "
            f"open={r['owner_openings']}"
        )
        prev = key

print("\n=== type297 fill changes ===")
prev = None
for r in B:
    if r.get("employment_candidate") == "1" or r["type_id"] != "297":
        continue
    if int(r["group_index"]) < 0:
        continue
    key = (r["count"], r["filled_owner"], r["employee_filled"], r["owner_required"],
           r["employee_required"])
    if key != prev:
        print(
            f"  d{r['day_index']} count={r['count']} "
            f"owner={r['filled_owner']}/{r['owner_required']} "
            f"emp={r['employee_filled']}/{r['employee_required']} "
            f"opp={r['opportunity_disposable_survival_power_per_day']}"
        )
        prev = key

print("\n=== last-day cell openings vs cohort pops ===")
last_d = C[-1]["day_index"]
print(f"last day {last_d}")
for r in C:
    if r["day_index"] != last_d:
        continue
    print(
        f"  sig{r['signature_id']} pop={r['population']} "
        f"owner={r['owner_employed']} emp={r['employee_employed']} "
        f"unemp={r['unemployed']}"
    )
for r in B:
    if r["day_index"] != last_d:
        continue
    if r.get("employment_candidate") == "1" or int(r["group_index"]) < 0:
        continue
    print(
        f"  g{r['group_index']} type{r['type_id']} count={r['count']} "
        f"owner={r['filled_owner']}/{r['owner_required']} "
        f"open={r['owner_openings']} emp={r['employee_filled']}/{r['employee_required']} "
        f"owner_sig={r['owner_signature_id']} "
        f"disp={r['opportunity_disposable_survival_power_per_day']}"
    )
