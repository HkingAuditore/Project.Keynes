import csv, collections, statistics

BASE = "tmp/economy_record_20260828_231131_v25_cell1788_q34_r29_"

def load(name):
    with open(BASE + name + ".csv", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))

def f(x):
    try:
        return float(x)
    except Exception:
        return 0.0

b = load("buildings")
groups = collections.OrderedDict()
for r in b:
    groups.setdefault((r["group_index"], r["type_id"]), []).append(r)

FIELDS = ["owner_capacity", "owner_required", "filled_owner", "owner_openings",
          "employee_required", "employee_filled",
          "capacity_q16", "planned_utilization_q16", "funded_capacity_q16",
          "purchase_intent_capacity_q16",
          "opportunity_owner_income_per_day", "owner_living_cost_per_day",
          "opportunity_disposable_survival_power_per_day",
          "opportunity_executable_capacity_q16", "opportunity_in_kind_retail_value",
          "projected_owner_income_per_day", "owner_livelihood_required",
          "viability_operating_cost", "viability_income_gap",
          "last_output", "last_sold", "last_retained", "last_supported" if False else "last_discarded",
          "last_revenue", "last_input", "last_input_cost",
          "last_wages_due", "last_wages_paid", "last_in_kind_livelihood_value",
          "survival_priority", "survival_shortage_q16",
          "realized_profit_margin_q16", "operating_state",
          "investment_rejection_reason", "investment_candidate",
          "investment_required_capital", "investment_score_q16",
          "investment_driver_good_id", "investment_driver_pressure_q16",
          "last_climate_capacity_q16", "last_temperature_fit_q16", "last_water_fit_q16"]

for (gi, ti), rows in groups.items():
    if gi == "-1":
        continue
    rl = rows[-1]
    print("\n===== group_index=%s type_id=%s owner_sig=%s count=%s =====" % (gi, ti, rl["owner_signature_id"], rl["count"]))
    for k in FIELDS:
        if k not in rl:
            continue
        vals = [f(r[k]) for r in rows]
        uniq = len({r[k] for r in rows})
        print("  %-48s last=%-16.0f min=%-14.0f max=%-14.0f uniq=%d" % (k, vals[-1], min(vals), max(vals), uniq))

print("\n\n===== candidate rows (group_index=-1) rejection reason over time =====")
REASON = {0:"NONE",1:"PENDING_CONSTRUCTION",2:"SUSPENDED_CAPACITY",3:"ACTIVE_OWNER_VACANCY",
          4:"INSTALLED_CAPACITY_SUFFICIENT",5:"OWNER_LIVELIHOOD",6:"SELL_THROUGH",7:"DISCARD",
          8:"INPUT_CHAIN",9:"TARGET_MARGIN",10:"PAYBACK",11:"SPONSOR_CAPITAL",12:"MATERIALS",
          13:"RESOURCE",14:"PROBABILITY",15:"MARKET_SIGNAL",16:"GROWTH_LIMIT",
          17:"UNSUPPORTED_KIND",18:"NO_COST_ADVANTAGE"}
for (gi, ti), rows in groups.items():
    if gi != "-1":
        continue
    c = collections.Counter(int(f(r["investment_rejection_reason"])) for r in rows)
    print("  type_id=%-6s %s" % (ti, {REASON.get(k,k): v for k, v in c.most_common()}))
    rl = rows[-1]
    print("      req_capital=%s score_q16=%s driver_good=%s driver_pressure=%s shortage_q16=%s util_q16=%s stealable=%s failed_material_group=%s sel_mats=%s" % (
        rl["investment_required_capital"], rl["investment_score_q16"], rl["investment_driver_good_id"],
        rl["investment_driver_pressure_q16"], rl["investment_shortage_q16"],
        rl["investment_utilization_q16"], rl["investment_stealable"],
        rl["investment_failed_material_group"], rl["investment_selected_material_good_ids"]))

# also: rejection reason on ACTUAL groups
print("\n===== actual-group rejection reason distribution =====")
for (gi, ti), rows in groups.items():
    if gi == "-1":
        continue
    c = collections.Counter(int(f(r["investment_rejection_reason"])) for r in rows)
    print("  grp=%-4s type=%-6s %s" % (gi, ti, {REASON.get(k,k): v for k, v in c.most_common()}))
