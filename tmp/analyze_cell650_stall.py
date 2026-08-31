import csv
import json
import math
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFIX = ROOT / "tmp" / "economy_record_20260831_140522_v25_cell650_q45_r10"
Q16 = 65536


def rows(kind):
    with Path(f"{PREFIX}_{kind}.csv").open(encoding="utf-8-sig", newline="") as f:
        yield from csv.DictReader(f)


def i(row, name):
    value = row.get(name, "")
    return int(float(value)) if value else 0


def f(row, name):
    value = row.get(name, "")
    return float(value) if value else 0.0


def avg(values):
    return sum(values) / len(values) if values else 0.0


def pct(num, den):
    return num / den if den else None


def catalog_ids(folder):
    import re
    found = []
    for path in folder.glob("*.tres"):
        match = re.search(r'^id\s*=\s*&?"([^"]+)"', path.read_text(encoding="utf-8", errors="ignore"), re.M)
        if match:
            found.append(match.group(1))
    return sorted(found)


summary = list(rows("summary"))
cohorts = list(rows("cohorts"))
market = list(rows("market"))
buildings = list(rows("buildings"))
resources = list(rows("resources"))
days = [i(r, "day_index") for r in summary]
day_first, day_last = days[0], days[-1]
early_end, late_start = day_first + 89, day_last - 89

cohort_daily = defaultdict(lambda: defaultdict(float))
cohort_events = []
prev_pop = {}
for r in cohorts:
    day = i(r, "day_index")
    pop = i(r, "population")
    d = cohort_daily[day]
    for key in ("population", "funds", "epoch_income", "epoch_expense", "epoch_in_kind_income",
                "owner_employed", "employee_employed", "unemployed"):
        d[key] += i(r, key)
    d["satisfaction_weighted"] += pop * i(r, "satisfaction_q16")
    d["livelihood_weighted"] += pop * i(r, "livelihood_coverage_q16")
    d["weight"] += pop
    sig = i(r, "signature_id")
    old = prev_pop.get(sig)
    if old is not None and old != pop:
        cohort_events.append({
            "day": day, "signature_id": sig, "profession_id": i(r, "profession_id"),
            "from": old, "to": pop, "delta": pop - old,
            "satisfaction_q16": i(r, "satisfaction_q16"),
            "livelihood_coverage_q16": i(r, "livelihood_coverage_q16"),
            "worst_need_id": i(r, "worst_need_id"),
        })
    prev_pop[sig] = pop

for d in cohort_daily.values():
    d["satisfaction_q16"] = d["satisfaction_weighted"] / d["weight"]
    d["livelihood_q16"] = d["livelihood_weighted"] / d["weight"]

market_by_good = defaultdict(list)
merchant_by_day = {}
for r in market:
    market_by_good[r["good_id"]].append(r)
    merchant_by_day.setdefault(i(r, "day_index"), {
        "merchant_cash": i(r, "merchant_cash"),
        "merchant_economic_assets": i(r, "merchant_economic_assets"),
        "merchant_liquidity_coverage_q16": i(r, "merchant_liquidity_coverage_q16"),
        "merchant_effective_buy_factor_q16": i(r, "merchant_effective_buy_factor_q16"),
    })

market_stats = []
for good, rr in market_by_good.items():
    active = [r for r in rr if any(i(r, k) for k in (
        "stock", "demand_ema", "business_demand_ema", "offered_supply_ema",
        "realized_withdrawal_ema", "production_input_reserve"))]
    if not active:
        continue
    early = [r for r in rr if i(r, "day_index") <= early_end]
    late = [r for r in rr if i(r, "day_index") >= late_start]
    def window(x):
        return {
            k: avg([i(r, k) for r in x]) for k in (
                "stock", "household_available_stock", "demand_ema", "business_demand_ema",
                "offered_supply_ema", "realized_withdrawal_ema", "production_input_reserve",
                "merchant_inventory_target", "merchant_procurement_shortfall", "shortage_q16",
                "price", "trade_import_ema", "trade_export_ema", "trade_inbound", "trade_outbound")
        }
    market_stats.append({
        "good_id": good,
        "active_days": len(active),
        "shortage_share": pct(sum(i(r, "shortage_q16") > 0 for r in active), len(active)),
        "severe_shortage_share": pct(sum(i(r, "shortage_q16") >= Q16 // 2 for r in active), len(active)),
        "stockout_share": pct(sum(i(r, "stock") <= 0 for r in active), len(active)),
        "household_unavailable_share": pct(sum(i(r, "household_available_stock") <= 0 for r in active), len(active)),
        "early": window(early),
        "late": window(late),
        "first": {k: i(rr[0], k) for k in ("stock", "household_available_stock", "price", "shortage_q16")},
        "last": {k: i(rr[-1], k) for k in ("stock", "household_available_stock", "price", "shortage_q16")},
    })
market_stats.sort(key=lambda x: (x["late"]["demand_ema"], x["late"]["business_demand_ema"]), reverse=True)

building_ids = catalog_ids(ROOT / "Project" / "project-keynes" / "data" / "economy" / "buildings")
actual = [r for r in buildings if not i(r, "is_construction") and not i(r, "investment_candidate")
          and i(r, "group_index") >= 0]
building_by_type = defaultdict(list)
for r in actual:
    building_by_type[i(r, "type_id")].append(r)

building_stats = []
for type_id, rr in building_by_type.items():
    early = [r for r in rr if i(r, "day_index") <= early_end]
    late = [r for r in rr if i(r, "day_index") >= late_start]
    def sums(x, names):
        return {name: sum(i(r, name) for r in x) for name in names}
    flow_names = ("last_input", "last_output", "last_sold", "last_discarded", "last_retained",
                  "last_revenue", "last_input_cost", "last_wages_paid", "last_wages_due",
                  "owner_livelihood_required", "viability_operating_cost", "last_resource",
                  "last_climate_lost_output")
    totals = sums(rr, flow_names)
    latest_rows = [r for r in rr if i(r, "day_index") == day_last]
    latest = sums(latest_rows, ("count", "owner_capacity", "owner_required", "filled_owner",
                                "owner_openings", "employee_required", "employee_filled"))
    building_stats.append({
        "type_id": type_id,
        "building": building_ids[type_id] if type_id < len(building_ids) else str(type_id),
        "totals": totals,
        "latest": latest,
        "sell_through": pct(totals["last_sold"], totals["last_output"]),
        "discard_share": pct(totals["last_discarded"], totals["last_output"]),
        "revenue_cost_coverage": pct(totals["last_revenue"], totals["viability_operating_cost"]),
        "livelihood_coverage": pct(totals["last_revenue"], totals["owner_livelihood_required"]),
        "early_utilization_q16": avg([i(r, "planned_utilization_q16") for r in early]),
        "late_utilization_q16": avg([i(r, "planned_utilization_q16") for r in late]),
        "early_capacity_q16": avg([i(r, "capacity_q16") for r in early]),
        "late_capacity_q16": avg([i(r, "capacity_q16") for r in late]),
        "late_margin_q16": avg([i(r, "realized_profit_margin_q16") for r in late]),
        "suspended_days": len({i(r, "day_index") for r in rr if i(r, "operating_state") == 1}),
    })
building_stats.sort(key=lambda x: x["totals"]["last_output"], reverse=True)

employment_rows = [r for r in buildings if i(r, "employment_candidate")]
employment_rejections = defaultdict(lambda: {"rows": 0, "eligible": 0, "take": 0, "vacancy": 0})
for r in employment_rows:
    key = r["employment_rejection_reason"] or "accepted"
    d = employment_rejections[key]
    d["rows"] += 1
    d["eligible"] += i(r, "employment_eligible")
    d["take"] += i(r, "employment_take")
    d["vacancy"] += i(r, "employment_vacancy")

investment_rows = [r for r in buildings if i(r, "investment_candidate")]
investment_rejections = defaultdict(int)
for r in investment_rows:
    investment_rejections[r["investment_rejection_reason"] or "accepted"] += 1

resource_by_id = defaultdict(list)
for r in resources:
    resource_by_id[r["resource_id"]].append(r)
resource_stats = []
for resource, rr in resource_by_id.items():
    first, last = rr[0], rr[-1]
    resource_stats.append({
        "resource_id": resource,
        "first_reserve": f(first, "reserve"),
        "last_reserve": f(last, "reserve"),
        "delta": f(last, "reserve") - f(first, "reserve"),
        "min_reserve": min(f(r, "reserve") for r in rr),
        "natural_positive": sum(f(r, "natural_positive_change") for r in rr),
        "natural_negative": sum(f(r, "natural_negative_change") for r in rr),
        "extraction_applied": sum(f(r, "artificial_extraction_applied") for r in rr),
        "extraction_pending": sum(f(r, "artificial_extraction_pending") for r in rr),
        "min_projected_life_days": min((f(r, "projected_life_days") for r in rr if f(r, "projected_life_days") > 0), default=None),
        "last_safe_yield": f(last, "safe_yield"),
        "last_projected_life_days": f(last, "projected_life_days"),
    })
resource_stats.sort(key=lambda x: x["delta"])

sample_indices = sorted(set(round(j * (len(days) - 1) / 11) for j in range(12)))
timeline = []
market_lookup = {(i(r, "day_index"), r["good_id"]): r for r in market}
for idx in sample_indices:
    day = days[idx]
    d = cohort_daily[day]
    point = {
        "day": day,
        "population": int(d["population"]),
        "income": int(d["epoch_income"]),
        "expense": int(d["epoch_expense"]),
        "in_kind": int(d["epoch_in_kind_income"]),
        "satisfaction_pct": d["satisfaction_q16"] / Q16 * 100,
        "livelihood_pct": d["livelihood_q16"] / Q16 * 100,
        "owner_employed": int(d["owner_employed"]),
        "employee_employed": int(d["employee_employed"]),
        "unemployed": int(d["unemployed"]),
    }
    for good in ("prepared_staples", "gathered_plants", "game_meat", "fish", "clothing", "charcoal"):
        r = market_lookup[(day, good)]
        point[f"{good}_shortage_pct"] = i(r, "shortage_q16") / Q16 * 100
        point[f"{good}_available"] = i(r, "household_available_stock")
    timeline.append(point)

summary_result = {
    "range": {"first_day": day_first, "last_day": day_last, "days": len(days)},
    "local_first": {k: cohort_daily[day_first][k] for k in (
        "population", "funds", "epoch_income", "epoch_expense", "epoch_in_kind_income",
        "owner_employed", "employee_employed", "unemployed", "satisfaction_q16", "livelihood_q16")},
    "local_last": {k: cohort_daily[day_last][k] for k in (
        "population", "funds", "epoch_income", "epoch_expense", "epoch_in_kind_income",
        "owner_employed", "employee_employed", "unemployed", "satisfaction_q16", "livelihood_q16")},
    "global_flow_totals": {name: sum(i(r, name) for r in summary) for name in (
        "births", "deaths", "building_investments_started", "building_owner_mobility",
        "building_owner_job_reallocations", "production_output_stock",
        "production_output_discarded", "production_output_retained", "building_wages_paid",
        "building_wages_unpaid")},
    "global_demography_events": [
        {"day": i(r, "day_index"), "births": i(r, "births"), "deaths": i(r, "deaths")}
        for r in summary if i(r, "births") or i(r, "deaths")
    ],
    "audit_max": {name: max(abs(i(r, name)) for r in summary) for name in (
        "population_error", "money_error", "goods_error")},
    "population_events": cohort_events,
    "market": market_stats,
    "buildings": building_stats,
    "employment_candidates": {
        "rows": len(employment_rows),
        "rejections": dict(sorted(employment_rejections.items(), key=lambda kv: kv[1]["rows"], reverse=True)),
    },
    "investment_candidates": {
        "rows": len(investment_rows),
        "rejections": dict(sorted(investment_rejections.items(), key=lambda kv: kv[1], reverse=True)),
    },
    "resources": resource_stats,
    "merchant_first": merchant_by_day[day_first],
    "merchant_last": merchant_by_day[day_last],
    "timeline": timeline,
}

out = ROOT / "tmp" / "economy_record_20260831_140522_v25_cell650_q45_r10_stall_diagnosis.json"
out.write_text(json.dumps(summary_result, ensure_ascii=False, indent=2), encoding="utf-8")
print(out)
