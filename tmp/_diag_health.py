#!/usr/bin/env python3
"""Focused health diagnosis for one economy recorder family."""
from __future__ import annotations

import csv
import json
from collections import defaultdict
from pathlib import Path

PREFIX = Path("tmp/economy_record_20260901_164046_v25_cell1522_q15_r15")
Q16 = 65536
MONEY = 10000.0
GOODS = 1000.0


def fnum(x, default=0.0):
    try:
        if x is None or x == "":
            return default
        return float(x)
    except Exception:
        return default


def inum(x, default=0):
    try:
        if x is None or x == "":
            return default
        return int(float(x))
    except Exception:
        return default


def analyze_summary():
    path = Path(str(PREFIX) + "_summary.csv")
    rows = 0
    audits = {"population_error": 0, "money_error": 0, "goods_error": 0, "nonzero_days": []}
    births = deaths = 0
    first = last = None
    death_days = []
    birth_days = []
    wage_unpaid_days = []
    suspend_days = []
    invest_started = 0
    trade_disp = trade_arr = 0
    trade_cap_used_max = 0
    deadline_miss_max = 0
    unresolved_no_attempt_max = 0
    unfunded_sum = funded_sum = desired_sum = 0
    discard_sum = retained_sum = 0
    bullion_sum = 0
    wages_paid_sum = 0
    merchant_cash_series = []
    owner_jobs_series = []
    unemployed_series = []
    loss_suspend_series = []
    climate_lim_series = []
    windows = {
        "early": [],  # first 180
        "mid": [],
        "late": [],  # last 180
    }
    day_first = day_last = None
    all_days = []

    with path.open(newline="", encoding="utf-8") as fh:
        r = csv.DictReader(fh)
        for row in r:
            rows += 1
            day = inum(row["day_index"])
            all_days.append(day)
            if day_first is None:
                day_first = day
                first = row
            last = row
            day_last = day

            for k in ("population_error", "money_error", "goods_error"):
                v = inum(row.get(k))
                if v != 0:
                    audits[k] += 1
                    if len(audits["nonzero_days"]) < 20:
                        audits["nonzero_days"].append((day, k, v))

            b = inum(row.get("births"))
            d = inum(row.get("deaths"))
            births += b
            deaths += d
            if d > 0:
                death_days.append((day, d))
            if b > 0:
                birth_days.append((day, b))

            if inum(row.get("building_wages_unpaid")) > 0:
                wage_unpaid_days.append(day)
            if inum(row.get("loss_suspended_building_groups")) > 0:
                suspend_days.append((day, inum(row["loss_suspended_building_groups"])))

            invest_started += inum(row.get("building_investments_started"))
            trade_disp += inum(row.get("trade_orders_dispatched"))
            trade_arr += inum(row.get("trade_orders_arrived"))
            trade_cap_used_max = max(trade_cap_used_max, inum(row.get("trade_capacity_used")))
            deadline_miss_max = max(
                deadline_miss_max, inum(row.get("trade_response_deadline_misses_cumulative") or 0)
            )
            unresolved_no_attempt_max = max(
                unresolved_no_attempt_max, inum(row.get("trade_unresolved_no_attempt") or 0)
            )
            unfunded_sum += inum(row.get("unfunded_business_demand"))
            funded_sum += inum(row.get("funded_business_demand"))
            desired_sum += inum(row.get("desired_business_demand"))
            discard_sum += inum(row.get("production_output_discarded"))
            retained_sum += inum(row.get("production_output_retained"))
            bullion_sum += inum(row.get("bullion_money_issued"))
            wages_paid_sum += inum(row.get("building_wages_paid"))

            merchant_cash_series.append((day, inum(row.get("merchant_cash"))))
            owner_jobs_series.append((day, inum(row.get("filled_owner_jobs"))))
            unemployed_series.append((day, inum(row.get("unemployed_population"))))
            loss_suspend_series.append((day, inum(row.get("loss_suspended_building_groups"))))
            climate_lim_series.append((day, inum(row.get("climate_limited_building_groups") or 0)))

    # classify windows after knowing day_last
    early_end = day_first + 179
    late_start = day_last - 179

    def window_stats(series, pred):
        vals = [v for d, v in series if pred(d)]
        if not vals:
            return None
        return {
            "n": len(vals),
            "mean": sum(vals) / len(vals),
            "min": min(vals),
            "max": max(vals),
            "first": vals[0],
            "last": vals[-1],
        }

    def pick(row, keys):
        return {k: row.get(k) for k in keys}

    keys_interest = [
        "day_index",
        "cohort_count",
        "building_group_count",
        "filled_owner_jobs",
        "filled_employee_jobs",
        "unemployed_population",
        "births",
        "deaths",
        "production_output_discarded",
        "production_output_retained",
        "producer_revenue",
        "bullion_money_issued",
        "building_wages_paid",
        "building_wages_unpaid",
        "loss_suspended_building_groups",
        "desired_business_demand",
        "funded_business_demand",
        "unfunded_business_demand",
        "trade_orders_dispatched",
        "trade_orders_arrived",
        "trade_capacity_used",
        "trade_candidates_generated",
        "trade_candidates_accepted",
        "merchant_cash",
        "merchant_liquidity_coverage_q16",
        "merchant_credit_outstanding",
        "merchant_credit_bad_debt",
        "recovery_liquidated_buildings",
        "building_investments_started",
        "population_error",
        "money_error",
        "goods_error",
        "trade_response_deadline_misses_cumulative",
        "trade_unresolved_no_attempt",
        "climate_limited_building_groups",
        "average_climate_capacity_q16",
        "maintenance_unmet",
        "production_input_reserve_shortfall",
    ]

    # death onset / concentration
    death_by_yearish = defaultdict(int)
    for day, d in death_days:
        bucket = (day // 365) * 365
        death_by_yearish[bucket] += d
    birth_by_yearish = defaultdict(int)
    for day, b in birth_days:
        bucket = (day // 365) * 365
        birth_by_yearish[bucket] += b

    return {
        "rows": rows,
        "day_first": day_first,
        "day_last": day_last,
        "horizon_days": day_last - day_first + 1,
        "audits": audits,
        "births_total": births,
        "deaths_total": deaths,
        "net_pop_flow": births - deaths,
        "first_death_day": death_days[0][0] if death_days else None,
        "last_death_day": death_days[-1][0] if death_days else None,
        "death_event_days": len(death_days),
        "max_deaths_one_day": max((d for _, d in death_days), default=0),
        "first_birth_day": birth_days[0][0] if birth_days else None,
        "invest_started_total": invest_started,
        "trade_orders_dispatched_total": trade_disp,
        "trade_orders_arrived_total": trade_arr,
        "trade_capacity_used_max": trade_cap_used_max,
        "deadline_miss_cumulative_max": deadline_miss_max,
        "unresolved_no_attempt_max": unresolved_no_attempt_max,
        "desired_demand_sum": desired_sum,
        "funded_demand_sum": funded_sum,
        "unfunded_demand_sum": unfunded_sum,
        "discard_sum": discard_sum,
        "retained_sum": retained_sum,
        "discard_rate": (discard_sum / (discard_sum + retained_sum)) if (discard_sum + retained_sum) else None,
        "bullion_issued_sum": bullion_sum,
        "wages_paid_sum": wages_paid_sum,
        "wage_unpaid_days": len(wage_unpaid_days),
        "suspend_positive_days": len(suspend_days),
        "first_suspend_day": suspend_days[0][0] if suspend_days else None,
        "max_suspend_groups": max((v for _, v in suspend_days), default=0),
        "merchant_cash": {
            "early": window_stats(merchant_cash_series, lambda d: d <= early_end),
            "late": window_stats(merchant_cash_series, lambda d: d >= late_start),
            "first": merchant_cash_series[0][1] if merchant_cash_series else None,
            "last": merchant_cash_series[-1][1] if merchant_cash_series else None,
        },
        "owner_jobs": {
            "early": window_stats(owner_jobs_series, lambda d: d <= early_end),
            "late": window_stats(owner_jobs_series, lambda d: d >= late_start),
            "first": owner_jobs_series[0][1],
            "last": owner_jobs_series[-1][1],
        },
        "unemployed": {
            "early": window_stats(unemployed_series, lambda d: d <= early_end),
            "late": window_stats(unemployed_series, lambda d: d >= late_start),
            "max": max(v for _, v in unemployed_series),
        },
        "loss_suspend": {
            "early": window_stats(loss_suspend_series, lambda d: d <= early_end),
            "late": window_stats(loss_suspend_series, lambda d: d >= late_start),
            "max": max(v for _, v in loss_suspend_series),
        },
        "climate_limited": {
            "early": window_stats(climate_lim_series, lambda d: d <= early_end),
            "late": window_stats(climate_lim_series, lambda d: d >= late_start),
            "max": max(v for _, v in climate_lim_series),
        },
        "deaths_by_approx_year": dict(sorted(death_by_yearish.items())),
        "births_by_approx_year": dict(sorted(birth_by_yearish.items())),
        "first_snapshot": pick(first, keys_interest),
        "last_snapshot": pick(last, keys_interest),
    }


def analyze_cohorts():
    path = Path(str(PREFIX) + "_cohorts.csv")
    by_sig = {}
    pop_by_day = defaultdict(int)
    deaths_local = defaultdict(int)  # no death field usually
    sat_min = {}
    cov_min = {}
    first_day = last_day = None
    with path.open(newline="", encoding="utf-8") as fh:
        r = csv.DictReader(fh)
        cols = r.fieldnames
        for row in r:
            day = inum(row["day_index"])
            if first_day is None:
                first_day = day
            last_day = day
            sig = row.get("signature_id")
            pop = inum(row.get("population"))
            pop_by_day[day] += pop
            if sig not in by_sig:
                by_sig[sig] = {
                    "profession_id": row.get("profession_id"),
                    "is_merchant": row.get("is_merchant"),
                    "first_day": day,
                    "first_pop": pop,
                    "first_funds": inum(row.get("funds")),
                    "first_sat": fnum(row.get("satisfaction_q16")),
                    "first_cov": fnum(row.get("livelihood_coverage_q16")),
                    "first_needs_sat": fnum(row.get("needs_satisfaction_q16") or row.get("subsistence_satisfaction_q16") or 0),
                }
            e = by_sig[sig]
            e["last_day"] = day
            e["last_pop"] = pop
            e["last_funds"] = inum(row.get("funds"))
            e["last_sat"] = fnum(row.get("satisfaction_q16"))
            e["last_cov"] = fnum(row.get("livelihood_coverage_q16"))
            e["last_needs_sat"] = fnum(row.get("needs_satisfaction_q16") or row.get("subsistence_satisfaction_q16") or 0)
            e["last_worst_need"] = row.get("worst_need_id")
            e["last_worst_dim"] = row.get("worst_dimension_id")
            e["last_unemployed"] = inum(row.get("unemployed") or row.get("unemployed_population") or 0)
            e["min_sat"] = min(e.get("min_sat", 1e18), fnum(row.get("satisfaction_q16"), 1e18))
            e["min_cov"] = min(e.get("min_cov", 1e18), fnum(row.get("livelihood_coverage_q16"), 1e18))
            e["min_needs"] = min(
                e.get("min_needs", 1e18),
                fnum(row.get("needs_satisfaction_q16") or row.get("subsistence_satisfaction_q16") or 1e18, 1e18),
            )

    days_sorted = sorted(pop_by_day)
    early = days_sorted[:180]
    late = days_sorted[-180:]
    return {
        "columns": cols,
        "day_first": first_day,
        "day_last": last_day,
        "pop_first": pop_by_day[days_sorted[0]],
        "pop_last": pop_by_day[days_sorted[-1]],
        "pop_early_mean": sum(pop_by_day[d] for d in early) / len(early),
        "pop_late_mean": sum(pop_by_day[d] for d in late) / len(late),
        "pop_min": min(pop_by_day.values()),
        "pop_max": max(pop_by_day.values()),
        "cohorts": by_sig,
    }


def analyze_market():
    path = Path(str(PREFIX) + "_market.csv")
    # track per good: stockout days late, shortage, price, household available
    goods = {}
    day_first = day_last = None
    merchant_cash_by_day = {}  # dedupe
    with path.open(newline="", encoding="utf-8") as fh:
        r = csv.DictReader(fh)
        cols = r.fieldnames
        for row in r:
            day = inum(row["day_index"])
            if day_first is None:
                day_first = day
            day_last = day
            gid = row.get("good_id") or row.get("good_stable_id") or row.get("stable_id")
            # sometimes numeric id + stable
            if not gid or gid.isdigit():
                gid = row.get("good_stable_id") or row.get("stable_good_id") or row.get("good_id")
            g = goods.setdefault(
                gid,
                {
                    "first_day": day,
                    "first_stock": inum(row.get("stock")),
                    "first_hh": inum(row.get("household_available_stock")),
                    "first_price": inum(row.get("price")),
                    "first_shortage": fnum(row.get("shortage_q16")),
                    "stockout_days": 0,
                    "severe_shortage_days": 0,
                    "max_shortage": 0.0,
                    "sum_stock": 0,
                    "sum_hh": 0,
                    "n": 0,
                    "late_stockout": 0,
                    "late_severe": 0,
                    "late_n": 0,
                },
            )
            stock = inum(row.get("stock"))
            hh = inum(row.get("household_available_stock"))
            sh = fnum(row.get("shortage_q16"))
            g["last_day"] = day
            g["last_stock"] = stock
            g["last_hh"] = hh
            g["last_price"] = inum(row.get("price"))
            g["last_shortage"] = sh
            g["last_demand_ema"] = fnum(row.get("demand_ema") or row.get("household_demand_ema") or 0)
            g["last_supply_ema"] = fnum(row.get("offered_supply_ema") or row.get("supply_ema") or 0)
            g["n"] += 1
            g["sum_stock"] += stock
            g["sum_hh"] += hh
            g["max_shortage"] = max(g["max_shortage"], sh)
            if stock <= 0:
                g["stockout_days"] += 1
            if sh >= Q16 * 0.5:
                g["severe_shortage_days"] += 1
            # late window filled later

            cell = row.get("cell_idx")
            key = (day, cell)
            if key not in merchant_cash_by_day:
                merchant_cash_by_day[key] = inum(row.get("merchant_cash") or 0)

    # second pass too expensive; approximate late using last_day known
    late_start = day_last - 179
    # re-scan only for late? Too slow for 2.7M. Use last values + stockout counts already.
    # Instead stream once more only collecting late for top goods? Skip - use last + totals.

    # rank worst goods
    ranked = []
    for gid, g in goods.items():
        if g["n"] == 0:
            continue
        ranked.append(
            {
                "good": gid,
                "stockout_share": g["stockout_days"] / g["n"],
                "severe_share": g["severe_shortage_days"] / g["n"],
                "last_stock": g["last_stock"],
                "last_hh": g["last_hh"],
                "last_shortage": g["last_shortage"],
                "last_price": g["last_price"],
                "first_stock": g["first_stock"],
                "mean_stock": g["sum_stock"] / g["n"],
                "max_shortage": g["max_shortage"],
            }
        )
    ranked.sort(key=lambda x: (x["last_shortage"], x["stockout_share"], -x["last_stock"]), reverse=True)
    survivalish = [x for x in ranked if x["good"] in {
        "prepared_staples", "staples", "raw_staples", "clothing", "fuel", "water",
        "meat", "fish", "wild_game", "firewood", "hides", "leather"
    } or any(k in str(x["good"]) for k in ("staple", "cloth", "food", "fuel", "meat", "fish"))]

    return {
        "columns_sample": cols[:60] if cols else None,
        "day_first": day_first,
        "day_last": day_last,
        "n_goods": len(goods),
        "worst_by_late_shortage": ranked[:15],
        "survival_relevant": survivalish[:20],
        "merchant_cash_first_last": {
            "n_days_cells": len(merchant_cash_by_day),
        },
    }


def analyze_buildings():
    path = Path(str(PREFIX) + "_buildings.csv")
    types = {}
    row_classes = defaultdict(int)
    suspend_onset = {}
    day_first = day_last = None
    with path.open(newline="", encoding="utf-8") as fh:
        r = csv.DictReader(fh)
        cols = r.fieldnames
        for row in r:
            day = inum(row["day_index"])
            if day_first is None:
                day_first = day
            day_last = day
            is_c = row.get("is_construction") in ("1", "true", "True")
            inv = row.get("investment_candidate") in ("1", "true", "True")
            gidx = inum(row.get("group_index"), -999)
            if is_c:
                cls = "construction"
            elif inv or gidx < 0:
                cls = "candidate"
            else:
                cls = "actual"
            row_classes[cls] += 1
            if cls != "actual":
                continue
            tid = row.get("type_id")
            stable = row.get("type_stable_id") or row.get("building_stable_id") or tid
            t = types.setdefault(
                stable,
                {
                    "type_id": tid,
                    "first_day": day,
                    "n": 0,
                    "suspend_days": 0,
                    "zero_util_days": 0,
                    "sum_margin": 0.0,
                    "sum_util": 0.0,
                    "sum_output": 0.0,
                    "sum_discard": 0.0,
                    "wage_suspend_days": 0,
                },
            )
            t["n"] += 1
            t["last_day"] = day
            op = row.get("operating_state") or row.get("lifecycle_state") or ""
            t["last_op"] = op
            util = fnum(row.get("funded_utilization_q16") or row.get("planned_utilization_q16") or 0)
            margin = fnum(row.get("margin_q16") or 0)
            outp = inum(row.get("output_produced") or row.get("output_stock") or 0)
            disc = inum(row.get("output_discarded") or 0)
            t["sum_util"] += util
            t["sum_margin"] += margin
            t["sum_output"] += outp
            t["sum_discard"] += disc
            t["last_util"] = util
            t["last_margin"] = margin
            t["last_owners_filled"] = inum(row.get("filled_owners") or row.get("owners_filled") or 0)
            t["last_employees_filled"] = inum(row.get("filled_employees") or row.get("employees_filled") or 0)
            suspended = ("suspend" in op.lower()) if isinstance(op, str) else False
            if not suspended:
                # some recorders use loss_suspended flag
                suspended = row.get("loss_suspended") in ("1", "true", "True") or inum(row.get("loss_suspended") or 0) == 1
            if suspended:
                t["suspend_days"] += 1
                if stable not in suspend_onset:
                    suspend_onset[stable] = day
            if util <= 0:
                t["zero_util_days"] += 1
            if row.get("wage_suspended") in ("1", "true", "True") or inum(row.get("wage_suspended") or 0) == 1:
                t["wage_suspend_days"] += 1

    ranked = []
    for stable, t in types.items():
        n = max(t["n"], 1)
        ranked.append(
            {
                "type": stable,
                "type_id": t["type_id"],
                "rows": t["n"],
                "suspend_share": t["suspend_days"] / n,
                "zero_util_share": t["zero_util_days"] / n,
                "mean_util_q16": t["sum_util"] / n,
                "mean_margin_q16": t["sum_margin"] / n,
                "last_op": t.get("last_op"),
                "last_util": t.get("last_util"),
                "last_margin": t.get("last_margin"),
                "last_owners": t.get("last_owners_filled"),
                "last_employees": t.get("last_employees_filled"),
                "suspend_onset": suspend_onset.get(stable),
                "output_sum": t["sum_output"],
                "discard_sum": t["sum_discard"],
            }
        )
    ranked.sort(key=lambda x: (x["suspend_share"], x["zero_util_share"]), reverse=True)
    return {
        "columns_sample": cols[:80] if cols else None,
        "row_classes": dict(row_classes),
        "n_types": len(types),
        "types": ranked,
    }


def analyze_resources():
    path = Path(str(PREFIX) + "_resources.csv")
    res = {}
    with path.open(newline="", encoding="utf-8") as fh:
        r = csv.DictReader(fh)
        cols = r.fieldnames
        for row in r:
            day = inum(row["day_index"])
            rid = row.get("resource_stable_id") or row.get("resource_id") or row.get("stable_id")
            e = res.setdefault(
                rid,
                {
                    "first_day": day,
                    "first_reserve": fnum(row.get("reserve")),
                    "min_reserve": 1e300,
                    "sum_nat_pos": 0.0,
                    "sum_nat_neg": 0.0,
                    "sum_art_gen": 0.0,
                    "sum_art_ext": 0.0,
                    "sum_art_ext_pending": 0.0,
                    "n": 0,
                },
            )
            reserve = fnum(row.get("reserve"))
            e["n"] += 1
            e["last_day"] = day
            e["last_reserve"] = reserve
            e["min_reserve"] = min(e["min_reserve"], reserve)
            e["last_life"] = fnum(row.get("projected_life") or row.get("projected_life_days") or 0)
            e["min_life"] = min(e.get("min_life", 1e300), fnum(row.get("projected_life") or row.get("projected_life_days") or 1e300))
            e["last_safe_yield"] = fnum(row.get("safe_yield") or 0)
            e["sum_nat_pos"] += fnum(row.get("natural_positive_change"))
            e["sum_nat_neg"] += fnum(row.get("natural_negative_change"))
            e["sum_art_gen"] += fnum(row.get("artificial_generation_applied") or row.get("artificial_generation"))
            e["sum_art_ext"] += fnum(row.get("artificial_extraction_applied") or row.get("artificial_extraction"))
            e["sum_art_ext_pending"] += fnum(row.get("artificial_extraction_pending") or 0)

    ranked = []
    for rid, e in res.items():
        first = e["first_reserve"]
        last = e["last_reserve"]
        deplete = None
        if first > 1e-9:
            deplete = (first - last) / first
        ranked.append(
            {
                "resource": rid,
                "first": first,
                "last": last,
                "min": e["min_reserve"],
                "deplete_share": deplete,
                "nat_pos": e["sum_nat_pos"],
                "nat_neg": e["sum_nat_neg"],
                "art_gen": e["sum_art_gen"],
                "art_ext": e["sum_art_ext"],
                "last_life": e.get("last_life"),
                "min_life": e.get("min_life") if e.get("min_life", 1e300) < 1e299 else None,
            }
        )
    ranked.sort(key=lambda x: (x["deplete_share"] is not None, x["deplete_share"] or -1), reverse=True)
    return {"columns_sample": cols, "n": len(res), "resources": ranked}


def main():
    out = {
        "summary": analyze_summary(),
        "cohorts": analyze_cohorts(),
    }
    Path("tmp/_diag_partial.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print("partial written; starting heavy tables...")
    out["market"] = analyze_market()
    Path("tmp/_diag_partial.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print("market done")
    out["buildings"] = analyze_buildings()
    Path("tmp/_diag_partial.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print("buildings done")
    out["resources"] = analyze_resources()
    Path("tmp/_diag_health.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print("DONE -> tmp/_diag_health.json")
    # compact stdout
    s = out["summary"]
    print(json.dumps({
        "horizon": [s["day_first"], s["day_last"], s["horizon_days"]],
        "audits_nonzero_counts": {k: s["audits"][k] for k in ("population_error", "money_error", "goods_error")},
        "births_deaths": [s["births_total"], s["deaths_total"], s["net_pop_flow"]],
        "trade_totals": [s["trade_orders_dispatched_total"], s["trade_orders_arrived_total"]],
        "invest_started": s["invest_started_total"],
        "discard_rate": s["discard_rate"],
        "cell_pop": [out["cohorts"]["pop_first"], out["cohorts"]["pop_last"]],
        "market_worst": out["market"]["worst_by_late_shortage"][:8],
        "building_suspend_top": out["buildings"]["types"][:8],
        "resource_deplete_top": out["resources"]["resources"][:10],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
