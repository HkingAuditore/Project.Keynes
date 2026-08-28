import csv, statistics, collections, json

BASE = "tmp/economy_record_20260828_231131_v25_cell1788_q34_r29_"

def load(name):
    with open(BASE + name + ".csv", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def num(x):
    try:
        return float(x)
    except Exception:
        return None

# ---------- 1. summary: how many columns actually move ----------
summary = load("summary")
cols = [c for c in summary[0].keys()]
const, moving = [], []
for c in cols:
    vals = [r[c] for r in summary]
    uniq = set(vals)
    if len(uniq) == 1:
        const.append((c, vals[0]))
    else:
        moving.append((c, len(uniq), vals[0], vals[-1]))
print("summary rows=%d cols=%d  constant=%d moving=%d" % (len(summary), len(cols), len(const), len(moving)))
print("\n-- MOVING summary columns --")
for c, n, a, b in moving:
    print("  %-52s uniq=%-5d first=%-14s last=%s" % (c, n, a, b))

print("\n-- selected constant summary columns --")
watch = ["filled_owner_jobs","filled_employee_jobs","unemployed_population","births","deaths",
         "building_group_count","pending_construction_count","building_type_count",
         "population_error","money_error","goods_error","trade_runtime_mode","trade_topology_ready",
         "building_investment_candidates","building_investments_started",
         "building_investment_blocked_funds","building_investment_blocked_materials",
         "building_investment_blocked_sponsor_capital","building_investment_blocked_resources",
         "building_investment_probability_skips","building_owner_mobility",
         "building_owner_job_reallocations","building_employee_to_owner_reallocations",
         "loss_suspended_building_groups","producer_revenue","building_wages_paid",
         "production_output_stock","production_inputs_consumed","cycle_flow_produced",
         "cycle_flow_consumed","desired_business_demand","funded_business_demand",
         "unfunded_business_demand","merchant_cash","stage","epoch_active","progress_q16",
         "recovery_candidates","recovery_liquidated_buildings","building_investment_demand_limited",
         "building_investment_material_limited","building_investment_capital_limited"]
d0 = summary[0]
dl = summary[-1]
for c in watch:
    if c in d0:
        print("  %-52s first=%-14s last=%s" % (c, d0[c], dl[c]))

print("\n-- day/epoch sanity --")
print("  day_index", summary[0]["day_index"], "->", summary[-1]["day_index"])
print("  epoch_id", summary[0]["epoch_id"], "->", summary[-1]["epoch_id"])
print("  sample_day/commit_day first", summary[0]["sample_day"], summary[0]["commit_day"],
      " last", summary[-1]["sample_day"], summary[-1]["commit_day"])
