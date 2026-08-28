import csv, collections

BASE = "tmp/economy_record_20260828_231131_v25_cell1788_q34_r29_"

def load(name):
    with open(BASE + name + ".csv", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def f(x):
    try:
        return float(x)
    except Exception:
        return 0.0

s = load("summary")
print("-- global employment / demography time series (only change points) --")
watch = ["filled_owner_jobs", "filled_employee_jobs", "unemployed_population",
         "births", "deaths", "cohort_count", "building_group_count",
         "production_output_stock", "production_output_retained",
         "loss_suspended_building_groups", "maintenance_goods_consumed"]
prev = None
n = 0
for r in s:
    cur = tuple(r[c] for c in watch)
    if cur != prev:
        print("  day=%-6s %s" % (r["day_index"], dict(zip(watch, cur))))
        prev = cur
        n += 1
print("  total change points: %d over %d days" % (n, len(s)))

print("\n-- grp2 (type103) opportunity detail --")
b = load("buildings")
g2 = [r for r in b if r["group_index"] == "2"]
for k in ["owner_capacity", "owner_required", "filled_owner", "owner_openings",
          "capacity_q16", "planned_utilization_q16", "funded_capacity_q16",
          "opportunity_owner_income_per_day", "owner_living_cost_per_day",
          "opportunity_disposable_survival_power_per_day",
          "opportunity_executable_capacity_q16", "opportunity_in_kind_retail_value",
          "projected_owner_income_per_day", "owner_livelihood_required",
          "viability_operating_cost", "viability_income_gap",
          "last_output", "last_sold", "last_retained", "last_discarded", "last_revenue",
          "realized_profit_margin_q16", "survival_priority", "survival_shortage_q16",
          "last_resource", "last_resource_generated", "investment_driver_sell_through_q16",
          "investment_driver_merchant_sold", "investment_driver_sellable"]:
    if k not in g2[0]:
        continue
    v = [f(r[k]) for r in g2]
    print("  %-48s first=%-14.0f last=%-14.0f min=%-14.0f max=%-14.0f uniq=%d" % (
        k, v[0], v[-1], min(v), max(v), len({r[k] for r in g2})))

print("\n-- grp3 (type297, the only employee job) detail --")
g3 = [r for r in b if r["group_index"] == "3"]
for k in ["employee_required", "employee_filled", "wage_suspended", "operating_state",
          "capacity_q16", "planned_utilization_q16",
          "opportunity_owner_income_per_day",
          "opportunity_disposable_survival_power_per_day",
          "projected_owner_income_per_day", "realized_profit_margin_q16",
          "last_wages_due", "last_wages_paid", "last_base_wages_due",
          "viability_operating_cost", "viability_income_gap", "last_revenue"]:
    if k not in g3[0]:
        continue
    v = [f(r[k]) for r in g3]
    print("  %-48s first=%-14.0f last=%-14.0f min=%-14.0f max=%-14.0f uniq=%d" % (
        k, v[0], v[-1], min(v), max(v), len({r[k] for r in g3})))
