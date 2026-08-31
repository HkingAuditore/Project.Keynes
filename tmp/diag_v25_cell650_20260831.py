#!/usr/bin/env python3
"""Read-only full diagnosis for recorder family 20260831_140522_v25_cell650.

Does not modify runtime. Writes JSON + compact text to tmp/.
"""
from __future__ import annotations

import csv
import json
import math
import re
import statistics as st
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFIX = ROOT / "tmp" / "economy_record_20260831_140522_v25_cell650_q45_r10"
Q16 = 65536.0
MONEY = 10000.0
GOODS = 1000.0
SAMPLE_N = 16


def n(v, default=0.0):
    if v in (None, ""):
        return default
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def i(v, default=0):
    return int(n(v, default))


def catalog_index(directory: Path) -> dict[int, str]:
    items = []
    id_re = re.compile(r'^id\s*=\s*&?"([^"]+)"', re.MULTILINE)
    if not directory.is_dir():
        return {}
    for path in directory.glob("*.tres"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        m = id_re.search(text)
        if m:
            items.append(m.group(1))
    items.sort()
    return dict(enumerate(items))


def load(kind: str):
    path = Path(f"{PREFIX}_{kind}.csv")
    with path.open(encoding="utf-8-sig", newline="") as f:
        r = csv.DictReader(f)
        rows = list(r)
        return list(r.fieldnames or []), rows


def pick_idx(days, k=SAMPLE_N):
    if not days:
        return []
    if len(days) <= k:
        return list(days)
    return [days[round(i * (len(days) - 1) / (k - 1))] for i in range(k)]


def extrema(xs):
    if not xs:
        return None
    return {"min": min(xs), "max": max(xs), "first": xs[0], "last": xs[-1],
            "mean": st.mean(xs), "p50": st.median(xs)}


def window(xs, a, b):
    sl = xs[a:b]
    return None if not sl else st.mean(sl)


def pearson(a, b):
    if len(a) < 30 or len(a) != len(b):
        return None
    ma, mb = st.mean(a), st.mean(b)
    va = sum((x - ma) ** 2 for x in a)
    vb = sum((y - mb) ** 2 for y in b)
    if va <= 0 or vb <= 0:
        return None
    return sum((x - ma) * (y - mb) for x, y in zip(a, b)) / math.sqrt(va * vb)


def d1(xs):
    return [xs[i] - xs[i - 1] for i in range(1, len(xs))]


def main():
    data_root = ROOT / "Project" / "project-keynes" / "data" / "economy"
    prof_map = catalog_index(data_root / "professions")
    need_map = catalog_index(data_root / "needs")
    bld_map = catalog_index(data_root / "buildings")

    sh, summary = load("summary")
    ch, cohorts = load("cohorts")
    mh, market = load("market")
    bh, buildings = load("buildings")
    rh, resources = load("resources")

    days = [i(r["day_index"]) for r in summary]
    assert days == sorted(days)
    d0, d1_last = days[0], days[-1]
    horizon = d1_last - d0 + 1
    early_n = min(90, len(days))
    late_n = min(90, len(days))
    mid_cut = len(days) // 2
    sample_days = pick_idx(days)
    sample_set = set(sample_days)

    # ---- integrity
    def pk_dups(rows, keys):
        seen = set()
        dups = 0
        for r in rows:
            k = tuple(r.get(x, "") for x in keys)
            if k in seen:
                dups += 1
            else:
                seen.add(k)
        return dups

    sum_epochs = {r["epoch_row_id"] for r in summary}
    integrity = {
        "rows": {
            "summary": len(summary), "cohorts": len(cohorts),
            "market": len(market), "buildings": len(buildings),
            "resources": len(resources),
        },
        "headers": {
            "summary": len(sh), "cohorts": len(ch), "market": len(mh),
            "buildings": len(bh), "resources": len(rh),
        },
        "day_first": d0, "day_last": d1_last, "unique_days": len(set(days)),
        "horizon_days": horizon, "day_gaps": [],
        "summary_pk_dups": pk_dups(summary, ["epoch_row_id"]),
        "cohorts_pk_dups": pk_dups(cohorts, ["epoch_row_id", "cell_idx", "cohort_index"]),
        "market_pk_dups": pk_dups(market, ["epoch_row_id", "cell_idx", "good_id"]),
        "resources_pk_dups": pk_dups(resources, ["epoch_row_id", "cell_idx", "resource_id"]),
        "detail_cells": sorted({i(r["cell_idx"]) for r in cohorts}),
        "qr": {
            "q": i(cohorts[0]["q"]) if cohorts else None,
            "r": i(cohorts[0]["r"]) if cohorts else None,
        },
        "detail_epochs_not_in_summary": {
            "cohorts": len({r["epoch_row_id"] for r in cohorts} - sum_epochs),
            "market": len({r["epoch_row_id"] for r in market} - sum_epochs),
            "buildings": len({r["epoch_row_id"] for r in buildings} - sum_epochs),
            "resources": len({r["epoch_row_id"] for r in resources} - sum_epochs),
        },
        "blank_good_id": sum(1 for r in market if not r.get("good_id")),
        "blank_resource_id": sum(1 for r in resources if not r.get("resource_id")),
        "scope": "summary=GLOBAL; cohorts/market/buildings/resources=cell650 only",
    }
    day_set = set(days)
    expected = set(range(d0, d1_last + 1))
    integrity["day_gaps"] = sorted(expected - day_set)

    # ---- conservation
    def audit(name):
        xs = [n(r[name]) for r in summary]
        nz = [(days[i], xs[i]) for i, v in enumerate(xs) if v != 0]
        return {
            "max_abs": max(abs(x) for x in xs) if xs else 0,
            "nonzero_days": len(nz),
            "first_nonzero": nz[0] if nz else None,
            "last_nonzero": nz[-1] if nz else None,
        }

    conservation = {
        "population_error": audit("population_error"),
        "money_error": audit("money_error"),
        "goods_error": audit("goods_error"),
    }

    def series(field):
        return [n(r[field]) for r in summary]

    g_series = {
        "cohort_count": series("cohort_count"),
        "building_group_count": series("building_group_count"),
        "pending_construction_count": series("pending_construction_count"),
        "filled_owner_jobs": series("filled_owner_jobs"),
        "filled_employee_jobs": series("filled_employee_jobs"),
        "unemployed_population": series("unemployed_population"),
        "births": series("births"),
        "deaths": series("deaths"),
        "production_inputs_consumed": series("production_inputs_consumed"),
        "production_output_stock": series("production_output_stock"),
        "production_output_discarded": series("production_output_discarded"),
        "production_output_retained": series("production_output_retained"),
        "production_output_supported": series("production_output_supported"),
        "producer_revenue": series("producer_revenue"),
        "bullion_money_issued": series("bullion_money_issued"),
        "building_wages_paid": series("building_wages_paid"),
        "building_wages_unpaid": series("building_wages_unpaid"),
        "building_resource_consumed": series("building_resource_consumed"),
        "building_resource_generated": series("building_resource_generated"),
        "loss_suspended_building_groups": series("loss_suspended_building_groups"),
        "merchant_procurement_spent": series("merchant_procurement_spent"),
        "merchant_procurement_budget": series("merchant_procurement_budget"),
        "production_input_reserve_shortfall": series("production_input_reserve_shortfall"),
        "desired_business_demand": series("desired_business_demand"),
        "funded_business_demand": series("funded_business_demand"),
        "unfunded_business_demand": series("unfunded_business_demand"),
        "trade_orders_dispatched": series("trade_orders_dispatched"),
        "trade_orders_arrived": series("trade_orders_arrived"),
        "trade_orders_in_flight": series("trade_orders_in_flight"),
        "trade_candidates_generated": series("trade_candidates_generated"),
        "trade_candidates_accepted": series("trade_candidates_accepted"),
        "building_investments_started": series("building_investments_started"),
        "building_investment_candidates": series("building_investment_candidates"),
        "building_investment_blocked_funds": series("building_investment_blocked_funds"),
        "building_investment_blocked_materials": series("building_investment_blocked_materials"),
        "building_investment_blocked_resources": series("building_investment_blocked_resources"),
        "building_investment_demand_limited": series("building_investment_demand_limited"),
        "building_investment_material_limited": series("building_investment_material_limited"),
        "building_investment_capital_limited": series("building_investment_capital_limited"),
        "building_investment_owner_population_limited": series("building_investment_owner_population_limited"),
        "merchant_cash": series("merchant_cash"),
        "merchant_economic_assets": series("merchant_economic_assets"),
        "merchant_liquidity_coverage_q16": series("merchant_liquidity_coverage_q16"),
        "climate_limited_building_groups": series("climate_limited_building_groups"),
        "average_climate_capacity_q16": series("average_climate_capacity_q16"),
        "maintenance_unmet": series("maintenance_unmet"),
    }

    def pack_ts(xs):
        return {
            "first": xs[0], "last": xs[-1],
            "early90_mean": window(xs, 0, early_n),
            "late90_mean": window(xs, -late_n, None if late_n else None) if False else st.mean(xs[-late_n:]),
            "sum": sum(xs),
            "min": min(xs), "max": max(xs),
            "nonzero_days": sum(1 for x in xs if x != 0),
            "samples": [{"day": d, "v": xs[days.index(d)]} for d in sample_days],
        }

    global_ts = {k: pack_ts(v) for k, v in g_series.items()}

    # births/deaths onset
    death_days = [days[i] for i, v in enumerate(g_series["deaths"]) if v > 0]
    birth_days = [days[i] for i, v in enumerate(g_series["births"]) if v > 0]

    # ---- cohorts cell 650
    by_day_c = defaultdict(list)
    for r in cohorts:
        by_day_c[i(r["day_index"])].append(r)

    def wavg(rows, field, wfield="population"):
        tw = sum(n(x[wfield]) for x in rows)
        if tw <= 0:
            return 0.0
        return sum(n(x[field]) * n(x[wfield]) for x in rows) / tw

    pop_ts, funds_ts, sat_ts, cov_ts, unemp_c_ts, owner_c_ts, emp_c_ts = [], [], [], [], [], [], []
    merch_pop_ts, non_pop_ts, merch_funds_ts, non_funds_ts = [], [], [], []
    for d in days:
        rs = by_day_c[d]
        pop = sum(n(x["population"]) for x in rs)
        pop_ts.append(pop)
        funds_ts.append(sum(n(x["funds"]) for x in rs))
        sat_ts.append(wavg(rs, "satisfaction_q16") / Q16)
        cov_ts.append(wavg(rs, "livelihood_coverage_q16") / Q16)
        unemp_c_ts.append(sum(n(x["unemployed"]) for x in rs))
        owner_c_ts.append(sum(n(x["owner_employed"]) for x in rs))
        emp_c_ts.append(sum(n(x["employee_employed"]) for x in rs))
        mp = sum(n(x["population"]) for x in rs if i(x["is_merchant"]))
        np_ = pop - mp
        merch_pop_ts.append(mp)
        non_pop_ts.append(np_)
        merch_funds_ts.append(sum(n(x["funds"]) for x in rs if i(x["is_merchant"])))
        non_funds_ts.append(sum(n(x["funds"]) for x in rs if not i(x["is_merchant"])))

    sat_base = st.mean(sat_ts[:30])
    sat_onset = next((days[i] for i, v in enumerate(sat_ts) if v < sat_base - 0.05), None)
    cov_lt1_days = [days[i] for i, v in enumerate(cov_ts) if v < 1.0]
    sat_lt05_days = [days[i] for i, v in enumerate(sat_ts) if v < 0.5]

    # per signature first/last
    sigs = {}
    for r in cohorts:
        sid = i(r["signature_id"])
        sigs.setdefault(sid, []).append(r)

    cohort_entities = []
    for sid, rs in sorted(sigs.items()):
        rs = sorted(rs, key=lambda x: i(x["day_index"]))
        first, last = rs[0], rs[-1]
        pops = [n(x["population"]) for x in rs]
        sats = [n(x["satisfaction_q16"]) / Q16 for x in rs]
        covs = [n(x["livelihood_coverage_q16"]) / Q16 for x in rs]
        funds = [n(x["funds"]) for x in rs]
        income = [n(x["epoch_income"]) for x in rs]
        expense = [n(x["epoch_expense"]) for x in rs]
        unemp = [n(x["unemployed"]) for x in rs]
        worst_need = i(last["worst_need_id"])
        cohort_entities.append({
            "signature_id": sid,
            "profession": prof_map.get(i(last["profession_id"]), str(i(last["profession_id"]))),
            "is_merchant": bool(i(last["is_merchant"])),
            "pop_first": pops[0], "pop_last": pops[-1], "pop_min": min(pops), "pop_max": max(pops),
            "funds_first": funds[0], "funds_last": funds[-1],
            "fpc_first": funds[0] / max(pops[0], 1), "fpc_last": funds[-1] / max(pops[-1], 1),
            "income_early90": st.mean(income[:early_n]),
            "income_late90": st.mean(income[-late_n:]),
            "expense_early90": st.mean(expense[:early_n]),
            "expense_late90": st.mean(expense[-late_n:]),
            "sat_first": sats[0], "sat_last": sats[-1], "sat_min": min(sats),
            "cov_first": covs[0], "cov_last": covs[-1], "cov_min": min(covs),
            "unemp_max": max(unemp), "unemp_last": unemp[-1],
            "owner_last": n(last["owner_employed"]),
            "employee_last": n(last["employee_employed"]),
            "worst_need": need_map.get(worst_need, str(worst_need)),
            "days_sat0": sum(1 for x in sats if x <= 0),
            "days_cov_lt1": sum(1 for x in covs if x < 1.0),
        })

    # ---- market cell 650
    by_good = defaultdict(list)
    for r in market:
        by_good[r["good_id"]].append(r)
    for g, rs in by_good.items():
        rs.sort(key=lambda x: i(x["day_index"]))

    # merchant fields: one per day
    merch_day = {}
    for r in market:
        d = i(r["day_index"])
        if d not in merch_day:
            merch_day[d] = r

    merch_cash_cell = [n(merch_day[d]["merchant_cash"]) for d in days]
    merch_liq = [n(merch_day[d]["merchant_liquidity_coverage_q16"]) / Q16 for d in days]

    foodish = [
        "rice_grain", "prepared_staples", "gathered_plants", "game_meat", "fish",
        "wheat_grain", "millet_grain", "maize_grain", "barley_grain", "sorghum_grain",
        "bread", "porridge", "dried_fish", "dried_meat", "staple_food",
    ]
    fuelish = ["charcoal", "firewood", "fuel"]
    key_goods = []
    seen_g = set()
    for gid in foodish + fuelish + [
        "clothing", "chipped_stone_tools", "lumber", "bast_fiber", "reed_bundle",
        "turf_block", "pottery", "salt", "hides", "wool",
    ]:
        if gid in by_good and gid not in seen_g:
            key_goods.append(gid)
            seen_g.add(gid)

    def good_diag(gid):
        rs = by_good[gid]
        stock = [n(x["stock"]) for x in rs]
        hav = [n(x["household_available_stock"]) for x in rs]
        demand = [n(x["demand_ema"]) for x in rs]
        biz = [n(x["business_demand_ema"]) for x in rs]
        supply = [n(x["offered_supply_ema"]) for x in rs]
        wd = [n(x["realized_withdrawal_ema"]) for x in rs]
        shq = [n(x["shortage_q16"]) / Q16 for x in rs]
        price = [n(x["price"]) for x in rs]
        reserve = [n(x["production_input_reserve"]) for x in rs]
        unfunded = [n(x["unfunded_business_demand"]) for x in rs]
        imp = [n(x["trade_import_ema"]) for x in rs]
        exp = [n(x["trade_export_ema"]) for x in rs]
        inbound = [n(x["trade_inbound"]) for x in rs]
        outbound = [n(x["trade_outbound"]) for x in rs]
        age = [n(x["trade_signal_age_days"]) for x in rs]
        rej = [x["trade_last_rejection_reason"] for x in rs]
        stockout = sum(1 for x in stock if x <= 0)
        severe = sum(1 for x in shq if x >= 0.9)
        first_stockout = next((i(x["day_index"]) for x in rs if n(x["stock"]) <= 0), None)
        first_severe = next((i(x["day_index"]) for x in rs if n(x["shortage_q16"]) / Q16 >= 0.9), None)
        rej_counts = defaultdict(int)
        for x in rej:
            if x not in ("", "0", "none"):
                rej_counts[str(x)] += 1
        return {
            "good_id": gid,
            "stock_first": stock[0], "stock_last": stock[-1],
            "stock_min": min(stock), "stock_max": max(stock),
            "hav_first": hav[0], "hav_last": hav[-1], "hav_mean": st.mean(hav),
            "demand_early": st.mean(demand[:early_n]), "demand_late": st.mean(demand[-late_n:]),
            "supply_early": st.mean(supply[:early_n]), "supply_late": st.mean(supply[-late_n:]),
            "withdraw_early": st.mean(wd[:early_n]), "withdraw_late": st.mean(wd[-late_n:]),
            "biz_late": st.mean(biz[-late_n:]),
            "shortage_early": st.mean(shq[:early_n]), "shortage_late": st.mean(shq[-late_n:]),
            "shortage_last": shq[-1], "stockout_days": stockout, "severe_days": severe,
            "first_stockout": first_stockout, "first_severe": first_severe,
            "price_first": price[0], "price_last": price[-1],
            "price_min": min(price), "price_max": max(price),
            "reserve_last": reserve[-1], "unfunded_late": st.mean(unfunded[-late_n:]),
            "import_late": st.mean(imp[-late_n:]), "export_late": st.mean(exp[-late_n:]),
            "inbound_sum": sum(inbound), "outbound_sum": sum(outbound),
            "signal_age_max": max(age),
            "rejection": dict(sorted(rej_counts.items(), key=lambda kv: -kv[1])[:5]),
            "samples": [{"day": d, "stock": stock[days.index(d)] if d in days else None,
                          "shortage": shq[days.index(d)] if d in days else None,
                          "demand": demand[days.index(d)] if d in days else None,
                          "supply": supply[days.index(d)] if d in days else None,
                          "price": price[days.index(d)] if d in days else None}
                         for d in sample_days],
        }

    market_goods = [good_diag(g) for g in key_goods]
    # also top late shortage among all goods with demand or stock activity
    all_late_shortage = []
    for gid, rs in by_good.items():
        late = rs[-late_n:]
        sh_m = st.mean(n(x["shortage_q16"]) / Q16 for x in late)
        dem = st.mean(n(x["demand_ema"]) for x in late)
        stk = st.mean(n(x["stock"]) for x in late)
        if sh_m >= 0.2 and (dem > 0 or st.mean(n(x["stock"]) for x in rs[:early_n]) > 0):
            all_late_shortage.append((sh_m, gid, stk, dem, st.mean(n(x["offered_supply_ema"]) for x in late)))
    all_late_shortage.sort(reverse=True)

    # goods with demand but zero supply
    demand_no_supply = []
    for gid, rs in by_good.items():
        late = rs[-late_n:]
        dem = st.mean(n(x["demand_ema"]) for x in late)
        sup = st.mean(n(x["offered_supply_ema"]) for x in late)
        if dem > 1 and sup <= 0.01:
            demand_no_supply.append({
                "good_id": gid, "demand_late": dem, "supply_late": sup,
                "stock_late": st.mean(n(x["stock"]) for x in late),
                "shortage_late": st.mean(n(x["shortage_q16"]) / Q16 for x in late),
            })
    demand_no_supply.sort(key=lambda x: -x["demand_late"])

    # ---- buildings
    actual = [r for r in buildings if i(r["group_index"]) >= 0 and i(r["is_construction"]) == 0]
    cand = [r for r in buildings if i(r["investment_candidate"])]
    constr = [r for r in buildings if i(r["is_construction"])]
    by_type_day = defaultdict(lambda: defaultdict(list))
    for r in actual:
        by_type_day[i(r["type_id"])][i(r["day_index"])].append(r)

    type_diag = []
    for tid, by_d in by_type_day.items():
        last_day = days[-1]
        first_day = days[0]
        last_rs = by_d.get(last_day, [])
        first_rs = by_d.get(first_day, [])
        late_rs = [x for d in days[-late_n:] for x in by_d.get(d, [])]
        early_rs = [x for d in days[:early_n] for x in by_d.get(d, [])]

        def sums(rs, f):
            return sum(n(x[f]) for x in rs)

        out_l = sums(late_rs, "last_output")
        sold_l = sums(late_rs, "last_sold")
        disc_l = sums(late_rs, "last_discarded")
        ret_l = sums(late_rs, "last_retained")
        states = defaultdict(int)
        for x in last_rs:
            states[x["operating_state"]] += i(x["count"]) or 1
        openings = sum(n(x["owner_openings"]) for x in last_rs)
        filled = sum(n(x["filled_owner"]) for x in last_rs)
        req = sum(n(x["owner_required"]) for x in last_rs)
        cap = sum(n(x["owner_capacity"]) for x in last_rs)
        emp_req = sum(n(x["employee_required"]) for x in last_rs)
        emp_f = sum(n(x["employee_filled"]) for x in last_rs)
        util = [n(x["funded_capacity_q16"]) / Q16 for x in late_rs] if late_rs else [0]
        margin = [n(x["realized_profit_margin_q16"]) / Q16 for x in late_rs] if late_rs else [0]
        wage_sus = sum(1 for x in last_rs if i(x["wage_suspended"]))
        inv_score = max((n(x["investment_score_q16"]) for x in last_rs), default=0)
        rej = defaultdict(int)
        for x in last_rs:
            rr = x.get("investment_rejection_reason") or ""
            if rr and rr not in ("0", "none", ""):
                rej[rr] += 1
        climate = st.mean([n(x["last_climate_capacity_q16"]) / Q16 for x in last_rs]) if last_rs else 0
        type_diag.append({
            "type_id": tid,
            "building": bld_map.get(tid, str(tid)),
            "groups_first": len(first_rs), "groups_last": len(last_rs),
            "count_last": sum(i(x["count"]) for x in last_rs),
            "owner_cap_last": cap, "owner_req_last": req, "filled_owner_last": filled,
            "owner_openings_last": openings,
            "emp_req_last": emp_req, "emp_filled_last": emp_f,
            "output_late_sum": out_l, "sold_late_sum": sold_l,
            "discard_late_sum": disc_l, "retained_late_sum": ret_l,
            "discard_share_late": disc_l / out_l if out_l else None,
            "sold_share_late": sold_l / out_l if out_l else None,
            "output_early_sum": sums(early_rs, "last_output"),
            "sold_early_sum": sums(early_rs, "last_sold"),
            "util_late_mean": st.mean(util),
            "margin_late_mean": st.mean(margin),
            "states_last": dict(states),
            "wage_suspended_groups": wage_sus,
            "climate_cap_last": climate,
            "inv_score_max_last": inv_score,
            "inv_reject": dict(rej),
            "revenue_late": sums(late_rs, "last_revenue"),
            "input_cost_late": sums(late_rs, "last_input_cost"),
            "resource_late": sums(late_rs, "last_resource"),
            "resource_gen_late": sums(late_rs, "last_resource_generated"),
        })
    type_diag.sort(key=lambda x: -(x["output_late_sum"] or 0))

    late_actual = [x for x in actual if i(x["day_index"]) >= days[-late_n]]
    early_act = [x for x in actual if i(x["day_index"]) <= days[early_n - 1]]
    out_l = sum(n(x["last_output"]) for x in late_actual)
    sold_l = sum(n(x["last_sold"]) for x in late_actual)
    disc_l = sum(n(x["last_discarded"]) for x in late_actual)
    ret_l = sum(n(x["last_retained"]) for x in late_actual)
    out_e = sum(n(x["last_output"]) for x in early_act)
    disc_e = sum(n(x["last_discarded"]) for x in early_act)

    # operating state last day
    last_act = [x for x in actual if i(x["day_index"]) == days[-1]]
    state_last = defaultdict(int)
    for x in last_act:
        state_last[x["operating_state"]] += 1
    openings_last = sum(n(x["owner_openings"]) for x in last_act)
    filled_last = sum(n(x["filled_owner"]) for x in last_act)
    req_last = sum(n(x["owner_required"]) for x in last_act)
    emp_req_last = sum(n(x["employee_required"]) for x in last_act)
    emp_fill_last = sum(n(x["employee_filled"]) for x in last_act)

    inv_rej_all = defaultdict(int)
    for r in cand[-5000:]:
        rr = r.get("investment_rejection_reason") or ""
        if rr:
            inv_rej_all[rr] += 1
    # better: last day candidates
    last_cand = [r for r in buildings if i(r["day_index"]) == days[-1] and i(r["investment_candidate"])]
    last_cand_rej = defaultdict(int)
    last_cand_score = []
    for r in last_cand:
        last_cand_rej[r.get("investment_rejection_reason") or "(empty)"] += 1
        last_cand_score.append(n(r["investment_score_q16"]) / Q16)

    # employment diagnostics last day
    last_emp = [r for r in buildings if i(r["day_index"]) == days[-1] and i(r.get("employment_candidate") or 0)]
    emp_rej = defaultdict(int)
    for r in last_emp:
        emp_rej[r.get("employment_rejection_reason") or "(empty)"] += 1

    # ---- resources
    by_res = defaultdict(list)
    for r in resources:
        by_res[r["resource_id"]].append(r)
    for rs in by_res.values():
        rs.sort(key=lambda x: i(x["day_index"]))

    res_diag = []
    for rid, rs in by_res.items():
        reserve = [n(x["reserve"]) for x in rs]
        nat_neg = [n(x["natural_negative_change"]) for x in rs]
        nat_pos = [n(x["natural_positive_change"]) for x in rs]
        ext_a = [n(x["artificial_extraction_applied"]) for x in rs]
        gen_a = [n(x["artificial_generation_applied"]) for x in rs]
        ext_p = [n(x["artificial_extraction_pending"]) for x in rs]
        life = [n(x["projected_life_days"]) for x in rs]
        opening = n(rs[0]["opening_reserve"])
        final = reserve[-1]
        dep = (opening - min(reserve)) / opening if opening > 0 else None
        first_crit = next((i(x["day_index"]) for x, rv in zip(rs, reserve) if rv <= 0), None)
        res_diag.append({
            "resource_id": rid,
            "opening": opening, "final": final, "min": min(reserve), "max": max(reserve),
            "depletion_to_min": dep,
            "nat_neg_sum": sum(nat_neg), "nat_pos_sum": sum(nat_pos),
            "extract_applied_sum": sum(ext_a), "gen_applied_sum": sum(gen_a),
            "extract_pending_last": ext_p[-1],
            "safe_yield_last": n(rs[-1]["safe_yield"]),
            "proj_life_last": life[-1], "proj_life_min": min(life),
            "first_zero": first_crit,
            "extract_days": sum(1 for x in ext_a if x > 0),
        })
    res_diag.sort(key=lambda x: -(x["extract_applied_sum"] or 0))

    # binding resources: those with extraction and declining
    binding = [x for x in res_diag if x["extract_applied_sum"] > 0 or (x["opening"] > 0 and x["final"] < x["opening"] * 0.99)]

    # ---- correlations (first difference, same-cell or global-only)
    # cell food shortage vs sat
    if "rice_grain" in by_good:
        rice_sh = [n(x["shortage_q16"]) / Q16 for x in by_good["rice_grain"]]
    else:
        rice_sh = [0] * len(days)
    if "prepared_staples" in by_good:
        prep_sh = [n(x["shortage_q16"]) / Q16 for x in by_good["prepared_staples"]]
    else:
        prep_sh = [0] * len(days)
    discard_g = g_series["production_output_discarded"]
    corr = {
        "n": len(days) - 1,
        "d_sat_vs_d_rice_shortage": pearson(d1(sat_ts), d1(rice_sh)),
        "d_sat_vs_d_prep_shortage": pearson(d1(sat_ts), d1(prep_sh)),
        "level_sat_vs_rice_shortage": pearson(sat_ts, rice_sh),
        "d_cov_vs_d_rice_shortage": pearson(d1(cov_ts), d1(rice_sh)),
        "level_pop_vs_unemp_global": pearson(pop_ts, g_series["unemployed_population"]),
        "d_discard_vs_d_revenue_global": pearson(d1(discard_g), d1(g_series["producer_revenue"])),
        "note": "level correlations of trending series are weak causal evidence; prefer first differences",
    }

    # raw spot checks
    def row_at(rows, day, pred):
        for r in rows:
            if i(r["day_index"]) == day and pred(r):
                return r
        return None

    first_sum = summary[0]
    last_sum = summary[-1]
    mid_sum = summary[mid_cut]
    death_spot = None
    if death_days:
        death_spot = next(r for r in summary if i(r["day_index"]) == death_days[0])

    rice_first = by_good.get("rice_grain", [None])[0]
    rice_last = by_good.get("rice_grain", [None])[-1]
    prep_last = by_good.get("prepared_staples", [None])[-1]

    # fisher/hunter last rows
    fisher_last = None
    hunter_last = None
    artisan_last = None
    for r in by_day_c[days[-1]]:
        pid = prof_map.get(i(r["profession_id"]), str(i(r["profession_id"])))
        if pid == "fisher":
            fisher_last = r
        elif pid == "hunter":
            hunter_last = r
        elif pid == "artisan":
            artisan_last = r

    # building raw: highest discard type last day
    top_disc = max(last_act, key=lambda x: n(x["last_discarded"]), default=None)

    # ranking stagnation
    # evidence scores 0-3
    # SUPPLY: local food stockout + global discard (overproduction of non-food?) + input shortfall
    food_stockout = [g for x in all_late_shortage[:15] for g in [x[1]]
                     if x[1] in set(foodish) and x[0] >= 0.8]
    supply_score = 0
    supply_notes = []
    if any(x["stockout_days"] > 200 for x in market_goods if x["good_id"] in foodish):
        supply_score = 3
        supply_notes.append("staple goods stockout >200/553 days in cell650")
    if st.mean(g_series["production_output_discarded"]) > 0.3 * st.mean(
            [a + b for a, b in zip(g_series["production_output_stock"], g_series["production_output_discarded"])]):
        supply_notes.append("global discard high: composition mismatch not aggregate capacity=0")
    if st.mean(g_series["production_input_reserve_shortfall"]) > 0:
        supply_notes.append("persistent production_input_reserve_shortfall")
        supply_score = max(supply_score, 2)

    # CONSUMPTION: coverage, withdrawal vs demand, sat drop, expense up income mixed
    cons_score = 0
    cons_notes = []
    if sat_onset:
        cons_score = 3
        cons_notes.append(f"cell650 pop-weighted satisfaction drop onset day {sat_onset}")
    if cov_lt1_days:
        cons_notes.append(f"livelihood coverage <1.0 on {len(cov_lt1_days)} days")
        cons_score = max(cons_score, 2)
    if demand_no_supply:
        cons_notes.append(f"{len(demand_no_supply)} goods with late demand and ~0 offered supply")

    # EMPLOYMENT: global unemployed=6 constant, employee jobs 0, openings persist, 0 investments
    emp_score = 0
    emp_notes = []
    if max(g_series["filled_employee_jobs"]) == 0:
        emp_score = 2
        emp_notes.append("global filled_employee_jobs always 0")
    if min(g_series["unemployed_population"]) >= 6 and max(g_series["unemployed_population"]) <= 6:
        emp_notes.append("global unemployed frozen at 6")
        emp_score = max(emp_score, 2)
    if sum(g_series["building_investments_started"]) == 0:
        emp_notes.append("zero investments started globally across 553 days")
        emp_score = max(emp_score, 3)
    if openings_last > 0:
        emp_notes.append(f"cell650 last-day owner_openings={openings_last} vs unemployed local {unemp_c_ts[-1]}")

    # RESOURCES
    res_score = 0
    res_notes = []
    dead = [x for x in res_diag if x["first_zero"] is not None]
    extracted_ok = [x for x in res_diag if x["extract_applied_sum"] > 0 and x["final"] > 0]
    if dead:
        res_notes.append(f"resources hitting zero: {[x['resource_id'] for x in dead]}")
        # only elevate if they bind production
        res_score = 2
    landish = [x for x in res_diag if "land" in x["resource_id"] or x["resource_id"] in
               ("paddy_land", "arable_land", "plantation_land", "pasture", "fertile_soil")]
    if extracted_ok:
        res_notes.append("extracted resources remain positive; not world-ending depletion")
        if res_score < 2:
            res_score = 1
    if not any(x["extract_applied_sum"] > 100 for x in res_diag):
        res_notes.append("cell650 extraction applied sums small or zero for most slots")

    ranking = sorted([
        ("供给/生产结构(含错配与短缺)", supply_score, supply_notes),
        ("消费/生存需求满足", cons_score, cons_notes),
        ("就业/投资/岗位扩张", emp_score, emp_notes),
        ("自然资源约束", res_score, res_notes),
    ], key=lambda x: -x[1])

    # plot series
    plot_series = {
        "days_sample": sample_days,
        "global": {
            "births": [g_series["births"][days.index(d)] for d in sample_days],
            "deaths": [g_series["deaths"][days.index(d)] for d in sample_days],
            "unemployed": [g_series["unemployed_population"][days.index(d)] for d in sample_days],
            "filled_owner": [g_series["filled_owner_jobs"][days.index(d)] for d in sample_days],
            "filled_employee": [g_series["filled_employee_jobs"][days.index(d)] for d in sample_days],
            "discard": [g_series["production_output_discarded"][days.index(d)] for d in sample_days],
            "output_stock": [g_series["production_output_stock"][days.index(d)] for d in sample_days],
            "revenue": [g_series["producer_revenue"][days.index(d)] for d in sample_days],
            "invest_started": [g_series["building_investments_started"][days.index(d)] for d in sample_days],
            "trade_dispatched": [g_series["trade_orders_dispatched"][days.index(d)] for d in sample_days],
            "merchant_cash": [g_series["merchant_cash"][days.index(d)] for d in sample_days],
            "input_shortfall": [g_series["production_input_reserve_shortfall"][days.index(d)] for d in sample_days],
        },
        "cell650": {
            "population": [pop_ts[days.index(d)] for d in sample_days],
            "satisfaction": [sat_ts[days.index(d)] for d in sample_days],
            "livelihood_coverage": [cov_ts[days.index(d)] for d in sample_days],
            "unemployed": [unemp_c_ts[days.index(d)] for d in sample_days],
            "owner_employed": [owner_c_ts[days.index(d)] for d in sample_days],
            "merchant_cash": [merch_cash_cell[days.index(d)] for d in sample_days],
        },
    }
    for gid in ["rice_grain", "prepared_staples", "game_meat", "fish", "gathered_plants", "charcoal", "clothing"]:
        if gid in by_good:
            rs = by_good[gid]
            plot_series["cell650"][f"{gid}_stock"] = [n(rs[days.index(d)]["stock"]) for d in sample_days]
            plot_series["cell650"][f"{gid}_shortage"] = [n(rs[days.index(d)]["shortage_q16"]) / Q16 for d in sample_days]
            plot_series["cell650"][f"{gid}_demand"] = [n(rs[days.index(d)]["demand_ema"]) for d in sample_days]
            plot_series["cell650"][f"{gid}_supply"] = [n(rs[days.index(d)]["offered_supply_ema"]) for d in sample_days]

    # key scalars
    key_numbers = {
        "day_first": d0, "day_last": d1_last, "n_days": len(days),
        "global_cohort_count": (g_series["cohort_count"][0], g_series["cohort_count"][-1]),
        "global_building_groups": (g_series["building_group_count"][0], g_series["building_group_count"][-1]),
        "global_unemployed": (g_series["unemployed_population"][0], g_series["unemployed_population"][-1]),
        "global_births_sum": sum(g_series["births"]),
        "global_deaths_sum": sum(g_series["deaths"]),
        "global_investments_started_sum": sum(g_series["building_investments_started"]),
        "global_employee_jobs_max": max(g_series["filled_employee_jobs"]),
        "global_wages_paid_sum": sum(g_series["building_wages_paid"]),
        "global_unfunded_biz_max": max(g_series["unfunded_business_demand"]),
        "global_discard_mean": st.mean(g_series["production_output_discarded"]),
        "global_output_stock_mean": st.mean(g_series["production_output_stock"]),
        "global_discard_share_approx": st.mean(g_series["production_output_discarded"]) / max(
            1, st.mean(g_series["production_output_discarded"]) + st.mean(g_series["production_output_stock"]) + st.mean(g_series["production_output_retained"]) / 10),
        "cell650_pop": (pop_ts[0], pop_ts[-1], min(pop_ts), max(pop_ts)),
        "cell650_sat": (sat_ts[0], sat_ts[-1], min(sat_ts)),
        "cell650_cov": (cov_ts[0], cov_ts[-1], min(cov_ts)),
        "cell650_late_discard_share": disc_l / out_l if out_l else None,
        "cell650_late_sold_share": sold_l / out_l if out_l else None,
        "cell650_early_discard_share": disc_e / out_e if out_e else None,
        "cell650_owner_openings_last": openings_last,
        "cell650_emp_req_last": emp_req_last,
        "merchant_cash_global": (g_series["merchant_cash"][0], g_series["merchant_cash"][-1]),
        "merchant_liq_q16_global": (g_series["merchant_liquidity_coverage_q16"][0], g_series["merchant_liquidity_coverage_q16"][-1]),
        "cell650_merchant_liq": (merch_liq[0], merch_liq[-1]),
        "death_days": death_days[:12],
        "sat_onset": sat_onset,
        "pending_construction_max": max(g_series["pending_construction_count"]),
    }

    def slim_row(r, keys):
        if not r:
            return None
        return {k: r.get(k) for k in keys}

    spots = {
        "summary_first": slim_row(first_sum, [
            "day_index", "cohort_count", "building_group_count", "filled_owner_jobs",
            "filled_employee_jobs", "unemployed_population", "births", "deaths",
            "population_error", "money_error", "goods_error",
            "production_output_discarded", "production_output_stock",
            "building_investments_started", "producer_revenue",
            "production_input_reserve_shortfall", "trade_orders_dispatched"]),
        "summary_last": slim_row(last_sum, [
            "day_index", "cohort_count", "building_group_count", "filled_owner_jobs",
            "filled_employee_jobs", "unemployed_population", "births", "deaths",
            "population_error", "money_error", "goods_error",
            "production_output_discarded", "production_output_stock",
            "building_investments_started", "producer_revenue",
            "production_input_reserve_shortfall", "trade_orders_dispatched",
            "trade_orders_arrived"]),
        "summary_first_death": slim_row(death_spot, [
            "day_index", "deaths", "births", "unemployed_population"]) if death_spot else None,
        "rice_first": slim_row(rice_first, ["day_index", "good_id", "stock", "household_available_stock",
                                              "demand_ema", "offered_supply_ema", "shortage_q16", "price"]),
        "rice_last": slim_row(rice_last, ["day_index", "good_id", "stock", "household_available_stock",
                                            "demand_ema", "offered_supply_ema", "shortage_q16", "price",
                                            "trade_import_ema", "trade_last_rejection_reason"]),
        "prepared_staples_last": slim_row(prep_last, ["day_index", "good_id", "stock", "demand_ema",
                                                       "offered_supply_ema", "shortage_q16", "price"]),
        "fisher_last": slim_row(fisher_last, ["day_index", "signature_id", "population", "funds",
                                             "epoch_income", "epoch_expense", "livelihood_coverage_q16",
                                             "satisfaction_q16", "unemployed", "owner_employed"]),
        "hunter_last": slim_row(hunter_last, ["day_index", "signature_id", "population", "funds",
                                               "epoch_income", "epoch_expense", "livelihood_coverage_q16",
                                               "satisfaction_q16", "unemployed"]),
        "top_discard_building_last": slim_row(top_disc, [
            "day_index", "type_id", "group_index", "count", "operating_state",
            "filled_owner", "owner_required", "owner_openings",
            "last_output", "last_sold", "last_discarded", "last_retained",
            "realized_profit_margin_q16", "last_climate_capacity_q16"]),
    }

    out = {
        "integrity": integrity,
        "conservation": conservation,
        "key_numbers": key_numbers,
        "global_ts_compact": {k: {kk: v[kk] for kk in (
            "first", "last", "early90_mean", "late90_mean", "sum", "min", "max", "nonzero_days")
        } for k, v in global_ts.items()},
        "cohort_entities": cohort_entities,
        "market_key_goods": market_goods,
        "late_shortage_top": [
            {"shortage_late": a, "good_id": g, "stock_late": s, "demand_late": d, "supply_late": u}
            for a, g, s, d, u in all_late_shortage[:20]
        ],
        "demand_no_supply": demand_no_supply[:20],
        "buildings_cell650": {
            "actual_rows": len(actual), "candidate_rows": len(cand), "construction_rows": len(constr),
            "late_output": out_l, "late_sold": sold_l, "late_discard": disc_l, "late_retained": ret_l,
            "early_output": out_e, "early_discard": disc_e,
            "state_last": dict(state_last),
            "openings_last": openings_last, "filled_owner_last": filled_last,
            "owner_required_last": req_last,
            "emp_req_last": emp_req_last, "emp_filled_last": emp_fill_last,
            "last_day_candidates": len(last_cand),
            "last_cand_reject": dict(sorted(last_cand_rej.items(), key=lambda kv: -kv[1])),
            "last_cand_score_max": max(last_cand_score) if last_cand_score else None,
            "employment_candidates_last": len(last_emp),
            "employment_reject": dict(emp_rej),
            "types": type_diag,
        },
        "resources_cell650": res_diag,
        "binding_resources": binding,
        "correlations": corr,
        "stagnation_rank": [
            {"rank": i + 1, "domain": a, "score_0to3": s, "notes": notes}
            for i, (a, s, notes) in enumerate(ranking)
        ],
        "plot_series": plot_series,
        "spot_checks": spots,
        "windows": {
            "full": [d0, d1_last],
            "early90": [days[0], days[early_n - 1]],
            "late90": [days[-late_n], days[-1]],
        },
    }

    json_path = ROOT / "tmp" / "diag_v25_cell650_20260831.json"
    json_path.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({
        "json": str(json_path),
        "days": [d0, d1_last],
        "rows": integrity["rows"],
        "conservation_max_abs": {k: conservation[k]["max_abs"] for k in conservation},
        "rank": ranking,
        "pop": key_numbers["cell650_pop"],
        "sat": key_numbers["cell650_sat"],
        "invest_sum": key_numbers["global_investments_started_sum"],
        "births": key_numbers["global_births_sum"],
        "deaths": key_numbers["global_deaths_sum"],
    }, ensure_ascii=False, indent=2, default=str))


if __name__ == "__main__":
    main()
