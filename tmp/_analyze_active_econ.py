import csv
import collections
import statistics as st
from pathlib import Path

prefix = Path("tmp/economy_record_20260918_221504_v25_cell1827_q12_r30")

with open(prefix.with_name(prefix.name + "_summary.csv"), newline="", encoding="utf-8") as f:
    rows = list(csv.DictReader(f))
print("summary rows", len(rows), "days", rows[0]["day_index"], "->", rows[-1]["day_index"])
print("day own emp unemp bldgs mob e2o des fund unfund rev wages mcash")
pick = rows[:: max(1, len(rows) // 12)] + [rows[-1]]
seen = set()
for r in pick:
    d = r["day_index"]
    if d in seen:
        continue
    seen.add(d)
    print(
        " ".join(
            str(r.get(k, ""))
            for k in [
                "day_index",
                "filled_owner_jobs",
                "filled_employee_jobs",
                "unemployed_population",
                "building_group_count",
                "building_owner_mobility",
                "building_employee_to_owner_reallocations",
                "desired_business_demand",
                "funded_business_demand",
                "unfunded_business_demand",
                "producer_revenue",
                "building_wages_paid",
                "merchant_cash",
            ]
        )
    )

print("\naudit last:", {k: rows[-1][k] for k in ["population_error", "money_error", "goods_error"]})
print(
    "mobility nonzero days",
    sum(1 for r in rows if int(r["building_owner_mobility"]) > 0),
    "e2o nonzero",
    sum(1 for r in rows if int(r["building_employee_to_owner_reallocations"]) > 0),
    "invest starts",
    sum(int(r["building_investments_started"]) for r in rows),
)

with open(prefix.with_name(prefix.name + "_cohorts.csv"), newline="", encoding="utf-8") as f:
    cohorts = list(csv.DictReader(f))
last = max(int(r["day_index"]) for r in cohorts)
first = min(int(r["day_index"]) for r in cohorts)
for day in [first, last]:
    day_rows = [r for r in cohorts if int(r["day_index"]) == day]
    by_prof = collections.Counter()
    emp = {"owner": 0, "employee": 0, "unemployed": 0, "pop": 0}
    for r in day_rows:
        p = int(r["profession_id"])
        pop = int(r["population"])
        by_prof[p] += pop
        emp["owner"] += int(r["owner_employed"])
        emp["employee"] += int(r["employee_employed"])
        emp["unemployed"] += int(r["unemployed"])
        emp["pop"] += pop
    print(f"day {day} cell cohorts: {emp} professions={dict(by_prof)}")

with open(prefix.with_name(prefix.name + "_buildings.csv"), newline="", encoding="utf-8") as f:
    brows = list(csv.DictReader(f))
blast = max(int(r["day_index"]) for r in brows)
bfirst = min(int(r["day_index"]) for r in brows)
for day in [bfirst, blast]:
    day_rows = [r for r in brows if int(r["day_index"]) == day]
    by = collections.defaultdict(
        lambda: {
            "count": 0,
            "filled_owner": 0,
            "owner_req": 0,
            "emp_f": 0,
            "emp_r": 0,
            "output": 0,
            "ops": collections.Counter(),
            "open": 0,
            "prof": "",
        }
    )
    for r in day_rows:
        t = int(r["type_id"])
        c = int(r["count"])
        by[t]["count"] += c
        by[t]["filled_owner"] += int(r["filled_owner"])
        by[t]["owner_req"] += int(r["owner_required"])
        by[t]["emp_f"] += int(r["employee_filled"])
        by[t]["emp_r"] += int(r["employee_required"])
        by[t]["output"] += int(r["last_output"])
        by[t]["ops"][r["operating_state"]] += c
        by[t]["open"] += int(r["owner_openings"])
        by[t]["prof"] = r.get("employment_profession_id", "")
    print(f"=== buildings day {day} n={len(day_rows)} ===")
    for t, v in sorted(by.items(), key=lambda kv: -kv[1]["count"])[:25]:
        print(
            f" type={t} prof={v['prof']} count={v['count']} "
            f"own={v['filled_owner']}/{v['owner_req']} open={v['open']} "
            f"emp={v['emp_f']}/{v['emp_r']} out={v['output']} ops={dict(v['ops'])}"
        )

with open("tmp/perf_record_20260918_221117.csv", newline="", encoding="utf-8") as f:
    prow = list(csv.DictReader(f))
print("\nperf rows", len(prow))


def nums(k):
    xs = [float(r[k]) for r in prow if r.get(k) not in (None, "")]
    if not xs:
        return None
    return (round(st.mean(xs), 2), round(st.median(xs), 2), round(max(xs), 2))


for k in [
    "fps",
    "speed_multiplier",
    "fast_ms",
    "t_sus_ms",
    "t_render_ms",
    "frame_wall_ms",
    "continuation_wall_ms",
    "continuation_economy_slices",
    "runtime_graph_pulse_count",
    "runtime_graph_budget_yields",
    "runtime_graph_last_elapsed_us",
    "clock_full_ms",
]:
    print(k, nums(k))
print("largest_slice", collections.Counter(r["largest_slice_job"] for r in prow).most_common(8))
print("speed values", collections.Counter(r["speed_multiplier"] for r in prow).most_common())

# profile signals
prof = Path("tmp/economy_record_20260918_221504_v25_cell1827_q12_r30_profile.json")
if prof.exists():
    import json

    data = json.loads(prof.read_text(encoding="utf-8"))
    print("\nprofile signals:")
    for s in data.get("signals", data.get("warning_signals", []))[:20]:
        print(" ", s if not isinstance(s, dict) else json.dumps(s, ensure_ascii=False)[:200])
