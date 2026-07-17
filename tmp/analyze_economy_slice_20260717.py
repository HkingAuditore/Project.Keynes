import csv, os, re, json, math
from collections import defaultdict
ROOT = r"D:\Godot\ProjectKeynes\Project.Keynes"
PFX = os.path.join(ROOT, "tmp", "economy_record_20260717_152531_v7_cell1166_q17_r19")
paths = {k: PFX + "_" + k + ".csv" for k in ["summary", "cohorts", "market", "buildings", "resources"]}

def read_csv(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def num(x):
    if x is None or x == "": return 0
    try:
        if any(c in x for c in ".eE"):
            return float(x)
        return int(x)
    except ValueError:
        return x

def profile_map(dir_rel):
    d = os.path.join(ROOT, dir_rel)
    items = []
    if not os.path.isdir(d): return {}
    for fn in os.listdir(d):
        if not fn.endswith(".tres"): continue
        p = os.path.join(d, fn)
        txt = open(p, encoding="utf-8", errors="ignore").read()
        m = re.search(r'^id\s*=\s*&?"([^"]+)"', txt, re.M)
        if not m: continue
        disp = re.search(r'^display_name\s*=\s*"([^"]*)"', txt, re.M)
        items.append((m.group(1), disp.group(1) if disp else "", fn))
    return {i: {"id": sid, "display": disp, "file": fn} for i, (sid, disp, fn) in enumerate(sorted(items, key=lambda x: x[0]))}

prof = profile_map(os.path.join("Project", "project-keynes", "data", "economy", "professions"))
need = profile_map(os.path.join("Project", "project-keynes", "data", "economy", "needs"))
bld = profile_map(os.path.join("Project", "project-keynes", "data", "economy", "buildings"))

summary = read_csv(paths["summary"])
cohorts = read_csv(paths["cohorts"])
market = read_csv(paths["market"])
buildings = read_csv(paths["buildings"])
resources = read_csv(paths["resources"])

out = {}
out["rows"] = {k: len(read_csv(v)) for k,v in paths.items()}
out["days"] = {"first": int(summary[0]["day_index"]), "last": int(summary[-1]["day_index"]), "epochs": len(summary)}
out["audit_max_abs"] = {k: max(abs(int(r[k])) for r in summary) for k in ["population_error","money_error","goods_error"]}
out["summary_first_last"] = {k: [num(summary[0][k]), num(summary[-1][k])] for k in ["cohort_count","filled_owner_jobs","filled_employee_jobs","unemployed_population","births","deaths","production_output_stock","production_output_discarded","producer_revenue","building_wages_paid","loss_suspended_building_groups","merchant_procurement_budget","merchant_procurement_spent","production_input_reserved","production_input_reserve_shortfall"]}
# max suspended and final
out["summary_extrema"] = {
    "max_loss_suspended_building_groups": max(int(r["loss_suspended_building_groups"]) for r in summary),
    "max_unemployed_population": max(int(r["unemployed_population"]) for r in summary),
    "first_global_unemployment_day": next((int(r["day_index"]) for r in summary if int(r["unemployed_population"]) > 0), None),
    "first_global_deaths_day": next((int(r["day_index"]) for r in summary if int(r["deaths"]) > 0), None),
}
# cohorts by signature/profession
by_sig = defaultdict(list)
for r in cohorts:
    by_sig[int(r["signature_id"])].append(r)
cohort_report = []
for sig, rows in sorted(by_sig.items()):
    rows.sort(key=lambda r:int(r["day_index"]))
    first, last = rows[0], rows[-1]
    min_sat = min(int(r["satisfaction_q16"]) for r in rows)
    first_sat_low = next((int(r["day_index"]) for r in rows if int(r["satisfaction_q16"]) < 32768), None)
    first_funds_low = next((int(r["day_index"]) for r in rows if int(r["funds"]) < 100000), None)
    first_pop_loss = next((int(r["day_index"]) for r in rows if int(r["population"]) < int(first["population"])), None)
    prof_id = int(first["profession_id"])
    cohort_report.append({
        "signature_id": sig,
        "profession_id": prof_id,
        "profession": prof.get(prof_id, {}).get("id", str(prof_id)),
        "pop_first_last": [int(first["population"]), int(last["population"])],
        "funds_first_last": [int(first["funds"]), int(last["funds"])],
        "income_first_last": [int(first["epoch_income"]), int(last["epoch_income"])],
        "expense_first_last": [int(first["epoch_expense"]), int(last["epoch_expense"])],
        "owner_emp_first_last": [int(first["owner_employed"]), int(last["owner_employed"])],
        "employee_emp_first_last": [int(first["employee_employed"]), int(last["employee_employed"])],
        "unemployed_first_last": [int(first["unemployed"]), int(last["unemployed"])],
        "min_satisfaction_q16": min_sat,
        "first_sat_below_50_day": first_sat_low,
        "first_funds_below_1000_day": first_funds_low,
        "first_pop_loss_day": first_pop_loss,
        "worst_need_first_last": [need.get(int(first["worst_need_id"]), {}).get("id", first["worst_need_id"]), need.get(int(last["worst_need_id"]), {}).get("id", last["worst_need_id"])]
    })
out["cohorts"] = sorted(cohort_report, key=lambda x: x["pop_first_last"][1]-x["pop_first_last"][0])
out["cell_population_first_last"] = [sum(int(r["population"]) for r in cohorts if int(r["epoch_id"]) == int(summary[0]["epoch_id"])), sum(int(r["population"]) for r in cohorts if int(r["epoch_id"]) == int(summary[-1]["epoch_id"]))]
out["cell_funds_first_last"] = [sum(int(r["funds"]) for r in cohorts if int(r["epoch_id"]) == int(summary[0]["epoch_id"])), sum(int(r["funds"]) for r in cohorts if int(r["epoch_id"]) == int(summary[-1]["epoch_id"]))]
# market by goods of interest + top shortages
by_good = defaultdict(list)
for r in market:
    by_good[r["good_id"]].append(r)
for rows in by_good.values(): rows.sort(key=lambda r:int(r["day_index"]))
interest = ["game_meat","gathered_plants","fish","processed_food","chipped_stone_tools","logs","tools","cloth","clothing","game_meat"]
mg = {}
for g in sorted(set(interest) & set(by_good.keys())):
    rows = by_good[g]
    first, last = rows[0], rows[-1]
    mg[g] = {k: [num(first[k]), num(last[k])] for k in ["stock","price","demand_ema","business_demand_ema","offered_supply_ema","realized_withdrawal_ema","production_input_reserve","household_available_stock","merchant_procurement_shortfall","shortage_q16","price_pressure_total_q16","trade_import_ema","trade_export_ema"]}
    mg[g]["max_price"] = max(int(float(r["price"])) for r in rows)
    mg[g]["zero_household_days"] = sum(1 for r in rows if int(float(r["household_available_stock"])) == 0)
    mg[g]["shortage_days"] = sum(1 for r in rows if int(float(r["shortage_q16"])) > 32768)
out["market_interest"] = mg
# top final demand shortages (nonzero demand and low stock/shortage)
final_market = [r for r in market if int(r["epoch_id"]) == int(summary[-1]["epoch_id"])]
out["top_final_shortages"] = sorted([
    {"good": r["good_id"], "stock": num(r["stock"]), "hh_stock": num(r["household_available_stock"]), "price": num(r["price"]), "demand_ema": num(r["demand_ema"]), "business_demand_ema": num(r["business_demand_ema"]), "shortage_q16": num(r["shortage_q16"]), "pressure": num(r["price_pressure_total_q16"]), "proc_shortfall": num(r["merchant_procurement_shortfall"])}
    for r in final_market if int(float(r["shortage_q16"])) > 0 or int(float(r["demand_ema"])) > 0 or int(float(r["business_demand_ema"])) > 0
], key=lambda x:(x["shortage_q16"], x["demand_ema"]+x["business_demand_ema"]), reverse=True)[:15]
# buildings by type
by_type = defaultdict(list)
for r in buildings:
    by_type[int(r["type_id"])].append(r)
breps = []
for tid, rows in sorted(by_type.items()):
    rows.sort(key=lambda r:int(r["day_index"]))
    f,l = rows[0], rows[-1]
    breps.append({
        "type_id": tid, "building": bld.get(tid, {}).get("id", str(tid)), "owner_sig": int(f["owner_signature_id"]),
        "count": int(f["count"]),
        "filled_owner_first_last": [int(f["filled_owner"]), int(l["filled_owner"])],
        "employee_filled_first_last": [int(f["employee_filled"]), int(l["employee_filled"])],
        "capacity_first_last": [int(f["capacity_q16"]), int(l["capacity_q16"])],
        "util_first_last": [int(f["planned_utilization_q16"]), int(l["planned_utilization_q16"])],
        "last_input_first_last": [int(f["last_input"]), int(l["last_input"])],
        "last_output_first_last": [int(f["last_output"]), int(l["last_output"])],
        "last_sold_first_last": [int(f["last_sold"]), int(l["last_sold"])],
        "last_discarded_first_last": [int(f["last_discarded"]), int(l["last_discarded"])],
        "last_retained_first_last": [int(f["last_retained"]), int(l["last_retained"])],
        "last_revenue_first_last": [int(f["last_revenue"]), int(l["last_revenue"])],
        "last_input_cost_first_last": [int(f["last_input_cost"]), int(l["last_input_cost"])],
        "last_expected_revenue_first_last": [int(f["last_expected_revenue"]), int(l["last_expected_revenue"])],
        "margin_gap_first_last": [int(f["last_margin_gap_q16"]), int(l["last_margin_gap_q16"])],
        "severe_loss_cycles_final": int(l["severe_loss_cycles"]),
        "operating_state_final": int(l["operating_state"]),
        "first_zero_capacity_day": next((int(r["day_index"]) for r in rows if int(r["capacity_q16"]) == 0), None),
        "first_output_zero_after_positive_day": next((int(r["day_index"]) for r in rows if int(r["last_output"]) == 0 and any(int(prev["last_output"])>0 for prev in rows[:rows.index(r)])), None),
    })
out["buildings"] = sorted(breps, key=lambda x:(x["capacity_first_last"][1], x["filled_owner_first_last"][1]-x["filled_owner_first_last"][0], x["last_output_first_last"][1]-x["last_output_first_last"][0]))
# resources first/last and extrema
by_res = defaultdict(list)
for r in resources: by_res[r["resource_id"]].append(r)
res_interest = {}
for rid, rows in by_res.items():
    rows.sort(key=lambda r:int(r["day_index"]))
    if rid in ["timber","wild_game","fertile_soil","arable_land","stone"]:
        vals = [float(r["reserve"]) for r in rows]
        res_interest[rid] = {"first_last": [vals[0], vals[-1]], "min": min(vals), "max": max(vals)}
out["resources_interest"] = res_interest
print(json.dumps(out, ensure_ascii=False, indent=2))
