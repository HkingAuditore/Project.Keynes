#!/usr/bin/env python3
"""Stream and diagnose a Project.Keynes economy recorder v18 export.

The five input files are discovered from a common prefix ending before
``_summary.csv``.  The script intentionally uses the Python standard library
and keeps only compact per-good/per-building/per-cohort aggregates in memory.

Example:
    python tools/analysis/analyze_economy_record_v18.py \
      --prefix tmp/economy_record_20260722_151716_v18_cell620_q15_r10
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

Q16 = 65_536
MONEY_SCALE = 10_000
GOODS_SCALE = 1_000
KINDS = ("summary", "cohorts", "market", "resources", "buildings")


def number(value: Any, default: float = 0) -> float:
    if value in (None, ""):
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def integer(value: Any, default: int = 0) -> int:
    return int(number(value, default))


def ratio(num: float, den: float) -> float | None:
    return num / den if den else None


def pct(value: float | None) -> str:
    return "—" if value is None else f"{value * 100:.1f}%"


def q16_pct(value: float) -> str:
    return pct(value / Q16)


def fmt(value: float | int) -> str:
    return f"{value:,.0f}"


def rows(path: Path) -> Iterable[dict[str, str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        yield from csv.DictReader(handle)


def catalog_index(directory: Path) -> dict[int, dict[str, str]]:
    items: list[dict[str, str]] = []
    id_pattern = re.compile(r'^id\s*=\s*&?"([^"]+)"', re.MULTILINE)
    name_pattern = re.compile(r'^display_name\s*=\s*"([^"]*)"', re.MULTILINE)
    if not directory.is_dir():
        return {}
    for path in directory.glob("*.tres"):
        text = path.read_text(encoding="utf-8", errors="ignore")
        match = id_pattern.search(text)
        if not match:
            continue
        display = name_pattern.search(text)
        items.append({
            "id": match.group(1),
            "display_name": display.group(1) if display else "",
        })
    items.sort(key=lambda item: item["id"])
    return dict(enumerate(items))


@dataclass
class Window:
    rows: int = 0
    sums: dict[str, float] = field(default_factory=lambda: defaultdict(float))

    def add(self, row: dict[str, str], names: Iterable[str]) -> None:
        self.rows += 1
        for name in names:
            self.sums[name] += number(row.get(name))

    def average(self, name: str) -> float:
        return self.sums[name] / self.rows if self.rows else 0


def analyze_summary(path: Path) -> dict[str, Any]:
    data = list(rows(path))
    if not data:
        raise ValueError(f"empty summary file: {path}")
    audits = {
        name: max(abs(integer(row.get(name))) for row in data)
        for name in ("population_error", "money_error", "goods_error")
    }
    sums = {
        name: sum(integer(row.get(name)) for row in data)
        for name in (
            "births", "deaths", "producer_revenue", "production_output_stock",
            "production_output_discarded", "production_output_retained",
            "building_wages_paid", "building_wages_unpaid",
            "recovery_candidates", "recovery_approved", "recovery_restarted",
            "recovery_failed", "recovery_liquidated_buildings",
            "building_investments_started", "building_owner_job_reallocations",
        )
    }
    first, last = data[0], data[-1]
    first_day = integer(first["day_index"])
    annual_rows: dict[int, list[dict[str, str]]] = defaultdict(list)
    for row in data:
        annual_rows[(integer(row["day_index"]) - first_day) // 365].append(row)
    annual = []
    for year, year_rows in sorted(annual_rows.items()):
        year_first, year_last = year_rows[0], year_rows[-1]
        annual.append({
            "year": year,
            "day_first": integer(year_first["day_index"]),
            "day_last": integer(year_last["day_index"]),
            **{
                name: sum(integer(row.get(name)) for row in year_rows)
                for name in (
                    "births", "deaths", "recovery_liquidated_buildings",
                    "recovery_restarted", "building_investments_started",
                    "building_owner_job_reallocations",
                )
            },
            "filled_owner_jobs_first": integer(year_first["filled_owner_jobs"]),
            "filled_owner_jobs_last": integer(year_last["filled_owner_jobs"]),
            "building_groups_first": integer(year_first["building_group_count"]),
            "building_groups_last": integer(year_last["building_group_count"]),
            "suspended_groups_last": integer(year_last["loss_suspended_building_groups"]),
        })
    return {
        "rows": len(data),
        "day_first": integer(first["day_index"]),
        "day_last": integer(last["day_index"]),
        "epoch_first": integer(first["epoch_id"]),
        "epoch_last": integer(last["epoch_id"]),
        "audits_max_abs": audits,
        "totals": sums,
        "first_last": {
            name: [integer(first.get(name)), integer(last.get(name))]
            for name in (
                "cohort_count", "filled_owner_jobs", "filled_employee_jobs",
                "unemployed_population", "building_group_count",
                "loss_suspended_building_groups", "merchant_credit_outstanding",
                "unfunded_business_demand",
            )
        },
        "maxima": {
            name: max(integer(row.get(name)) for row in data)
            for name in (
                "unemployed_population", "loss_suspended_building_groups",
                "merchant_credit_outstanding", "unfunded_business_demand",
            )
        },
        "annual": annual,
    }


def analyze_cohorts(
    path: Path,
    professions: dict[int, dict[str, str]],
    needs: dict[int, dict[str, str]],
) -> dict[str, Any]:
    by_day: dict[int, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    by_signature: dict[int, dict[str, Any]] = {}
    row_count = 0
    for row in rows(path):
        row_count += 1
        day = integer(row["day_index"])
        population = integer(row["population"])
        daily = by_day[day]
        daily["population"] += population
        daily["funds"] += integer(row["funds"])
        daily["income"] += integer(row["epoch_income"])
        daily["expense"] += integer(row["epoch_expense"])
        daily["in_kind"] += integer(row.get("epoch_in_kind_income"))
        daily["unemployed"] += integer(row["unemployed"])
        daily["owner"] += integer(row["owner_employed"])
        daily["employee"] += integer(row["employee_employed"])
        daily["satisfaction_population"] += population
        daily["satisfaction_weighted"] += population * integer(row["satisfaction_q16"])

        signature = integer(row["signature_id"])
        snapshot = {
            "day": day,
            "population": population,
            "funds": integer(row["funds"]),
            "income": integer(row["epoch_income"]),
            "expense": integer(row["epoch_expense"]),
            "in_kind_income": integer(row.get("epoch_in_kind_income")),
            "cash_coverage_q16": integer(row.get("cash_expense_coverage_q16")),
            "livelihood_coverage_q16": integer(row.get("livelihood_coverage_q16")),
            "satisfaction_q16": integer(row["satisfaction_q16"]),
            "worst_need_id": integer(row["worst_need_id"], -1),
            "unemployed": integer(row["unemployed"]),
            "owner": integer(row["owner_employed"]),
            "employee": integer(row["employee_employed"]),
        }
        state = by_signature.setdefault(signature, {
            "signature_id": signature,
            "profession_id": integer(row["profession_id"]),
            "first": snapshot,
            "last": snapshot,
            "min_satisfaction_q16": snapshot["satisfaction_q16"],
            "min_livelihood_coverage_q16": snapshot["livelihood_coverage_q16"],
            "first_low_livelihood_day": None,
            "first_population_loss_day": None,
        })
        previous = state["last"]
        if state["first_low_livelihood_day"] is None and snapshot["livelihood_coverage_q16"] < Q16:
            state["first_low_livelihood_day"] = day
        if state["first_population_loss_day"] is None and snapshot["population"] < previous["population"]:
            state["first_population_loss_day"] = day
        state["last"] = snapshot
        state["min_satisfaction_q16"] = min(
            state["min_satisfaction_q16"], snapshot["satisfaction_q16"])
        state["min_livelihood_coverage_q16"] = min(
            state["min_livelihood_coverage_q16"], snapshot["livelihood_coverage_q16"])

    days = sorted(by_day)
    day_series = []
    for day in days:
        item = dict(by_day[day])
        item["day"] = day
        item["weighted_satisfaction_q16"] = (
            item["satisfaction_weighted"] / item["satisfaction_population"]
            if item["satisfaction_population"] else 0
        )
        day_series.append(item)

    signatures = []
    for state in by_signature.values():
        profession_id = state["profession_id"]
        state["profession"] = professions.get(profession_id, {}).get("id", str(profession_id))
        worst = state["last"]["worst_need_id"]
        state["final_worst_need"] = needs.get(worst, {}).get("id", str(worst))
        state["population_delta"] = state["last"]["population"] - state["first"]["population"]
        signatures.append(state)
    signatures.sort(key=lambda item: (item["population_delta"], item["profession"]))
    return {
        "rows": row_count,
        "day_series": day_series,
        "signatures": signatures,
        "first": day_series[0] if day_series else {},
        "last": day_series[-1] if day_series else {},
    }


def analyze_market(path: Path, start_day: int, end_day: int) -> dict[str, Any]:
    fields = (
        "stock", "price", "demand_ema", "business_demand_ema",
        "offered_supply_ema", "realized_withdrawal_ema",
        "merchant_inventory_target", "merchant_procurement_shortfall",
        "cost_anchor_price", "shortage_q16", "price_pressure_total_q16",
        "desired_business_demand", "funded_business_demand",
        "unfunded_business_demand", "trade_import_ema", "trade_export_ema",
    )
    early_end = min(end_day, start_day + 180)
    late_start = max(start_day, end_day - 180)
    goods: dict[str, dict[str, Any]] = {}
    row_count = 0
    for row in rows(path):
        row_count += 1
        good = row["good_id"]
        day = integer(row["day_index"])
        snapshot = {name: number(row.get(name)) for name in fields}
        state = goods.setdefault(good, {
            "good_id": good,
            "first": {"day": day, **snapshot},
            "last": {"day": day, **snapshot},
            "early": Window(),
            "late": Window(),
            "active_rows": 0,
            "price_one_rows": 0,
            "shortage_rows": 0,
            "max_price": snapshot["price"],
            "min_price": snapshot["price"],
            "max_shortage_q16": snapshot["shortage_q16"],
        })
        state["last"] = {"day": day, **snapshot}
        state["max_price"] = max(state["max_price"], snapshot["price"])
        state["min_price"] = min(state["min_price"], snapshot["price"])
        state["max_shortage_q16"] = max(state["max_shortage_q16"], snapshot["shortage_q16"])
        active = (
            snapshot["stock"] > 0 or snapshot["demand_ema"] > 0 or
            snapshot["business_demand_ema"] > 0 or snapshot["offered_supply_ema"] > 0
        )
        if active:
            state["active_rows"] += 1
            state["price_one_rows"] += snapshot["price"] <= 1
        state["shortage_rows"] += snapshot["shortage_q16"] > 0
        if day <= early_end:
            state["early"].add(row, fields)
        if day >= late_start:
            state["late"].add(row, fields)

    output = []
    for state in goods.values():
        early: Window = state.pop("early")
        late: Window = state.pop("late")
        state["early_avg"] = {name: early.average(name) for name in fields}
        state["late_avg"] = {name: late.average(name) for name in fields}
        state["active_price_one_share"] = ratio(state["price_one_rows"], state["active_rows"])
        state["shortage_share"] = ratio(state["shortage_rows"], max(early.rows, late.rows, 1))
        state["price_change_ratio"] = ratio(state["last"]["price"], state["first"]["price"])
        output.append(state)
    output.sort(key=lambda item: (
        item["active_price_one_share"] or 0,
        item["late_avg"]["shortage_q16"],
        item["late_avg"]["demand_ema"] + item["late_avg"]["business_demand_ema"],
    ), reverse=True)
    return {"rows": row_count, "goods": output}


def analyze_buildings(
    path: Path, building_types: dict[int, dict[str, str]],
    start_day: int, end_day: int,
) -> dict[str, Any]:
    flow_fields = (
        "last_input", "last_output", "last_sold", "last_discarded", "last_retained",
        "last_revenue", "last_input_cost", "last_base_wages_due",
        "owner_livelihood_required", "viability_operating_cost", "viability_income_gap",
    )
    state_fields = (
        "count", "filled_owner", "employee_filled", "planned_utilization_q16",
        "realized_profit_margin_q16", "severe_loss_cycles", "operating_state",
        "last_in_kind_livelihood_value",
    )
    early_end = min(end_day, start_day + 180)
    late_start = max(start_day, end_day - 180)
    per_type_day: dict[tuple[int, int], dict[str, float]] = defaultdict(lambda: defaultdict(float))
    candidate_rows = construction_rows = actual_rows = 0
    for row in rows(path):
        if integer(row.get("investment_candidate")):
            candidate_rows += 1
            continue
        if integer(row.get("is_construction")):
            construction_rows += 1
            continue
        if integer(row.get("group_index"), -1) < 0:
            continue
        actual_rows += 1
        type_id = integer(row["type_id"])
        day = integer(row["day_index"])
        daily = per_type_day[(type_id, day)]
        for name in flow_fields:
            daily[name] += number(row.get(name))
        for name in state_fields:
            value = number(row.get(name))
            if name in ("planned_utilization_q16", "realized_profit_margin_q16"):
                daily[name + "_weighted"] += value * max(1, integer(row.get("count")))
                daily[name + "_weight"] += max(1, integer(row.get("count")))
            elif name in ("severe_loss_cycles", "operating_state"):
                daily[name] = max(daily[name], value)
            else:
                daily[name] += value
        daily["suspended_groups"] += integer(row.get("operating_state")) == 1
        daily["recovery_groups"] += integer(row.get("operating_state")) == 2

    series_by_type: dict[int, list[dict[str, float]]] = defaultdict(list)
    for (type_id, day), daily in per_type_day.items():
        for name in ("planned_utilization_q16", "realized_profit_margin_q16"):
            daily[name] = ratio(daily[name + "_weighted"], daily[name + "_weight"]) or 0
            daily.pop(name + "_weighted", None)
            daily.pop(name + "_weight", None)
        daily["day"] = day
        series_by_type[type_id].append(dict(daily))

    output = []
    for type_id, series in series_by_type.items():
        series.sort(key=lambda item: item["day"])
        early = [item for item in series if item["day"] <= early_end]
        late = [item for item in series if item["day"] >= late_start]

        def total(items: list[dict[str, float]], name: str) -> float:
            return sum(item.get(name, 0) for item in items)

        viability = total(series, "viability_operating_cost")
        revenue = total(series, "last_revenue")
        livelihood = total(series, "owner_livelihood_required")
        in_kind = total(series, "last_in_kind_livelihood_value")
        output_qty = total(series, "last_output")
        sold = total(series, "last_sold")
        discarded = total(series, "last_discarded")
        last = series[-1]
        output.append({
            "type_id": type_id,
            "building": building_types.get(type_id, {}).get("id", str(type_id)),
            "first": series[0],
            "last": last,
            "revenue_total": revenue,
            "viability_cost_total": viability,
            "viability_coverage": ratio(revenue, viability),
            "livelihood_coverage": ratio(revenue + in_kind, livelihood),
            "sell_through": ratio(sold, output_qty),
            "discard_share": ratio(discarded, output_qty),
            "avg_utilization_early_q16": ratio(total(early, "planned_utilization_q16"), len(early)) or 0,
            "avg_utilization_late_q16": ratio(total(late, "planned_utilization_q16"), len(late)) or 0,
            "avg_margin_late_q16": ratio(total(late, "realized_profit_margin_q16"), len(late)) or 0,
            "first_suspended_day": next((item["day"] for item in series if item["suspended_groups"]), None),
            "first_recovery_day": next((item["day"] for item in series if item["recovery_groups"]), None),
            "suspended_at_end": last["suspended_groups"],
            "recovery_at_end": last["recovery_groups"],
        })
    output.sort(key=lambda item: (
        item["livelihood_coverage"] if item["livelihood_coverage"] is not None else math.inf,
        item["viability_coverage"] if item["viability_coverage"] is not None else math.inf,
    ))
    return {
        "actual_rows": actual_rows,
        "candidate_rows": candidate_rows,
        "construction_rows": construction_rows,
        "types": output,
    }


def analyze_resources(path: Path, start_day: int, end_day: int) -> dict[str, Any]:
    by_resource: dict[str, dict[str, Any]] = {}
    row_count = 0
    for row in rows(path):
        row_count += 1
        resource = row["resource_id"]
        reserve = number(row["reserve"])
        state = by_resource.setdefault(resource, {
            "resource_id": resource,
            "first_day": integer(row["day_index"]),
            "last_day": integer(row["day_index"]),
            "first_reserve": reserve,
            "last_reserve": reserve,
            "min_reserve": reserve,
            "natural_positive": 0.0,
            "natural_negative": 0.0,
            "artificial_generation": 0.0,
            "artificial_extraction": 0.0,
        })
        state["last_day"] = integer(row["day_index"])
        state["last_reserve"] = reserve
        state["min_reserve"] = min(state["min_reserve"], reserve)
        state["natural_positive"] += number(row.get("natural_positive_change"))
        state["natural_negative"] += number(row.get("natural_negative_change"))
        state["artificial_generation"] += number(row.get("artificial_generation_applied"))
        state["artificial_extraction"] += number(row.get("artificial_extraction_applied"))
    output = []
    for state in by_resource.values():
        state["reserve_delta"] = state["last_reserve"] - state["first_reserve"]
        replacement = state["natural_positive"] + state["artificial_generation"]
        depletion = state["natural_negative"] + state["artificial_extraction"]
        state["replacement_ratio"] = ratio(replacement, depletion)
        output.append(state)
    output.sort(key=lambda item: item["reserve_delta"])
    return {"rows": row_count, "resources": output}


def report_markdown(metrics: dict[str, Any], prefix: Path) -> str:
    summary = metrics["summary"]
    cohorts = metrics["cohorts"]
    market = metrics["market"]["goods"]
    buildings = metrics["buildings"]["types"]
    resources = metrics["resources"]["resources"]
    first_pop = cohorts["first"].get("population", 0)
    last_pop = cohorts["last"].get("population", 0)
    births = summary["totals"]["births"]
    deaths = summary["totals"]["deaths"]
    audits = summary["audits_max_abs"]

    active_market = [item for item in market if item["active_rows"] > 0]
    price_floor = [item for item in active_market if (item["active_price_one_share"] or 0) > 0]
    building_problem = [
        item for item in buildings
        if (item["livelihood_coverage"] is not None and item["livelihood_coverage"] < 1)
        or item["suspended_at_end"] or item["recovery_at_end"]
    ]
    cohort_losers = [item for item in cohorts["signatures"] if item["population_delta"] < 0]
    resource_declines = [item for item in resources if item["reserve_delta"] < 0]

    lines = [
        f"# Economy recorder v18 analysis — `{prefix.name}`",
        "",
        "## Executive summary",
        "",
        f"- Horizon: day {summary['day_first']} → {summary['day_last']} "
        f"({summary['rows']} committed records).",
        f"- Selected-cell population: {fmt(first_pop)} → {fmt(last_pop)} "
        f"({fmt(last_pop-first_pop)}). Global births/deaths recorded: {fmt(births)} / {fmt(deaths)} "
        f"(net {fmt(births-deaths)}).",
        f"- Exact audit maxima: population={audits['population_error']}, "
        f"money={audits['money_error']}, goods={audits['goods_error']}.",
        f"- Active goods touching price 1: {len(price_floor)} / {len(active_market)}.",
        f"- Building types below owner-livelihood coverage or ending suspended/recovery: "
        f"{len(building_problem)} / {len(buildings)}.",
        f"- Lifecycle churn: {fmt(summary['totals']['recovery_liquidated_buildings'])} buildings "
        f"liquidated, {fmt(summary['totals']['building_investments_started'])} investments started, "
        f"and {fmt(summary['totals']['recovery_restarted'])} recovery restarts.",
        "",
        "## Global yearly dynamics",
        "",
        "| Year | Days | Births | Deaths | Net | Owner jobs first→last | Building groups first→last | Liquidated | Invested | Suspended end |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for item in summary["annual"]:
        lines.append(
            f"| {item['year']} | {item['day_first']}–{item['day_last']} "
            f"| {fmt(item['births'])} | {fmt(item['deaths'])} "
            f"| {fmt(item['births']-item['deaths'])} "
            f"| {fmt(item['filled_owner_jobs_first'])}→{fmt(item['filled_owner_jobs_last'])} "
            f"| {fmt(item['building_groups_first'])}→{fmt(item['building_groups_last'])} "
            f"| {fmt(item['recovery_liquidated_buildings'])} "
            f"| {fmt(item['building_investments_started'])} "
            f"| {fmt(item['suspended_groups_last'])} |"
        )
    lines += [
        "",
        "## Population and cohorts",
        "",
        "| Profession | Population first→last | Δ | Min livelihood coverage | Min satisfaction | Final worst need | First loss day |",
        "|---|---:|---:|---:|---:|---|---:|",
    ]
    for item in cohort_losers[:20]:
        lines.append(
            f"| {item['profession']} | {fmt(item['first']['population'])}→{fmt(item['last']['population'])} "
            f"| {fmt(item['population_delta'])} | {q16_pct(item['min_livelihood_coverage_q16'])} "
            f"| {q16_pct(item['min_satisfaction_q16'])} | {item['final_worst_need']} "
            f"| {item['first_population_loss_day'] if item['first_population_loss_day'] is not None else '—'} |"
        )

    lines += [
        "",
        "## Building viability",
        "",
        "| Building | Revenue/viability cost | Owner livelihood coverage | Sell-through | Discard | Util early→late | Margin late | State end | First suspended |",
        "|---|---:|---:|---:|---:|---:|---:|---|---:|",
    ]
    for item in building_problem[:30]:
        state = "suspended" if item["suspended_at_end"] else (
            "recovery" if item["recovery_at_end"] else "active")
        lines.append(
            f"| {item['building']} | {pct(item['viability_coverage'])} "
            f"| {pct(item['livelihood_coverage'])} | {pct(item['sell_through'])} "
            f"| {pct(item['discard_share'])} | {q16_pct(item['avg_utilization_early_q16'])}→{q16_pct(item['avg_utilization_late_q16'])} "
            f"| {q16_pct(item['avg_margin_late_q16'])} | {state} "
            f"| {item['first_suspended_day'] if item['first_suspended_day'] is not None else '—'} |"
        )

    target_buildings = [
        item for item in buildings
        if any(token in item["building"] for token in ("knapping", "weaving", "loom"))
    ]
    if target_buildings:
        lines += [
            "",
            "### Artisan target buildings",
            "",
            "| Building | Owner livelihood coverage | Revenue/viability | Util early→late | Margin late | First suspended | State end |",
            "|---|---:|---:|---:|---:|---:|---|",
        ]
        for item in target_buildings:
            state = "suspended" if item["suspended_at_end"] else (
                "recovery" if item["recovery_at_end"] else "active")
            lines.append(
                f"| {item['building']} | {pct(item['livelihood_coverage'])} "
                f"| {pct(item['viability_coverage'])} "
                f"| {q16_pct(item['avg_utilization_early_q16'])}→{q16_pct(item['avg_utilization_late_q16'])} "
                f"| {q16_pct(item['avg_margin_late_q16'])} "
                f"| {item['first_suspended_day'] if item['first_suspended_day'] is not None else '—'} "
                f"| {state} |"
            )

    lines += [
        "",
        "## Market stress",
        "",
        "| Good | Price first→last | Price=1 share while active | Late shortage | Late demand | Late business demand | Late stock | Cost anchor last |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    market_focus = sorted(active_market, key=lambda item: (
        item["active_price_one_share"] or 0,
        item["late_avg"]["shortage_q16"],
        item["late_avg"]["demand_ema"] + item["late_avg"]["business_demand_ema"],
    ), reverse=True)
    for item in market_focus[:30]:
        lines.append(
            f"| {item['good_id']} | {fmt(item['first']['price'])}→{fmt(item['last']['price'])} "
            f"| {pct(item['active_price_one_share'])} | {q16_pct(item['late_avg']['shortage_q16'])} "
            f"| {fmt(item['late_avg']['demand_ema'])} | {fmt(item['late_avg']['business_demand_ema'])} "
            f"| {fmt(item['late_avg']['stock'])} | {fmt(item['last']['cost_anchor_price'])} |"
        )

    lines += [
        "",
        "## Resource stock-flow",
        "",
        "| Resource | Reserve first→last | Δ | Natural + | Natural - | Extraction | Replacement ratio |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for item in resource_declines[:20]:
        lines.append(
            f"| {item['resource_id']} | {fmt(item['first_reserve'])}→{fmt(item['last_reserve'])} "
            f"| {fmt(item['reserve_delta'])} | {fmt(item['natural_positive'])} "
            f"| {fmt(item['natural_negative'])} | {fmt(item['artificial_extraction'])} "
            f"| {item['replacement_ratio']:.2f}" if item["replacement_ratio"] is not None else
            f"| {item['resource_id']} | {fmt(item['first_reserve'])}→{fmt(item['last_reserve'])} "
            f"| {fmt(item['reserve_delta'])} | {fmt(item['natural_positive'])} "
            f"| {fmt(item['natural_negative'])} | {fmt(item['artificial_extraction'])} | — |"
        )
        if item["replacement_ratio"] is not None:
            lines[-1] += " |"

    lines += [
        "",
        "## Recorder scope",
        "",
        "- Summary rows are global runtime aggregates; cohort, market, building, and resource rows describe the selected cell.",
        "- Early/late windows are the first/last 180 simulation days.",
        "- Money, goods, and Q16 values remain in recorder integer units unless shown as percentages.",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path,
                        help="common path before _summary.csv")
    parser.add_argument("--output-dir", type=Path,
                        help="defaults to the prefix directory")
    parser.add_argument("--repo-root", type=Path,
                        help="defaults to two parents above this script")
    args = parser.parse_args()

    repo_root = (args.repo_root or Path(__file__).resolve().parents[2]).resolve()
    prefix = args.prefix
    if not prefix.is_absolute():
        prefix = (repo_root / prefix).resolve()
    paths = {kind: Path(f"{prefix}_{kind}.csv") for kind in KINDS}
    missing = [str(path) for path in paths.values() if not path.is_file()]
    if missing:
        parser.error("missing recorder files: " + ", ".join(missing))

    data_root = repo_root / "Project" / "project-keynes" / "data" / "economy"
    professions = catalog_index(data_root / "professions")
    needs = catalog_index(data_root / "needs")
    building_types = catalog_index(data_root / "buildings")

    summary = analyze_summary(paths["summary"])
    metrics = {
        "record_prefix": str(prefix),
        "summary": summary,
        "cohorts": analyze_cohorts(paths["cohorts"], professions, needs),
        "market": analyze_market(paths["market"], summary["day_first"], summary["day_last"]),
        "buildings": analyze_buildings(
            paths["buildings"], building_types,
            summary["day_first"], summary["day_last"]),
        "resources": analyze_resources(
            paths["resources"], summary["day_first"], summary["day_last"]),
    }

    output_dir = (args.output_dir or prefix.parent).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / f"{prefix.name}_analysis.json"
    report_path = output_dir / f"{prefix.name}_analysis.md"
    json_path.write_text(json.dumps(metrics, ensure_ascii=False, indent=2), encoding="utf-8")
    report_path.write_text(report_markdown(metrics, prefix), encoding="utf-8")
    print(json.dumps({
        "json": str(json_path),
        "report": str(report_path),
        "rows": {
            "summary": metrics["summary"]["rows"],
            "cohorts": metrics["cohorts"]["rows"],
            "market": metrics["market"]["rows"],
            "buildings": metrics["buildings"]["actual_rows"],
            "resources": metrics["resources"]["rows"],
        },
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
