import json
from pathlib import Path

d = json.loads(Path("tmp/diag_v25_cell650_20260831.json").read_text(encoding="utf-8"))
out = []
out.append("=== COHORTS ===")
for c in d["cohort_entities"]:
    out.append(
        f"{c['profession']:16} merch={c['is_merchant']} pop {c['pop_first']}->{c['pop_last']} "
        f"sat {c['sat_first']:.3f}->{c['sat_last']:.3f} min={c['sat_min']:.3f} "
        f"cov {c['cov_first']:.2f}->{c['cov_last']:.2f} min={c['cov_min']:.3f} "
        f"incE {c['income_early90']:.0f} incL {c['income_late90']:.0f} expL {c['expense_late90']:.0f} "
        f"unemp_max={c['unemp_max']} owner={c['owner_last']} need={c['worst_need']} "
        f"sat0={c['days_sat0']} covlt1={c['days_cov_lt1']}"
    )
out.append("=== MARKET KEY ===")
for g in d["market_key_goods"]:
    out.append(
        f"{g['good_id']:22} stk {g['stock_first']:.0f}->{g['stock_last']:.0f} min={g['stock_min']:.0f} "
        f"havL={g['hav_last']:.0f} demE={g['demand_early']:.1f} demL={g['demand_late']:.1f} "
        f"supL={g['supply_late']:.1f} wdL={g['withdraw_late']:.1f} shE={g['shortage_early']:.2f} "
        f"shL={g['shortage_late']:.2f} so={g['stockout_days']} sev={g['severe_days']} "
        f"firstSO={g['first_stockout']} firstSev={g['first_severe']} px {g['price_first']:.0f}->{g['price_last']:.0f} "
        f"inb={g['inbound_sum']} outb={g['outbound_sum']} rej={g['rejection']}"
    )
out.append("=== LATE SHORTAGE TOP ===")
for x in d["late_shortage_top"][:18]:
    out.append(str(x))
out.append("=== DEMAND NO SUPPLY ===")
for x in d["demand_no_supply"]:
    out.append(str(x))
b = d["buildings_cell650"]
out.append("=== BUILDINGS META ===")
out.append(str({k: b[k] for k in b if k != "types"}))
out.append("=== TYPES ===")
for t in b["types"]:
    out.append(
        f"{t['building']:28} g {t['groups_first']}->{t['groups_last']} cnt={t['count_last']} "
        f"own f/r/c/o {t['filled_owner_last']}/{t['owner_req_last']}/{t['owner_cap_last']}/{t['owner_openings_last']} "
        f"emp {t['emp_filled_last']}/{t['emp_req_last']} outL={t['output_late_sum']:.0f} "
        f"sold={t['sold_late_sum']:.0f} disc={t['discard_late_sum']:.0f} dshare={t['discard_share_late']} "
        f"soldS={t['sold_share_late']} util={t['util_late_mean']:.3f} mar={t['margin_late_mean']:.3f} "
        f"state={t['states_last']} clim={t['climate_cap_last']:.3f} res={t['resource_late']:.1f} "
        f"gen={t['resource_gen_late']:.1f} rev={t['revenue_late']:.0f}"
    )
out.append("=== RESOURCES (nonzero or changing) ===")
for r in d["resources_cell650"]:
    if r["extract_applied_sum"] or abs(r["opening"] - r["final"]) > 1e-6 or r["opening"] > 1:
        out.append(
            f"{r['resource_id']:22} open={r['opening']:.6g} fin={r['final']:.6g} min={r['min']:.6g} "
            f"dep={r['depletion_to_min']} extA={r['extract_applied_sum']:.6g} genA={r['gen_applied_sum']:.6g} "
            f"natN={r['nat_neg_sum']:.6g} natP={r['nat_pos_sum']:.6g} life={r['proj_life_last']} "
            f"zero={r['first_zero']} extDays={r['extract_days']} yield={r['safe_yield_last']}"
        )
out.append("=== GLOBAL TS compact selected ===")
for k in [
    "births", "deaths", "unemployed_population", "filled_owner_jobs", "filled_employee_jobs",
    "building_investments_started", "building_investment_candidates",
    "building_investment_demand_limited", "building_investment_material_limited",
    "building_investment_capital_limited", "building_investment_owner_population_limited",
    "production_output_discarded", "production_output_stock", "producer_revenue",
    "trade_orders_dispatched", "trade_orders_arrived", "production_input_reserve_shortfall",
    "merchant_cash", "loss_suspended_building_groups", "climate_limited_building_groups",
    "average_climate_capacity_q16", "maintenance_unmet",
]:
    out.append(f"{k}: {d['global_ts_compact'][k]}")
out.append("=== SPOTS ===")
out.append(json.dumps(d["spot_checks"], indent=2, ensure_ascii=False))
out.append("=== PLOT ===")
out.append(json.dumps(d["plot_series"], indent=2, ensure_ascii=False))
Path("tmp/dump_diag.txt").write_text("\n".join(out), encoding="utf-8")
print("wrote tmp/dump_diag.txt", len(out), "lines")
