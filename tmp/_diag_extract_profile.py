import json
from pathlib import Path

d = json.loads(
    Path("tmp/economy_record_20260901_164046_v25_cell1522_q15_r15_profile.json").read_text(
        encoding="utf-8"
    )
)

print("=== record ===")
print(json.dumps(d["record"], ensure_ascii=False, indent=2)[:4000])

print("\n=== tables ===")
interesting = [
    "path",
    "rows",
    "column_count",
    "schema_fingerprint",
    "header_sha1",
    "day_min",
    "day_max",
    "epoch_row_id_min",
    "epoch_row_id_max",
    "unique_cells",
    "unique_goods",
    "unique_resources",
    "unique_signatures",
    "duplicate_primary_keys",
    "malformed_row_count",
    "blank_identifier_rows",
    "gap_days",
    "missing_epoch_row_ids",
    "extra_epoch_row_ids",
]
for kind, t in d["tables"].items():
    keep = {k: t[k] for k in interesting if k in t}
    # also dump nested integrity-like keys
    for k, v in t.items():
        if isinstance(v, (dict, list)) and k not in ("columns",):
            if k in (
                "integrity",
                "coverage",
                "warnings",
                "day_range",
                "cells",
                "primary_keys",
            ):
                keep[k] = v
    print(f"\n-- {kind} keys={list(t.keys())[:40]} --")
    print(json.dumps(keep, ensure_ascii=False, indent=2)[:3000])

print("\n=== signals_not_findings ===")
print(json.dumps(d.get("signals_not_findings"), ensure_ascii=False, indent=2)[:12000])

print("\n=== summary first/last/min/max/sum selected ===")
s = d["summary"]
keys = [
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
    "unfunded_business_demand",
    "trade_orders_dispatched",
    "trade_orders_arrived",
    "trade_capacity_used",
    "merchant_credit_outstanding",
    "merchant_credit_bad_debt",
    "recovery_liquidated_buildings",
    "building_investments_started",
    "merchant_cash",
    "merchant_liquidity_coverage_q16",
    "population_error",
    "money_error",
    "goods_error",
    "trade_response_deadline_misses",
    "trade_response_deadline_misses_cumulative",
    "trade_unresolved_no_attempt",
    "climate_limited_building_groups",
    "average_climate_capacity_q16",
    "maintenance_unmet",
    "production_input_reserve_shortfall",
]
for k in keys:
    print(
        f"{k}: first={s['first'].get(k)} last={s['last'].get(k)} "
        f"min={s.get('min', {}).get(k)} max={s.get('max', {}).get(k)} "
        f"sum={s.get('sum', {}).get(k)}"
    )

print("\n=== entities cohort count ===", len(d["entities"].get("cohorts", [])))
print("=== entities market goods ===", len(d["entities"].get("market_goods", d["entities"].get("goods", []))))
print("=== entities resources ===", len(d["entities"].get("resources", [])))
print("=== entities buildings ===", len(d["entities"].get("buildings", d["entities"].get("building_groups", []))))
print("entity keys", list(d["entities"].keys()))
