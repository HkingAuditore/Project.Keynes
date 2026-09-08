#!/usr/bin/env python3
"""Focused analysis of the v25 cell1860 economy recorder family.

Reads the five CSVs once, prints a compact evidence packet.
"""
from __future__ import annotations

import csv
import math
import statistics as st
from collections import defaultdict
from pathlib import Path

BASE = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260829_025602_v25_cell1860_q-15_r31")
Q16 = 65536.0
Q32 = 4294967296.0
MONEY = 10000.0
GOODS = 1000.0

W = 180  # late window


def load(name):
    with FILES[name].open(newline="", encoding="utf-8-sig") as f:
        r = csv.DictReader(f)
        return list(r)


# The recorder writes <prefix>_<kind>.csv files, not a directory.
FILES = {k: BASE.parent / f"{BASE.name}_{k}.csv" for k in
         ("summary", "cohorts", "market", "buildings", "resources")}


def q16(v):
    return int(v) / Q16


def win_stats(rows, key, conv=float):
    vals = [conv(r[key]) for r in rows]
    return vals


def fmt_series(vals, days):
    n = len(vals)
    if n == 0:
        return "n/a"
    early = vals[:W]
    late = vals[-W:]
    return (f"first={vals[0]:.6g} last={vals[-1]:.6g} min={min(vals):.6g}@d{days[vals.index(min(vals))]} "
            f"max={max(vals):.6g}@d{days[vals.index(max(vals))]} early180={st.mean(early):.6g} late180={st.mean(late):.6g}")


def main():
    summary = load("summary")
    cohorts = load("cohorts")
    market = load("market")
    buildings = load("buildings")
    resources = load("resources")

    days = [int(r["day_index"]) for r in summary]
    print("=" * 78)
    print("GLOBAL SUMMARY  day %d..%d  n=%d" % (days[0], days[-1], len(days)))
    print("=" * 78)

    # ---- population proxy
    print("\n-- population proxy (no global population column exists) --")
    for c in ["cohort_count", "filled_owner_jobs", "filled_employee_jobs", "unemployed_population"]:
        v = [int(r[c]) for r in summary]
        print(f"  {c:26s} first={v[0]:5d} last={v[-1]:5d} min={min(v):5d} max={max(v):5d} mean={st.mean(v):8.2f}")
    emp = [int(r["filled_owner_jobs"]) + int(r["filled_employee_jobs"]) + int(r["unemployed_population"])
           for r in summary]
    print(f"  {'labor_force(own+emp+unemp)':26s} first={emp[0]:5d} last={emp[-1]:5d} min={min(emp):5d} max={max(emp):5d} mean={st.mean(emp):8.2f}")

    # ---- births / deaths
    print("\n-- demography --")
    b = [int(r["births"]) for r in summary]
    dth = [int(r["deaths"]) for r in summary]
    span_days = days[-1] - days[0] + 1
    years = span_days / 365.0
    pop_mean = st.mean(emp)
    print(f"  births={sum(b)} deaths={sum(dth)} net={sum(b)-sum(dth)} over {span_days} days ({years:.2f} yr)")
    print(f"  mean labor force = {pop_mean:.1f}")
    print(f"  crude birth rate  = {sum(b)/years/pop_mean*1000:7.2f} per 1000 labor-force per year")
    print(f"  crude death rate  = {sum(dth)/years/pop_mean*1000:7.2f} per 1000 labor-force per year")
    print(f"  net  rate         = {(sum(b)-sum(dth))/years/pop_mean*1000:7.2f}")
    bdays = [days[i] for i, x in enumerate(b) if x > 0]
    ddays = [days[i] for i, x in enumerate(dth) if x > 0]
    print(f"  days with births>0 : {len(bdays)} / {len(days)}  ({len(bdays)/len(days)*100:.2f}%)")
    print(f"  first 10 birth days : {bdays[:10]}")
    print(f"  last  10 birth days : {bdays[-10:]}")
    gaps = [bdays[i+1] - bdays[i] for i in range(len(bdays) - 1)]
    if gaps:
        print(f"  birth gap days: min={min(gaps)} median={st.median(gaps)} max={max(gaps)}")
    print(f"  days with deaths>0 : {len(ddays)} ({len(ddays)/len(days)*100:.2f}%)")
    dgaps = [ddays[i+1] - ddays[i] for i in range(len(ddays) - 1)]
    if dgaps:
        print(f"  death gap days: min={min(dgaps)} median={st.median(dgaps)} max={max(dgaps)}")
    # births per 500-day bucket
    print("\n  births/deaths per 500-day bucket:")
    for lo in range(days[0], days[-1] + 1, 500):
        hi = lo + 500
        idx = [i for i, dd in enumerate(days) if lo <= dd < hi]
        print(f"    d{lo:5d}-{hi-1:5d}: births={sum(b[i] for i in idx):4d} deaths={sum(dth[i] for i in idx):4d} "
              f"cohorts={st.mean([int(summary[i]['cohort_count']) for i in idx]):5.1f} "
              f"labor={st.mean([emp[i] for i in idx]):6.1f}")

    # ---- global flows that are dead
    print("\n-- globally zero / near-zero flow counters --")
    for c in ["production_inputs_consumed", "building_resource_generated", "trade_candidates_generated",
              "trade_candidates_accepted", "trade_orders_dispatched", "trade_orders_arrived",
              "building_investments_started", "building_wages_unpaid", "merchant_credit_bad_debt",
              "recovery_restarted", "recovery_failed", "recovery_liquidated_buildings",
              "desired_business_demand", "funded_business_demand", "unfunded_business_demand",
              "production_input_reserved", "production_input_reserve_shortfall",
              "owner_working_capital_reserved", "owner_working_capital_allocated",
              "building_investment_candidates", "construction_goods_consumed", "maintenance_unmet"]:
        v = [int(r[c]) for r in summary]
        print(f"  {c:38s} total={sum(v):>16,}  nonzero_days={sum(1 for x in v if x):5d}")

    # ---- merchant liquidity
    print("\n-- merchant liquidity / money --")
    for c in ["merchant_cash", "merchant_economic_assets", "merchant_procurement_budget",
              "merchant_procurement_spent", "merchant_inventory_retail_value",
              "merchant_inventory_liquidation_value", "bullion_money_issued", "producer_revenue",
              "building_wages_paid", "producer_support_money_issued"]:
        v = [int(r[c]) for r in summary]
        print(f"  {c:38s} first={v[0]:>16,} last={v[-1]:>16,} peak={max(v):>16,} trough={min(v):>16,}")

    # ---- production
    print("\n-- production / goods --")
    for c in ["production_output_stock", "production_output_retained", "production_output_discarded",
              "production_output_supported", "building_resource_consumed", "cycle_flow_produced",
              "cycle_flow_consumed", "cycle_flow_discarded", "loss_suspended_building_groups"]:
        v = [int(r[c]) for r in summary]
        print(f"  {c:38s} " + fmt_series([float(x) for x in v], days))

    # ---- trade signals vs action
    print("\n-- trade signal vs action --")
    for c in ["trade_source_signals", "trade_destination_signals", "trade_ready_candidates",
              "trade_relief_candidates", "trade_capacity_available", "trade_capacity_used",
              "trade_deficit_episodes_started", "trade_deficit_episodes_resolved",
              "trade_unresolved_no_attempt", "trade_unresolved_no_spread", "trade_unresolved_margin",
              "trade_unresolved_route", "trade_unresolved_stock", "trade_unresolved_capacity",
              "trade_unresolved_cash", "trade_unresolved_order_cap", "trade_signal_max_age_days",
              "trade_response_deadline_misses"]:
        v = [int(r[c]) for r in summary]
        print(f"  {c:38s} total={sum(v):>14,} last={v[-1]:>12,} nonzero_days={sum(1 for x in v if x):5d}")

    # =====================================================================
    print("\n" + "=" * 78)
    print("COHORTS (cell 1860 only)")
    print("=" * 78)
    by_day = defaultdict(list)
    for r in cohorts:
        by_day[int(r["day_index"])].append(r)
    cpop = {d: sum(int(x["population"]) for x in v) for d, v in by_day.items()}
    cdays = sorted(cpop)
    print(f"  cell 1860 population first={cpop[cdays[0]]} last={cpop[cdays[-1]]} "
          f"min={min(cpop.values())} max={max(cpop.values())} mean={st.mean(cpop.values()):.2f}")
    print(f"  cohorts per day: min={min(len(v) for v in by_day.values())} max={max(len(v) for v in by_day.values())}")

    print("\n  per-cohort detail (last day sample):")
    last_day = cdays[-1]
    for r in sorted(by_day[last_day], key=lambda x: int(x["cohort_index"])):
        print(f"    coh{r['cohort_index']:>2s} sig={r['signature_id']:>10s} prof={r['profession_id']:>3s} "
              f"pop={r['population']:>4s} funds/人={int(r['funds'])/max(1,int(r['population']))/MONEY:9.2f} "
              f"sat={int(r['satisfaction_q16'])/Q16:.4f} cash_cov={int(r['cash_expense_coverage_q16'])/Q16:.3f} "
              f"liv_cov={int(r['livelihood_coverage_q16'])/Q16:.3f} worst={r['worst_need_id']:>3s} "
              f"merch={r['is_merchant']} own={r['owner_employed']} emp={r['employee_employed']} unemp={r['unemployed']}")

    print("\n  cohort satisfaction / coverage over time (cell 1860):")
    for c, conv in [("satisfaction_q16", lambda x: int(x) / Q16),
                    ("cash_expense_coverage_q16", lambda x: int(x) / Q16),
                    ("livelihood_coverage_q16", lambda x: int(x) / Q16)]:
        v = [conv(r[c]) for r in cohorts]
        cd = [int(r["day_index"]) for r in cohorts]
        print(f"    {c:32s} " + fmt_series(v, cd))
    # worst need distribution
    wn = defaultdict(int)
    for r in cohorts:
        wn[r["worst_need_id"]] += 1
    print("    worst_need_id distribution:", dict(sorted(wn.items(), key=lambda kv: -kv[1])[:10]))
    # per capita funds over time
    print("    funds per capita (cell 1860):")
    v = []
    cd2 = []
    for d in cdays:
        p = sum(int(x["population"]) for x in by_day[d])
        f = sum(int(x["funds"]) for x in by_day[d])
        if p:
            v.append(f / p / MONEY)
            cd2.append(d)
    print("      " + fmt_series(v, cd2))

    # =====================================================================
    print("\n" + "=" * 78)
    print("MARKET (cell 1860)")
    print("=" * 78)
    goods = sorted({r["good_id"] for r in market})
    print(f"  goods={len(goods)} rows={len(market)} days={len({r['day_index'] for r in market})}")
    last_day_m = max(int(r["day_index"]) for r in market)
    act = defaultdict(list)  # good -> rows
    for r in market:
        act[r["good_id"]].append(r)
    rowsout = []
    for g, rs in act.items():
        stock_last = int(rs[-1]["stock"])
        stock_max = max(int(x["stock"]) for x in rs)
        dem = [int(x["demand_ema"]) for x in rs]
        short = [int(x["shortage_q16"]) for x in rs]
        price = [int(x["price"]) for x in rs]
        rowsout.append((g, stock_last, stock_max, max(dem), st.mean(dem),
                        max(short) / Q16, st.mean(short) / Q16, price[0], price[-1],
                        min(price), max(price)))
    rowsout.sort(key=lambda x: -x[2])
    print("\n  top 25 goods by peak stock:")
    print(f"    {'good':28s} {'stock_last':>10s} {'stock_max':>10s} {'dem_max':>9s} {'dem_avg':>9s} "
          f"{'short_max':>9s} {'p_first':>9s} {'p_last':>9s} {'p_min':>9s} {'p_max':>9s}")
    for r in rowsout[:25]:
        print(f"    {r[0]:28s} {r[1]:10d} {r[2]:10d} {r[3]:9d} {r[4]:9.1f} {r[5]:9.3f} "
              f"{r[7]:9d} {r[8]:9d} {r[9]:9d} {r[10]:9d}")
    active = [r for r in rowsout if r[2] > 0 or r[3] > 0]
    print(f"\n  goods ever active (peak stock>0 or demand>0): {len(active)} / {len(rowsout)}")
    print("  active goods list:", [r[0] for r in active])

    # price dynamics for active goods
    print("\n  active goods, price and shortage detail:")
    for g, rs in sorted(act.items()):
        if max(int(x["stock"]) for x in rs) <= 0 and max(int(x["demand_ema"]) for x in rs) <= 0:
            continue
        price = [int(x["price"]) for x in rs]
        stock = [int(x["stock"]) for x in rs]
        dem = [int(x["demand_ema"]) for x in rs]
        wd = [int(x["realized_withdrawal_ema"]) for x in rs]
        off = [int(x["offered_supply_ema"]) for x in rs]
        sh = [int(x["shortage_q16"]) for x in rs]
        hav = [int(x["household_available_stock"]) for x in rs]
        print(f"    {g:26s} stock {stock[0]:8d}->{stock[-1]:8d} (max {max(stock):8d}) "
              f"hav {hav[-1]:8d} dem {st.mean(dem):8.1f}->? max {max(dem):8d} "
              f"withdraw {st.mean(wd):8.1f} offered {st.mean(off):8.1f} "
              f"short_avg {st.mean(sh)/Q16:6.3f} max {max(sh)/Q16:6.3f} "
              f"price {price[0]:7d}->{price[-1]:7d} [{min(price)},{max(price)}]")

    # =====================================================================
    print("\n" + "=" * 78)
    print("BUILDINGS (cell 1860)")
    print("=" * 78)
    bygrp = defaultdict(list)
    for r in buildings:
        bygrp[(r["is_construction"], r["group_index"], r["type_id"], r["owner_signature_id"],
               r["investment_candidate"])].append(r)
    print(f"  row-classes: {len(bygrp)}  rows={len(buildings)}")
    actual = {k: v for k, v in bygrp.items() if k[1] != "-1" and k[0] == "false"}
    cand = {k: v for k, v in bygrp.items() if k[1] == "-1"}
    print(f"  actual groups: {len(actual)}   candidate-only rows: {len(cand)}")
    print(f"\n  {'isC':>4s} {'grp':>4s} {'type':>5s} {'owner':>11s} {'n':>5s} {'cnt':>5s} "
          f"{'own_req':>7s} {'own_fill':>8s} {'emp_req':>7s} {'emp_fill':>8s} {'cap_q16':>8s} "
          f"{'margin':>8s} {'state':>12s} {'out':>8s} {'sold':>8s} {'disc':>7s} {'ret':>8s} {'rev':>9s} {'gap':>9s}")
    for k, v in sorted(actual.items(), key=lambda kv: min(int(x["group_index"]) for x in kv[1])):
        la = v[-1]
        print(f"  {k[0][:4]:>4s} {k[1]:>4s} {k[2]:>5s} {k[3]:>11s} {len(v):5d} {la['count']:>5s} "
              f"{la['owner_required']:>7s} {la['filled_owner']:>8s} {la['employee_required']:>7s} {la['employee_filled']:>8s} "
              f"{int(la['capacity_q16'])/Q16:8.3f} {int(la['realized_profit_margin_q16'])/Q16:8.3f} "
              f"{la['operating_state']:>12s} {la['last_output']:>8s} {la['last_sold']:>8s} {la['last_discarded']:>7s} "
              f"{la['last_retained']:>8s} {la['last_revenue']:>9s} {la['viability_income_gap']:>9s}")

    # =====================================================================
    print("\n" + "=" * 78)
    print("RESOURCES (cell 1860)")
    print("=" * 78)
    byres = defaultdict(list)
    for r in resources:
        byres[r["resource_id"]].append(r)
    print(f"  resources={len(byres)} rows={len(resources)}")
    print(f"\n  {'resource':18s} {'open':>14s} {'final':>14s} {'min':>14s} {'d%':>7s} "
          f"{'gen_appl':>10s} {'extr_appl':>10s} {'nat_neg':>12s} {'safe_yield':>11s} {'life_d':>10s}")
    for rid, rs in byres.items():
        op = float(rs[0]["opening_reserve"])
        fi = float(rs[-1]["reserve"])
        mn = min(float(x["reserve"]) for x in rs)
        gen = sum(float(x["artificial_generation_applied"]) for x in rs)
        ext = sum(float(x["artificial_extraction_applied"]) for x in rs)
        natneg = sum(float(x["natural_negative_change"]) for x in rs)
        dpct = (op - fi) / op * 100 if op > 0 else 0.0
        sy = float(rs[-1]["safe_yield"])
        life = rs[-1]["projected_life_days"]
        print(f"  {rid:18s} {op:14.1f} {fi:14.1f} {mn:14.1f} {dpct:7.2f} {gen:10.1f} {ext:10.1f} "
              f"{natneg:12.1f} {sy:11.1f} {life:>10s}")


if __name__ == "__main__":
    main()
