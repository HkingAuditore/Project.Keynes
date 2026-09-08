#!/usr/bin/env python3
"""Second pass: satisfaction timeline, per-cohort divergence, food/carrying
evidence, maintenance, and birth-event context."""
from __future__ import annotations

import csv
import statistics as st
from collections import defaultdict
from pathlib import Path

BASE = Path(r"D:\Godot\ProjectKeynes\Project.Keynes\tmp\economy_record_20260829_025602_v25_cell1860_q-15_r31")
FILES = {k: BASE.parent / f"{BASE.name}_{k}.csv" for k in
         ("summary", "cohorts", "market", "buildings", "resources")}
Q16 = 65536.0
Q32 = 4294967296.0


def load(name):
    with FILES[name].open(newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def main():
    summary = load("summary")
    cohorts = load("cohorts")
    market = load("market")
    buildings = load("buildings")

    days = [int(r["day_index"]) for r in summary]
    births = {int(r["day_index"]): int(r["births"]) for r in summary}
    deaths = {int(r["day_index"]): int(r["deaths"]) for r in summary}

    # ---------- satisfaction timeline ----------
    by_day = defaultdict(list)
    for r in cohorts:
        by_day[int(r["day_index"])].append(r)
    cdays = sorted(by_day)
    print("=" * 78)
    print("SATISFACTION / COVERAGE TIMELINE (cell 1860, 500-day buckets)")
    print("=" * 78)
    print(f"{'bucket':>16s} {'sat_mean':>9s} {'sat_min':>8s} {'cov_mean':>9s} {'liv_mean':>9s} "
          f"{'pop':>5s} {'funds_pc':>10s} {'births':>7s} {'deaths':>7s}")
    for lo in range(cdays[0], cdays[-1] + 1, 500):
        hi = lo + 500
        rows = [r for d in cdays if lo <= d < hi for r in by_day[d]]
        if not rows:
            continue
        sat = [int(r["satisfaction_q16"]) / Q16 for r in rows]
        cov = [int(r["cash_expense_coverage_q16"]) / Q16 for r in rows]
        liv = [int(r["livelihood_coverage_q16"]) / Q16 for r in rows]
        pop = sum(int(r["population"]) for r in rows) / len({r["day_index"] for r in rows})
        funds = sum(int(r["funds"]) for r in rows) / max(1, sum(int(r["population"]) for r in rows)) / 10000
        b = sum(v for d, v in births.items() if lo <= d < hi)
        dd = sum(v for d, v in deaths.items() if lo <= d < hi)
        print(f"{lo:7d}-{hi-1:7d} {st.mean(sat):9.4f} {min(sat):8.4f} {st.mean(cov):9.3f} "
              f"{st.mean(liv):9.3f} {pop:5.1f} {funds:10.1f} {b:7d} {dd:7d}")

    # per-cohort divergence of satisfaction on a single day
    print("\n-- is satisfaction shared across cohorts on the same day? --")
    same = 0
    total = 0
    for d in cdays[::37]:
        vals = {r["satisfaction_q16"] for r in by_day[d]}
        total += 1
        if len(vals) == 1:
            same += 1
    print(f"  sampled {total} days; identical across cohorts on {same} ({same/total*100:.0f}%)")
    d0 = cdays[0]
    print("  day", d0, "values:", [r["satisfaction_q16"] for r in by_day[d0]])
    print("  day", cdays[-1], "values:", [r["satisfaction_q16"] for r in by_day[cdays[-1]]])
    # worst need timeline
    print("\n-- worst_need_id by 1000-day bucket --")
    for lo in range(cdays[0], cdays[-1] + 1, 1000):
        hi = lo + 1000
        rows = [r for d in cdays if lo <= d < hi for r in by_day[d]]
        wn = defaultdict(int)
        for r in rows:
            wn[r["worst_need_id"]] += 1
        print(f"  d{lo}-{hi-1}: " + ", ".join(f"{k}:{v}" for k, v in sorted(wn.items(), key=lambda kv: -kv[1])))

    # ---------- food market detail ----------
    print("\n" + "=" * 78)
    print("FOOD / SUBSISTENCE MARKET DETAIL (cell 1860)")
    print("=" * 78)
    act = defaultdict(list)
    for r in market:
        act[r["good_id"]].append(r)
    mdays = sorted({int(r["day_index"]) for r in market})
    for g in ("gathered_plants", "game_meat", "logs", "clothing", "bast_fiber", "raw_hide"):
        rs = act.get(g)
        if not rs:
            continue
        print(f"\n  -- {g} --")
        print(f"    {'bucket':>16s} {'stock':>9s} {'havail':>9s} {'demand':>8s} {'offered':>8s} "
              f"{'withdr':>8s} {'short':>7s} {'price':>8s} {'imp_ema':>8s} {'exp_ema':>8s}")
        for lo in range(mdays[0], mdays[-1] + 1, 700):
            hi = lo + 700
            sub = [r for r in rs if lo <= int(r["day_index"]) < hi]
            if not sub:
                continue
            print(f"    {lo:7d}-{hi-1:7d} {st.mean([int(x['stock']) for x in sub]):9.0f} "
                  f"{st.mean([int(x['household_available_stock']) for x in sub]):9.0f} "
                  f"{st.mean([int(x['demand_ema']) for x in sub]):8.0f} "
                  f"{st.mean([int(x['offered_supply_ema']) for x in sub]):8.0f} "
                  f"{st.mean([int(x['realized_withdrawal_ema']) for x in sub]):8.0f} "
                  f"{st.mean([int(x['shortage_q16']) for x in sub])/Q16:7.3f} "
                  f"{st.mean([int(x['price']) for x in sub]):8.0f} "
                  f"{st.mean([int(x['trade_import_ema']) for x in sub]):8.0f} "
                  f"{st.mean([int(x['trade_export_ema']) for x in sub]):8.0f}")
        # stockout / severe shortage days
        zero = sum(1 for x in rs if int(x["household_available_stock"]) <= 0)
        sev = sum(1 for x in rs if int(x["shortage_q16"]) >= 0.5 * Q16)
        print(f"    days household_available_stock==0: {zero}/{len(rs)} ({zero/len(rs)*100:.1f}%)")
        print(f"    days shortage_q16 >= 0.5: {sev} ({sev/len(rs)*100:.1f}%)")
        rej = defaultdict(int)
        for x in rs:
            rej[x["trade_last_rejection_reason"]] += 1
        print(f"    trade_last_rejection_reason: {dict(list(sorted(rej.items(), key=lambda kv:-kv[1]))[:6])}")
        print(f"    trade_signal_age_days last={rs[-1]['trade_signal_age_days']} "
              f"first_dispatch_delay={rs[-1]['trade_first_dispatch_delay_days']} "
              f"relief_pressure={int(rs[-1]['trade_relief_pressure_q16'])/Q16:.3f}")

    # ---------- buildings row classes ----------
    print("\n" + "=" * 78)
    print("BUILDING ROW CLASSES (cell 1860)")
    print("=" * 78)
    bygrp = defaultdict(list)
    for r in buildings:
        bygrp[(r["is_construction"], r["group_index"], r["type_id"], r["owner_signature_id"],
               r["investment_candidate"])].append(r)
    print(f"  distinct classes: {len(bygrp)}")
    print(f"  is_construction values: {sorted({r['is_construction'] for r in buildings})}")
    print(f"  group_index values: {sorted({r['group_index'] for r in buildings})}")
    print("\n  per class:")
    for k, v in sorted(bygrp.items(), key=lambda kv: -len(kv[1])):
        la = v[-1]
        print(f"    isC={k[0]:>2s} grp={k[1]:>3s} type={k[2]:>4s} owner={k[3]:>10s} cand={k[4]:>2s} "
              f"days={len(v):5d} first_d={v[0]['day_index']} last_d={la['day_index']} count={la['count']:>4s} "
              f"state={la['operating_state']:>12s} rej={la['investment_rejection_reason'][:28]:28s} "
              f"score={int(la['investment_score_q16'])/Q16:7.4f} req_cap={la['investment_required_capital']:>10s}")

    # ---------- maintenance ----------
    print("\n" + "=" * 78)
    print("MAINTENANCE & SUPPORT")
    print("=" * 78)
    for c in ["maintenance_goods_consumed", "maintenance_unmet", "production_output_supported",
              "owner_output_consumed", "producer_support_money_issued", "building_resource_generated",
              "building_resource_net_delta", "building_resource_consumed"]:
        v = [int(r[c]) for r in summary]
        nz = [x for x in v if x]
        print(f"  {c:38s} total={sum(v):>16,} nonzero_days={len(nz):5d} "
              f"mean_nz={st.mean(nz) if nz else 0:12,.0f} first={v[0]:>10,} last={v[-1]:>10,}")

    # ---------- birth day context ----------
    print("\n" + "=" * 78)
    print("BIRTH EVENT CONTEXT (cell-1860 state on the day before each birth)")
    print("=" * 78)
    sat_by_day = {d: st.mean([int(r["satisfaction_q16"]) for r in by_day[d]]) / Q16
                  for d in cdays}
    cov_by_day = {d: st.mean([int(r["livelihood_coverage_q16"]) for r in by_day[d]]) / Q16
                  for d in cdays}
    bdays = sorted(d for d, v in births.items() if v > 0)
    allsat = [sat_by_day[d] for d in cdays]
    print(f"  cell-1860 mean satisfaction overall = {st.mean(allsat):.4f}")
    onb = [sat_by_day[d] for d in bdays if d in sat_by_day]
    print(f"  cell-1860 mean satisfaction on birth days = {st.mean(onb):.4f} (n={len(onb)})")
    print(f"  first 12 birth days -> sat: "
          f"{[(d, round(sat_by_day.get(d, float('nan')), 3)) for d in bdays[:12]]}")
    print(f"  last 12 birth days  -> sat: "
          f"{[(d, round(sat_by_day.get(d, float('nan')), 3)) for d in bdays[-12:]]}")

    # correlation: satisfaction (cell) vs births (global), lagged
    print("\n  lagged correlation, cell-1860 satisfaction vs global births (first differences):")
    xs = []
    ys = []
    for i in range(1, len(cdays)):
        xs.append(sat_by_day[cdays[i]] - sat_by_day[cdays[i - 1]])
        ys.append(births.get(cdays[i], 0))
    for lag in (0, 1, 7, 30, 90, 180, 365):
        a = xs[:-lag - 1] if lag else xs
        b = ys[lag + 1:] if lag else ys
        if len(a) < 30:
            continue
        ma, mb = st.mean(a), st.mean(b)
        num = sum((p - ma) * (q - mb) for p, q in zip(a, b))
        da = sum((p - ma) ** 2 for p in a) ** .5
        db = sum((q - mb) ** 2 for q in b) ** .5
        print(f"    lag {lag:4d} d: r = {num/(da*db) if da and db else 0:+.4f} (n={len(a)})")


if __name__ == "__main__":
    main()
