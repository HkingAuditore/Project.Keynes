#!/usr/bin/env python3
"""Focused unemployment vs investment diagnosis for one recorder family."""
from __future__ import annotations

import csv
import json
import math
import re
from collections import defaultdict
from pathlib import Path

Q16 = 65536
MONEY = 10000
GOODS = 1000
PREFIX = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260817_104006_v24_cell1780_q26_r29")
REPO = Path(r"D:\Godot\ProjectKeynes\Project.Keynes")
REJECTION = {
    0: "NONE",
    1: "PENDING_CONSTRUCTION",
    2: "SUSPENDED_CAPACITY",
    3: "ACTIVE_OWNER_VACANCY",
    4: "INSTALLED_CAPACITY_SUFFICIENT",
    5: "OWNER_LIVELIHOOD",
    6: "SELL_THROUGH",
    7: "DISCARD",
    8: "INPUT_CHAIN",
    9: "TARGET_MARGIN",
    10: "PAYBACK",
    11: "SPONSOR_CAPITAL",
    12: "MATERIALS",
    13: "RESOURCE",
    14: "PROBABILITY",
    15: "MARKET_SIGNAL",
    16: "GROWTH_LIMIT",
    17: "UNSUPPORTED_KIND",
}
FOOD_GOODS = (
    "gathered_plants", "potatoes", "grain", "bread", "prepared_staples",
    "fish", "game_meat", "meat", "canned_fish", "dairy_products",
    "vegetables", "processed_food",
)
STRESS_GOODS = ("fur", "chipped_stone_tools", "clothing", "logs", "bast_fiber", "raw_hide")
WATCH_GOODS = FOOD_GOODS + STRESS_GOODS


def i(v, default=0):
    if v in (None, ""):
        return default
    return int(float(v))


def f(v, default=0.0):
    if v in (None, ""):
        return default
    return float(v)


def catalog_ids(directory: Path) -> dict[int, str]:
    pattern = re.compile(r'^id\s*=\s*&?"([^"]+)"', re.MULTILINE)
    items = []
    if not directory.is_dir():
        return {}
    for path in directory.glob("*.tres"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        match = pattern.search(text)
        if match:
            items.append(match.group(1))
    items.sort()
    return dict(enumerate(items))


def pearson(xs, ys):
    n = len(xs)
    if n < 8:
        return None
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    dx = math.sqrt(sum((x - mx) ** 2 for x in xs))
    dy = math.sqrt(sum((y - my) ** 2 for y in ys))
    if dx == 0 or dy == 0:
        return None
    return num / (dx * dy)


def first_diff(xs):
    return [xs[i] - xs[i - 1] for i in range(1, len(xs))]


def main():
    professions = catalog_ids(REPO / "Project/project-keynes/data/economy/professions")
    buildings_cat = catalog_ids(REPO / "Project/project-keynes/data/economy/buildings")
    needs = catalog_ids(REPO / "Project/project-keynes/data/economy/needs")

    # --- summary: commit days have real employment stocks ---
    commit = []
    annual = defaultdict(lambda: {
        "births": 0, "deaths": 0, "investments_started": 0, "jobs_started": 0,
        "owner_limited": 0, "demand_limited": 0, "capital_limited": 0,
        "material_limited": 0, "catchup_cells": 0, "employment_gap": 0,
        "blocked_funds": 0, "blocked_materials": 0, "blocked_sponsor": 0,
        "blocked_resources": 0, "days": 0,
    })
    audits = {"population_error": 0, "money_error": 0, "goods_error": 0}
    first_day = last_day = None
    with (PREFIX.with_name(PREFIX.name + "_summary.csv")).open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            day = i(row["day_index"])
            first_day = day if first_day is None else first_day
            last_day = day
            for name in audits:
                audits[name] = max(audits[name], abs(i(row[name])))
            year = (day - first_day) // 365
            bucket = annual[year]
            bucket["days"] += 1
            bucket["births"] += i(row["births"])
            bucket["deaths"] += i(row["deaths"])
            bucket["investments_started"] += i(row["building_investments_started"])
            bucket["jobs_started"] += i(row.get("building_investment_jobs_started", 0))
            bucket["owner_limited"] += i(row.get("building_investment_owner_population_limited", 0))
            bucket["demand_limited"] += i(row.get("building_investment_demand_limited", 0))
            bucket["capital_limited"] += i(row.get("building_investment_capital_limited", 0))
            bucket["material_limited"] += i(row.get("building_investment_material_limited", 0))
            bucket["catchup_cells"] += i(row.get("building_investment_employment_catchup_cells", 0))
            bucket["employment_gap"] += i(row.get("building_investment_employment_gap", 0))
            bucket["blocked_funds"] += i(row.get("building_investment_blocked_funds", 0))
            bucket["blocked_materials"] += i(row.get("building_investment_blocked_materials", 0))
            bucket["blocked_sponsor"] += i(row.get("building_investment_blocked_sponsor_capital", 0))
            bucket["blocked_resources"] += i(row.get("building_investment_blocked_resources", 0))
            owners = i(row["filled_owner_jobs"])
            unemployed = i(row["unemployed_population"])
            if owners > 0 or unemployed > 0 or i(row["building_investments_started"]) > 0:
                commit.append({
                    "day": day,
                    "owners": owners,
                    "employees": i(row["filled_employee_jobs"]),
                    "unemployed": unemployed,
                    "groups": i(row["building_group_count"]),
                    "pending": i(row["pending_construction_count"]),
                    "births": i(row["births"]),
                    "deaths": i(row["deaths"]),
                    "investments": i(row["building_investments_started"]),
                    "jobs_started": i(row.get("building_investment_jobs_started", 0)),
                    "employment_gap": i(row.get("building_investment_employment_gap", 0)),
                    "catchup_cells": i(row.get("building_investment_employment_catchup_cells", 0)),
                    "demand_limited": i(row.get("building_investment_demand_limited", 0)),
                    "capital_limited": i(row.get("building_investment_capital_limited", 0)),
                    "owner_limited": i(row.get("building_investment_owner_population_limited", 0)),
                    "material_limited": i(row.get("building_investment_material_limited", 0)),
                    "blocked_sponsor": i(row.get("building_investment_blocked_sponsor_capital", 0)),
                    "blocked_resources": i(row.get("building_investment_blocked_resources", 0)),
                    "blocked_materials": i(row.get("building_investment_blocked_materials", 0)),
                    "suspended": i(row["loss_suspended_building_groups"]),
                    "discarded": i(row["production_output_discarded"]),
                    "supported": i(row["production_output_supported"]),
                    "retained": i(row["production_output_retained"]),
                    "sold_stock": i(row["production_output_stock"]),
                    "merchant_cash": i(row["merchant_cash"]),
                })

    # --- cohorts daily composition ---
    daily = {}
    last_cohorts = []
    last_cohort_day = None
    unemployed_onset = None
    with (PREFIX.with_name(PREFIX.name + "_cohorts.csv")).open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            day = i(row["day_index"])
            slot = daily.setdefault(day, {
                "pop": 0, "unemployed": 0, "owners": 0, "employees": 0,
                "merchant_pop": 0, "nonmerchant_pop": 0,
                "unemployed_funds": 0, "employed_funds": 0,
                "unemployed_income": 0, "employed_income": 0,
                "unemployed_expense": 0, "unemployed_sat": 0,
                "unemployed_livelihood": 0, "by_prof": defaultdict(int),
            })
            pop = i(row["population"])
            unemp = i(row["unemployed"])
            owners = i(row["owner_employed"])
            employees = i(row["employee_employed"])
            funds = i(row["funds"])
            income = i(row["epoch_income"])
            expense = i(row["epoch_expense"])
            prof = i(row["profession_id"])
            slot["pop"] += pop
            slot["unemployed"] += unemp
            slot["owners"] += owners
            slot["employees"] += employees
            slot["by_prof"][prof] += pop
            if i(row["is_merchant"]):
                slot["merchant_pop"] += pop
            else:
                slot["nonmerchant_pop"] += pop
            if unemp > 0 and unemp == pop:
                slot["unemployed_funds"] += funds
                slot["unemployed_income"] += income
                slot["unemployed_expense"] += expense
                slot["unemployed_sat"] = i(row["satisfaction_q16"])
                slot["unemployed_livelihood"] = i(row["livelihood_coverage_q16"])
                slot["unemployed_worst_need"] = i(row["worst_need_id"])
            else:
                slot["employed_funds"] += funds
                slot["employed_income"] += income
            if unemployed_onset is None and slot["pop"] > 0 and slot["unemployed"] / slot["pop"] >= 0.05:
                unemployed_onset = day
            if last_cohort_day != day:
                last_cohorts = []
                last_cohort_day = day
            last_cohorts.append({
                "profession_id": prof,
                "profession": professions.get(prof, str(prof)),
                "population": pop,
                "funds": funds,
                "funds_pc": funds / pop if pop else 0,
                "epoch_income": income,
                "epoch_expense": expense,
                "income_ema": i(row["income_ema"]),
                "livelihood_q16": i(row["livelihood_coverage_q16"]),
                "satisfaction_q16": i(row["satisfaction_q16"]),
                "worst_need_id": i(row["worst_need_id"]),
                "worst_need": needs.get(i(row["worst_need_id"]), str(i(row["worst_need_id"]))),
                "is_merchant": bool(i(row["is_merchant"])),
                "owners": owners,
                "employees": employees,
                "unemployed": unemp,
            })

    sampled_days = sorted(d for d in daily if d % 30 == 10 or d == min(daily) or d == max(daily))
    series = []
    for day in sampled_days:
        s = daily[day]
        pop = s["pop"]
        unemp = s["unemployed"]
        series.append({
            "day": day,
            "population": pop,
            "unemployed": unemp,
            "unemp_rate": unemp / pop if pop else 0,
            "catchup_threshold": pop / 4 if pop else 0,
            "owners": s["owners"],
            "employees": s["employees"],
            "unemployed_funds": s["unemployed_funds"],
            "employed_funds": s["employed_funds"],
            "unemployed_livelihood_q16": s["unemployed_livelihood"],
            "unemployed_sat_q16": s["unemployed_sat"],
            "by_prof": {professions.get(k, str(k)): v for k, v in s["by_prof"].items()},
        })

    # thresholds
    thresholds = {}
    for day in sorted(daily):
        s = daily[day]
        if s["pop"] <= 0:
            continue
        rate = s["unemployed"] / s["pop"]
        for key, cut in (("10pct", 0.10), ("15pct", 0.15), ("20pct", 0.20), ("25pct", 0.25)):
            if key not in thresholds and rate >= cut:
                thresholds[key] = {"day": day, "unemployed": s["unemployed"], "population": s["pop"], "rate": rate}

    # --- buildings last snapshot + last-review candidates ---
    last_actual = []
    last_actual_day = None
    last_candidates = []
    last_candidate_day = None
    review_rej = defaultdict(lambda: defaultdict(int))  # day -> reason -> count
    type_rej_last = defaultdict(lambda: defaultdict(int))
    openings_series = []
    with (PREFIX.with_name(PREFIX.name + "_buildings.csv")).open(encoding="utf-8-sig", newline="") as handle:
        current_actual = []
        current_cand = []
        current_day = None
        current_openings = 0
        current_filled = 0
        current_capacity = 0
        current_suspended = 0
        current_count = 0
        def flush(day, actual, cand, openings, filled, capacity, suspended, count):
            nonlocal last_actual, last_actual_day, last_candidates, last_candidate_day
            if actual:
                last_actual = actual
                last_actual_day = day
                openings_series.append({
                    "day": day,
                    "openings": openings,
                    "filled_owner": filled,
                    "owner_capacity": capacity,
                    "suspended_groups": suspended,
                    "building_count": count,
                })
            if cand:
                last_candidates = cand
                last_candidate_day = day
                for item in cand:
                    review_rej[day][item["reason"]] += 1
                    type_rej_last[item["type_id"]][item["reason"]] += 1
        for row in csv.DictReader(handle):
            day = i(row["day_index"])
            if current_day is None:
                current_day = day
            if day != current_day:
                flush(current_day, current_actual, current_cand, current_openings,
                      current_filled, current_capacity, current_suspended, current_count)
                current_actual, current_cand = [], []
                current_openings = current_filled = current_capacity = 0
                current_suspended = current_count = 0
                current_day = day
            if i(row.get("investment_candidate", 0)):
                current_cand.append({
                    "type_id": i(row["type_id"]),
                    "building": buildings_cat.get(i(row["type_id"]), str(i(row["type_id"]))),
                    "reason": i(row["investment_rejection_reason"]),
                    "reason_name": REJECTION.get(i(row["investment_rejection_reason"]), str(i(row["investment_rejection_reason"]))),
                    "score_q16": i(row["investment_score_q16"]),
                    "shortage_q16": i(row["investment_shortage_q16"]),
                    "util_q16": i(row["investment_utilization_q16"]),
                    "capital": i(row["investment_required_capital"]),
                    "profit_per_day": i(row["investment_projected_profit_per_day"]),
                    "driver": row.get("investment_driver_good_id", ""),
                    "driver_pressure_q16": i(row.get("investment_driver_pressure_q16", 0)),
                    "sell_through_q16": i(row.get("investment_driver_sell_through_q16", 0)),
                    "discard_q16": i(row.get("investment_driver_discard_q16", 0)),
                    "payback": i(row["investment_payback_days"]),
                    "failed_material_group": i(row.get("investment_failed_material_group", -1)),
                    "materials": row.get("investment_selected_material_good_ids", ""),
                })
                continue
            if i(row["is_construction"]):
                continue
            if i(row["group_index"]) < 0:
                continue
            rec = {
                "type_id": i(row["type_id"]),
                "building": buildings_cat.get(i(row["type_id"]), str(i(row["type_id"]))),
                "count": i(row["count"]),
                "owner_capacity": i(row["owner_capacity"]),
                "owner_required": i(row["owner_required"]),
                "filled_owner": i(row["filled_owner"]),
                "owner_openings": i(row["owner_openings"]),
                "employee_required": i(row["employee_required"]),
                "employee_filled": i(row["employee_filled"]),
                "operating_state": i(row["operating_state"]),
                "util_q16": i(row["planned_utilization_q16"]),
                "funded_util_q16": i(row["funded_capacity_q16"]),
                "margin_q16": i(row["realized_profit_margin_q16"]),
                "income_gap": i(row["viability_income_gap"]),
                "last_output": i(row["last_output"]),
                "last_sold": i(row["last_sold"]),
                "last_discarded": i(row["last_discarded"]),
                "last_retained": i(row["last_retained"]),
                "reason": i(row["investment_rejection_reason"]),
                "reason_name": REJECTION.get(i(row["investment_rejection_reason"]), "?"),
            }
            current_actual.append(rec)
            current_openings += rec["owner_openings"]
            current_filled += rec["filled_owner"]
            current_capacity += rec["owner_capacity"]
            current_count += rec["count"]
            if rec["operating_state"] == 1:
                current_suspended += 1
        if current_day is not None:
            flush(current_day, current_actual, current_cand, current_openings,
                  current_filled, current_capacity, current_suspended, current_count)

    # last-review rejection mix and viable types
    last_review_mix = defaultdict(int)
    viable = []
    livelihood_fail = []
    market_fail_with_pressure = []
    for item in last_candidates:
        last_review_mix[item["reason_name"]] += 1
        if item["reason"] == 0:
            viable.append(item)
        elif item["reason"] == 5:
            livelihood_fail.append(item)
        elif item["reason"] == 15 and item["shortage_q16"] > 0:
            market_fail_with_pressure.append(item)

    livelihood_fail.sort(key=lambda x: -x["shortage_q16"])
    viable.sort(key=lambda x: -x["score_q16"])

    # --- market last + sampled for watch goods ---
    market_last = {}
    market_sampled = defaultdict(list)
    with (PREFIX.with_name(PREFIX.name + "_market.csv")).open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            gid = row["good_id"]
            if gid not in WATCH_GOODS:
                continue
            day = i(row["day_index"])
            rec = {
                "day": day,
                "stock": i(row["stock"]),
                "demand_ema": i(row["demand_ema"]),
                "supply_ema": i(row["offered_supply_ema"]),
                "withdrawal_ema": i(row["realized_withdrawal_ema"]),
                "shortage_q16": i(row["shortage_q16"]),
                "price": i(row["price"]),
                "hh_stock": i(row["household_available_stock"]),
                "target": i(row["merchant_inventory_target"]),
                "shortfall": i(row["merchant_procurement_shortfall"]),
            }
            market_last[gid] = rec
            if day % 30 == 10:
                market_sampled[gid].append(rec)

    # --- resources last for food-binding ---
    resource_last = {}
    with (PREFIX.with_name(PREFIX.name + "_resources.csv")).open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            rid = row["resource_id"]
            if rid not in ("fertile_soil", "wild_game", "freshwater_fish", "timber", "flint"):
                continue
            resource_last[rid] = {
                "opening": f(row["opening_reserve"]),
                "reserve": f(row["reserve"]),
                "safe_yield": f(row["safe_yield"]),
                "life": f(row["projected_life_days"]),
                "extract_applied": f(row["artificial_extraction_applied"]),
                "extract_pending": f(row["artificial_extraction_pending"]),
                "natural_net": f(row["natural_net_change"]),
            }

    first_s = daily[min(daily)]
    last_s = daily[max(daily)]
    commit_unemp = [c["unemployed"] for c in commit]
    commit_invest = [c["investments"] for c in commit]
    commit_jobs = [c["jobs_started"] for c in commit]
    # align cohort sampled with investments on same days
    invest_by_day = {c["day"]: c["investments"] for c in commit}
    jobs_by_day = {c["day"]: c["jobs_started"] for c in commit}
    catchup_by_day = {c["day"]: c["catchup_cells"] for c in commit}
    aligned_rate = []
    aligned_invest = []
    aligned_gap = []
    for c in commit:
        d = daily.get(c["day"])
        if not d or d["pop"] <= 0:
            continue
        aligned_rate.append(d["unemployed"] / d["pop"])
        aligned_invest.append(c["investments"])
        aligned_gap.append(max(0, d["unemployed"] - d["pop"] / 4))

    # yearly cohort snapshot
    years = []
    for year, bucket in sorted(annual.items()):
        day = first_day + year * 365
        # nearest daily
        nearest = min(daily, key=lambda d: abs(d - day)) if daily else None
        snap = daily.get(nearest, {})
        pop = snap.get("pop", 0)
        years.append({
            "year": year,
            "day_start": day,
            **bucket,
            "population": pop,
            "unemployed": snap.get("unemployed", 0),
            "unemp_rate": snap.get("unemployed", 0) / pop if pop else 0,
            "owners": snap.get("owners", 0),
        })

    last_pop = last_s["pop"]
    last_unemp = last_s["unemployed"]
    catchup_needed = last_unemp > last_pop / 4
    output = {
        "scope": {
            "days": [first_day, last_day],
            "cell": 1780,
            "note": "summary.cohort_count=6 and cell 1780 last cohorts=6; world employment equals this cell",
            "audits": audits,
            "births": sum(b["births"] for b in annual.values()),
            "deaths": sum(b["deaths"] for b in annual.values()),
        },
        "last_cohorts": last_cohorts,
        "last_population": last_pop,
        "last_unemployed": last_unemp,
        "last_unemp_rate": last_unemp / last_pop if last_pop else 0,
        "catchup_threshold_people": last_pop / 4,
        "catchup_would_fire": catchup_needed,
        "unemployed_onset_5pct": unemployed_onset,
        "thresholds": thresholds,
        "first_composition": {professions.get(k, str(k)): v for k, v in first_s["by_prof"].items()},
        "last_composition": {professions.get(k, str(k)): v for k, v in last_s["by_prof"].items()},
        "years": years,
        "series_30d": series,
        "commit_last": commit[-3:] if commit else [],
        "commit_first": commit[:3],
        "investment_totals": {
            "started": sum(c["investments"] for c in commit),
            "jobs_started": sum(c["jobs_started"] for c in commit),
            "catchup_cell_days": sum(c["catchup_cells"] for c in commit),
            "employment_gap_sum": sum(c["employment_gap"] for c in commit),
            "demand_limited": sum(c["demand_limited"] for c in commit),
            "capital_limited": sum(c["capital_limited"] for c in commit),
            "owner_limited": sum(c["owner_limited"] for c in commit),
            "material_limited": sum(c["material_limited"] for c in commit),
            "blocked_sponsor": sum(c["blocked_sponsor"] for c in commit),
            "blocked_resources": sum(c["blocked_resources"] for c in commit),
        },
        "correlations": {
            "unemp_rate_vs_investments_level": pearson(aligned_rate, aligned_invest),
            "unemp_rate_vs_investments_d1": pearson(first_diff(aligned_rate), first_diff(aligned_invest)) if len(aligned_rate) > 9 else None,
            "samples": len(aligned_rate),
        },
        "last_buildings_day": last_actual_day,
        "last_buildings": last_actual,
        "last_openings": openings_series[-1] if openings_series else None,
        "openings_sampled": [x for x in openings_series if x["day"] % 180 == 10][-12:],
        "last_review_day": last_candidate_day,
        "last_review_mix": dict(last_review_mix),
        "last_review_viable": viable[:12],
        "last_review_livelihood_top": livelihood_fail[:12],
        "last_review_market_signal_with_pressure": sorted(market_fail_with_pressure, key=lambda x: -x["shortage_q16"])[:8],
        "market_last": market_last,
        "market_sampled_keys": {k: v[:: max(1, len(v)//24)] for k, v in market_sampled.items()},
        "resource_last": resource_last,
        "unemployed_funds_last": last_s["unemployed_funds"],
        "employed_funds_last": last_s["employed_funds"],
        "unemployed_livelihood_q16": last_s["unemployed_livelihood"],
        "unemployed_sat_q16": last_s["unemployed_sat"],
        "catchup_ever": any(c["catchup_cells"] > 0 for c in commit),
        "catchup_days": [c["day"] for c in commit if c["catchup_cells"] > 0][:20],
        "catchup_day_count": sum(1 for c in commit if c["catchup_cells"] > 0),
    }
    out = PREFIX.with_name(PREFIX.name + "_unemployment_diag.json")
    out.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "wrote": str(out),
        "last_unemp_rate": output["last_unemp_rate"],
        "catchup_would_fire": catchup_needed,
        "catchup_day_count": output["catchup_day_count"],
        "investments": output["investment_totals"]["started"],
        "last_review_day": last_candidate_day,
        "last_review_mix": dict(last_review_mix),
        "thresholds": thresholds,
        "audits": audits,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
