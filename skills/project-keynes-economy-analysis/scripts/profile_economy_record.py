#!/usr/bin/env python3
"""Stream-profile a Project.Keynes economy recorder CSV family.

The output is a compact JSON evidence index. It intentionally avoids treating
correlation or heuristic warning signals as a final diagnosis.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Any, Callable, Iterable


Q16 = 65_536
KINDS = ("summary", "cohorts", "market", "resources", "buildings")
CORE_COLUMNS = {
    "summary": ("epoch_row_id", "epoch_id", "day_index"),
    "cohorts": (
        "epoch_row_id", "day_index", "cell_idx", "signature_id",
        "population", "funds",
    ),
    "market": ("epoch_row_id", "day_index", "cell_idx", "good_id"),
    "resources": ("epoch_row_id", "day_index", "cell_idx", "resource_id"),
    "buildings": (
        "epoch_row_id", "day_index", "cell_idx", "group_index", "type_id",
    ),
}
PRIMARY_KEYS = {
    "summary": ("epoch_row_id",),
    "cohorts": ("epoch_row_id", "cell_idx", "cohort_index"),
    "market": ("epoch_row_id", "cell_idx", "good_id"),
    "resources": ("epoch_row_id", "cell_idx", "resource_id"),
    "buildings": (
        "epoch_row_id", "cell_idx", "is_construction", "group_index",
        "type_id", "owner_signature_id", "investment_candidate",
    ),
}

SUMMARY_FIELDS = (
    "cohort_count", "building_group_count", "pending_construction_count",
    "filled_owner_jobs", "filled_employee_jobs", "unemployed_population",
    "births", "deaths", "production_inputs_consumed",
    "production_output_stock", "production_output_discarded",
    "production_output_retained", "production_output_supported",
    "producer_revenue", "producer_support_money_issued",
    "bullion_money_issued", "building_wages_paid", "building_wages_unpaid",
    "building_resource_generated", "building_resource_consumed",
    "loss_suspended_building_groups", "merchant_procurement_budget",
    "merchant_procurement_opportunity", "merchant_procurement_spent",
    "owner_working_capital_reserved", "production_input_reserved",
    "production_input_reserve_shortfall", "desired_business_demand",
    "funded_business_demand", "unfunded_business_demand",
    "trade_source_signals", "trade_destination_signals",
    "trade_ready_candidates", "trade_candidates_generated",
    "trade_candidates_accepted", "trade_orders_in_flight",
    "trade_orders_dispatched", "trade_orders_arrived",
    "trade_capacity_available", "trade_capacity_used",
    "merchant_credit_outstanding", "merchant_credit_bad_debt",
    "recovery_restarted", "recovery_failed",
    "recovery_liquidated_buildings", "building_investments_started",
    "merchant_cash", "merchant_economic_assets",
    "merchant_operating_outflow", "merchant_liquidity_coverage_q16",
    "population_error", "money_error", "goods_error",
)
SUMMARY_FLOWS = {
    "births", "deaths", "production_inputs_consumed",
    "production_output_stock", "production_output_discarded",
    "production_output_retained", "production_output_supported",
    "producer_revenue", "producer_support_money_issued",
    "bullion_money_issued", "building_wages_paid", "building_wages_unpaid",
    "building_resource_generated", "building_resource_consumed",
    "merchant_procurement_spent", "trade_candidates_generated",
    "trade_candidates_accepted", "trade_orders_dispatched",
    "trade_orders_arrived", "merchant_credit_bad_debt",
    "recovery_restarted", "recovery_failed",
    "recovery_liquidated_buildings", "building_investments_started",
}
MARKET_SUM_FIELDS = (
    "stock", "demand_ema", "business_demand_ema", "offered_supply_ema",
    "realized_withdrawal_ema", "production_input_reserve",
    "household_available_stock", "merchant_inventory_target",
    "merchant_procurement_shortfall", "desired_business_demand",
    "funded_business_demand", "unfunded_business_demand",
    "trade_import_ema", "trade_export_ema", "trade_inbound", "trade_outbound",
)
MARKET_ENTITY_FIELDS = MARKET_SUM_FIELDS + (
    "price", "cost_anchor_price", "shortage_q16", "price_pressure_total_q16",
)
BUILDING_FLOW_FIELDS = (
    "last_input", "last_output", "last_sold", "last_discarded",
    "last_retained", "last_resource", "last_resource_generated",
    "last_revenue", "last_input_cost", "last_wages_paid", "last_wages_due",
    "last_base_wages_paid", "last_base_wages_due", "last_bonus_paid",
    "last_bonus_due", "owner_livelihood_required", "viability_operating_cost",
    "viability_income_gap", "owner_working_capital_allocated",
    "merchant_debt_principal", "merchant_debt_premium",
)
RESOURCE_FLOW_FIELDS = (
    "natural_net_change", "natural_positive_change", "natural_negative_change",
    "artificial_change_applied", "artificial_change_pending",
    "artificial_generation_applied", "artificial_extraction_applied",
    "artificial_generation_pending", "artificial_extraction_pending",
)

CORRELATION_PRIORITY = (
    "summary.births", "summary.deaths", "summary.filled_owner_jobs",
    "summary.unemployed_population", "summary.production_output_stock",
    "summary.production_output_discarded", "summary.producer_revenue",
    "summary.building_wages_unpaid", "summary.loss_suspended_building_groups",
    "summary.unfunded_business_demand", "summary.trade_orders_dispatched",
    "summary.trade_orders_arrived", "summary.merchant_credit_outstanding",
    "summary.recovery_liquidated_buildings", "summary.building_investments_started",
    "cohorts.population", "cohorts.funds_per_capita", "cohorts.income",
    "cohorts.expense", "cohorts.in_kind_income", "cohorts.owner",
    "cohorts.unemployed", "cohorts.satisfaction_q16",
    "cohorts.livelihood_coverage_q16", "cohorts.merchant_population",
    "cohorts.merchant_funds_share", "market.stock", "market.demand_ema",
    "market.business_demand_ema", "market.offered_supply_ema",
    "market.realized_withdrawal_ema", "market.production_input_reserve",
    "market.household_available_stock", "market.merchant_procurement_shortfall",
    "market.unfunded_business_demand", "market.shortage_goods",
    "market.severe_shortage_goods", "market.stockout_active_goods",
    "market.avg_shortage_q16", "market.merchant_cash",
    "market.merchant_economic_assets", "market.merchant_liquidity_coverage_q16",
    "market.merchant_effective_buy_factor_q16", "buildings.groups",
    "buildings.count", "buildings.suspended_groups", "buildings.recovery_groups",
    "buildings.owner_required", "buildings.filled_owner", "buildings.owner_openings",
    "buildings.last_input", "buildings.last_output", "buildings.last_sold",
    "buildings.last_discarded", "buildings.last_revenue",
    "buildings.last_wages_due", "buildings.viability_operating_cost",
    "buildings.merchant_debt_principal", "buildings.owner_fill_ratio",
    "buildings.sell_through", "buildings.planned_utilization_q16",
    "resources.natural_net_change", "resources.artificial_change_applied",
    "resources.artificial_change_pending", "resources.artificial_extraction_applied",
    "resources.artificial_extraction_pending", "resources.critical_life_count",
)
KNOWN_DIRECT_PROJECTIONS = {
    frozenset(("cohorts.owner", "buildings.filled_owner")),
    frozenset(("cohorts.merchant_funds", "market.merchant_cash")),
}


def number(value: Any) -> float | None:
    if value in (None, ""):
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def integer(value: Any, default: int = 0) -> int:
    parsed = number(value)
    return int(parsed) if parsed is not None else default


def safe_ratio(numerator: float, denominator: float) -> float | None:
    return numerator / denominator if denominator else None


def bool_value(value: Any) -> bool:
    return str(value).strip().lower() in {"1", "true", "yes"}


def normalize_prefix(value: Path) -> Path:
    text = str(value)
    for kind in KINDS:
        suffix = f"_{kind}.csv"
        if text.endswith(suffix):
            return Path(text[: -len(suffix)])
    return value


def filename_version(prefix: Path) -> int | None:
    match = re.search(r"(?:^|_)v(\d+)(?:_|$)", prefix.name)
    return int(match.group(1)) if match else None


def catalog_index(directory: Path) -> dict[int, str]:
    stable_ids: list[str] = []
    pattern = re.compile(r'^id\s*=\s*&?"([^"]+)"', re.MULTILINE)
    if not directory.is_dir():
        return {}
    for path in directory.glob("*.tres"):
        match = pattern.search(path.read_text(encoding="utf-8", errors="ignore"))
        if match:
            stable_ids.append(match.group(1))
    return dict(enumerate(sorted(stable_ids)))


class TableProfile:
    def __init__(self, kind: str, path: Path, headers: list[str]) -> None:
        self.kind = kind
        self.path = path
        self.headers = headers
        self.rows = 0
        self.bad_width_rows = 0
        self.blank_core_rows = 0
        self.duplicate_keys = 0
        self.order_regressions = 0
        self.days: set[int] = set()
        self.epochs: set[int] = set()
        self.cells: set[int] = set()
        self._keys: set[tuple[str, ...]] = set()
        self._last_epoch: int | None = None

    def observe(self, row: dict[str | None, Any]) -> None:
        self.rows += 1
        if None in row:
            self.bad_width_rows += 1
        core = CORE_COLUMNS[self.kind]
        if any(row.get(name) in (None, "") for name in core):
            self.blank_core_rows += 1
        day = integer(row.get("day_index"), -1)
        epoch = integer(row.get("epoch_row_id"), -1)
        if day >= 0:
            self.days.add(day)
        if epoch >= 0:
            self.epochs.add(epoch)
            if self._last_epoch is not None and epoch < self._last_epoch:
                self.order_regressions += 1
            self._last_epoch = epoch
        if "cell_idx" in row:
            cell = integer(row.get("cell_idx"), -1)
            if cell >= 0:
                self.cells.add(cell)
        key = tuple(str(row.get(name, "")) for name in PRIMARY_KEYS[self.kind])
        if key in self._keys:
            self.duplicate_keys += 1
        else:
            self._keys.add(key)

    def gaps(self) -> list[list[int]]:
        ordered = sorted(self.days)
        return [
            [left + 1, right - 1]
            for left, right in zip(ordered, ordered[1:])
            if right - left > 1
        ][:20]

    def public(self, summary_epochs: set[int] | None) -> dict[str, Any]:
        missing = [name for name in CORE_COLUMNS[self.kind] if name not in self.headers]
        extra_epochs = sorted(self.epochs - (summary_epochs or self.epochs))[:20]
        return {
            "path": str(self.path),
            "header_sha256_16": hashlib.sha256(
                ",".join(self.headers).encode("utf-8")
            ).hexdigest()[:16],
            "column_count": len(self.headers),
            "columns": self.headers,
            "rows": self.rows,
            "day_first": min(self.days) if self.days else None,
            "day_last": max(self.days) if self.days else None,
            "unique_days": len(self.days),
            "day_gaps": self.gaps(),
            "unique_epochs": len(self.epochs),
            "cells": sorted(self.cells),
            "missing_core_columns": missing,
            "blank_core_rows": self.blank_core_rows,
            "bad_width_rows": self.bad_width_rows,
            "duplicate_primary_keys": self.duplicate_keys,
            "epoch_order_regressions": self.order_regressions,
            "detail_epochs_not_in_summary": extra_epochs,
        }


def scan(
    kind: str,
    path: Path,
    callback: Callable[[dict[str | None, Any]], None],
) -> TableProfile:
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        headers = list(reader.fieldnames or [])
        profile = TableProfile(kind, path, headers)
        for row in reader:
            profile.observe(row)
            callback(row)
    return profile


def rankdata(values: list[float]) -> list[float]:
    order = sorted(range(len(values)), key=values.__getitem__)
    ranks = [0.0] * len(values)
    cursor = 0
    while cursor < len(order):
        end = cursor + 1
        while end < len(order) and values[order[end]] == values[order[cursor]]:
            end += 1
        rank = (cursor + end - 1) / 2.0 + 1.0
        for index in order[cursor:end]:
            ranks[index] = rank
        cursor = end
    return ranks


def pearson(left: list[float], right: list[float]) -> float | None:
    count = len(left)
    if count < 2:
        return None
    left_mean = sum(left) / count
    right_mean = sum(right) / count
    numerator = sum(
        (a - left_mean) * (b - right_mean) for a, b in zip(left, right)
    )
    left_ss = sum((value - left_mean) ** 2 for value in left)
    right_ss = sum((value - right_mean) ** 2 for value in right)
    denominator = math.sqrt(left_ss * right_ss)
    return numerator / denominator if denominator else None


def aligned(
    driver: dict[int, float],
    outcome: dict[int, float],
    lag_days: int = 0,
) -> tuple[list[float], list[float]]:
    driver_values: list[float] = []
    outcome_values: list[float] = []
    for day, outcome_value in outcome.items():
        driver_value = driver.get(day - lag_days)
        if driver_value is not None:
            driver_values.append(driver_value)
            outcome_values.append(outcome_value)
    return driver_values, outcome_values


def first_difference_per_day(series: dict[int, float]) -> dict[int, float]:
    output: dict[int, float] = {}
    previous_day: int | None = None
    previous_value = 0.0
    for day in sorted(series):
        value = series[day]
        if previous_day is not None and day > previous_day:
            output[day] = (value - previous_value) / (day - previous_day)
        previous_day = day
        previous_value = value
    return output


def correlation_report(
    series: dict[str, dict[int, float]],
    metadata: dict[str, dict[str, str]],
    minimum: int,
    top: int,
    max_series: int,
) -> dict[str, Any]:
    eligible = {name for name, values in series.items() if len(values) >= minimum}
    priority = [name for name in CORRELATION_PRIORITY if name in eligible]
    remaining = sorted(eligible - set(priority))
    names = (priority + remaining)[:max_series]
    differences = {name: first_difference_per_day(series[name]) for name in names}

    def candidates(
        source: dict[str, dict[int, float]],
        lags: Iterable[int],
        directional: bool,
    ) -> list[dict[str, Any]]:
        found: list[dict[str, Any]] = []
        for left_index, left_name in enumerate(names):
            for right_index, right_name in enumerate(names):
                if left_name == right_name:
                    continue
                if not directional and right_index <= left_index:
                    continue
                if frozenset((left_name, right_name)) in KNOWN_DIRECT_PROJECTIONS:
                    continue
                if metadata[left_name]["domain"] == metadata[right_name]["domain"]:
                    continue
                for lag in lags:
                    left_values, right_values = aligned(
                        source[left_name], source[right_name], lag
                    )
                    if len(left_values) < minimum:
                        continue
                    coefficient = pearson(left_values, right_values)
                    if coefficient is None:
                        continue
                    found.append({
                        "driver" if directional else "left": left_name,
                        "outcome" if directional else "right": right_name,
                        "lag_days": lag,
                        "samples": len(left_values),
                        "pearson": coefficient,
                        "mixed_scope": (
                            metadata[left_name]["scope"]
                            != metadata[right_name]["scope"]
                        ),
                    })
        found.sort(key=lambda item: abs(item["pearson"]), reverse=True)
        preselected = found[: max(top * 4, top)]
        for item in preselected:
            left_name = item.get("driver", item.get("left"))
            right_name = item.get("outcome", item.get("right"))
            left_values, right_values = aligned(
                source[left_name], source[right_name], item["lag_days"]
            )
            ranked = pearson(rankdata(left_values), rankdata(right_values))
            item["spearman"] = ranked
            item["score"] = min(
                abs(item["pearson"]), abs(ranked if ranked is not None else 0.0)
            )
        preselected.sort(key=lambda item: item["score"], reverse=True)
        return preselected[:top]

    level = candidates(series, (0,), False)
    change = candidates(differences, (0,), False)

    projection_checks: list[dict[str, Any]] = []
    for pair in KNOWN_DIRECT_PROJECTIONS:
        left_name, right_name = sorted(pair)
        if left_name not in series or right_name not in series:
            continue
        left_values, right_values = aligned(series[left_name], series[right_name])
        coefficient = pearson(left_values, right_values)
        projection_checks.append({
            "left": left_name,
            "right": right_name,
            "samples": len(left_values),
            "pearson": coefficient,
            "purpose": "alignment/projection validation; do not cite as causal evidence",
        })

    lagged: list[dict[str, Any]] = []
    for seed in change:
        left_name = seed["left"]
        right_name = seed["right"]
        for driver_name, outcome_name in (
            (left_name, right_name), (right_name, left_name)
        ):
            for lag in (1, 5, 30):
                driver_values, outcome_values = aligned(
                    differences[driver_name], differences[outcome_name], lag
                )
                if len(driver_values) < minimum:
                    continue
                coefficient = pearson(driver_values, outcome_values)
                if coefficient is None:
                    continue
                ranked = pearson(rankdata(driver_values), rankdata(outcome_values))
                lagged.append({
                    "driver": driver_name,
                    "outcome": outcome_name,
                    "lag_days": lag,
                    "samples": len(driver_values),
                    "pearson": coefficient,
                    "spearman": ranked,
                    "score": min(
                        abs(coefficient), abs(ranked if ranked is not None else 0.0)
                    ),
                    "mixed_scope": (
                        metadata[driver_name]["scope"]
                        != metadata[outcome_name]["scope"]
                    ),
                })
    lagged.sort(key=lambda item: item["score"], reverse=True)

    return {
        "method": (
            "Cross-domain Pearson candidates ranked by corroborating Spearman; "
            "first differences are per simulation day; lag scans seed from the "
            "strongest same-day first-difference pairs."
        ),
        "minimum_samples": minimum,
        "series_considered": names,
        "known_projection_checks": projection_checks,
        "top_level": level,
        "top_first_difference": change,
        "top_lagged_first_difference": lagged[:top],
        "cautions": [
            "Correlation is an investigation index, not a causal finding.",
            "mixed_scope=true combines global summary with sampled/local detail.",
            "Strong level-only correlations may be shared trends.",
            "Review algebraic dependencies and current runtime cadence before use.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--repo-root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--late-days", type=int, default=180)
    parser.add_argument("--min-correlation-samples", type=int, default=30)
    parser.add_argument("--max-correlation-series", type=int, default=64)
    parser.add_argument("--top", type=int, default=30)
    args = parser.parse_args()

    repo_root = (
        args.repo_root.resolve()
        if args.repo_root
        else Path(__file__).resolve().parents[4]
    )
    prefix = normalize_prefix(args.prefix)
    if not prefix.is_absolute():
        prefix = (repo_root / prefix).resolve()
    paths = {kind: Path(f"{prefix}_{kind}.csv") for kind in KINDS}
    if not paths["summary"].is_file():
        parser.error(f"summary CSV is required: {paths['summary']}")
    available = {kind: path for kind, path in paths.items() if path.is_file()}

    series: dict[str, dict[int, float]] = defaultdict(dict)
    series_metadata: dict[str, dict[str, str]] = {}
    profiles: dict[str, TableProfile] = {}

    def set_series(
        name: str,
        day: int,
        value: float | None,
        domain: str,
        scope: str,
        semantic: str,
    ) -> None:
        if day < 0 or value is None:
            return
        series[name][day] = value
        series_metadata[name] = {
            "domain": domain,
            "scope": scope,
            "semantic": semantic,
        }

    summary_first: dict[str, float] = {}
    summary_last: dict[str, float] = {}
    summary_totals: dict[str, float] = defaultdict(float)
    summary_audit_max = {name: 0.0 for name in (
        "population_error", "money_error", "goods_error"
    )}
    summary_categories: dict[str, set[str]] = defaultdict(set)

    def on_summary(row: dict[str | None, Any]) -> None:
        day = integer(row.get("day_index"), -1)
        for name in SUMMARY_FIELDS:
            value = number(row.get(name))
            if value is None:
                continue
            if name not in summary_first:
                summary_first[name] = value
            summary_last[name] = value
            if name in SUMMARY_FLOWS:
                summary_totals[name] += value
            if name in summary_audit_max:
                summary_audit_max[name] = max(summary_audit_max[name], abs(value))
            semantic = "flow" if name in SUMMARY_FLOWS else (
                "ratio" if name.endswith("_q16") else "state"
            )
            set_series(f"summary.{name}", day, value, "summary", "global", semantic)
        for name in ("stage", "trade_runtime_mode", "trade_plan_phase"):
            value = row.get(name)
            if value not in (None, ""):
                summary_categories[name].add(str(value))

    profiles["summary"] = scan("summary", paths["summary"], on_summary)
    day_first = min(profiles["summary"].days)
    day_last = max(profiles["summary"].days)
    late_start = max(day_first, day_last - max(1, args.late_days) + 1)

    data_root = repo_root / "Project" / "project-keynes" / "data" / "economy"
    profession_ids = catalog_index(data_root / "professions")
    need_ids = catalog_index(data_root / "needs")
    building_ids = catalog_index(data_root / "buildings")

    cohort_daily: dict[int, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    cohort_entities: dict[tuple[int, int], dict[str, Any]] = {}

    def on_cohort(row: dict[str | None, Any]) -> None:
        day = integer(row.get("day_index"), -1)
        cell = integer(row.get("cell_idx"), -1)
        signature = integer(row.get("signature_id"), -1)
        population = integer(row.get("population"))
        funds = number(row.get("funds")) or 0.0
        satisfaction = number(row.get("satisfaction_q16")) or 0.0
        livelihood = number(row.get("livelihood_coverage_q16")) or 0.0
        daily = cohort_daily[day]
        for source, target in (
            ("population", "population"), ("funds", "funds"),
            ("epoch_income", "income"), ("epoch_expense", "expense"),
            ("epoch_in_kind_income", "in_kind_income"),
            ("owner_employed", "owner"), ("employee_employed", "employee"),
            ("unemployed", "unemployed"),
        ):
            daily[target] += number(row.get(source)) or 0.0
        daily["satisfaction_weighted"] += satisfaction * population
        daily["livelihood_weighted"] += livelihood * population
        merchant = bool_value(row.get("is_merchant"))
        prefix_name = "merchant" if merchant else "nonmerchant"
        daily[f"{prefix_name}_population"] += population
        daily[f"{prefix_name}_funds"] += funds

        snapshot = {
            "day": day,
            "population": population,
            "funds": funds,
            "funds_per_capita": safe_ratio(funds, population),
            "epoch_income": number(row.get("epoch_income")) or 0.0,
            "epoch_expense": number(row.get("epoch_expense")) or 0.0,
            "livelihood_coverage_q16": livelihood,
            "satisfaction_q16": satisfaction,
            "worst_need_id": integer(row.get("worst_need_id"), -1),
            "unemployed": integer(row.get("unemployed")),
        }
        key = (cell, signature)
        state = cohort_entities.setdefault(key, {
            "cell_idx": cell,
            "signature_id": signature,
            "profession_id": integer(row.get("profession_id"), -1),
            "ethnicity_id": integer(row.get("ethnicity_id"), -1),
            "is_merchant": merchant,
            "first": snapshot,
            "last": snapshot,
            "min_satisfaction_q16": satisfaction,
            "min_livelihood_coverage_q16": livelihood,
        })
        if day < state["first"]["day"]:
            state["first"] = snapshot
        if day >= state["last"]["day"]:
            state["last"] = snapshot
        state["min_satisfaction_q16"] = min(
            state["min_satisfaction_q16"], satisfaction
        )
        state["min_livelihood_coverage_q16"] = min(
            state["min_livelihood_coverage_q16"], livelihood
        )

    if "cohorts" in available:
        profiles["cohorts"] = scan("cohorts", paths["cohorts"], on_cohort)
        for day, daily in cohort_daily.items():
            population = daily["population"]
            for name in (
                "population", "funds", "income", "expense", "in_kind_income",
                "owner", "employee", "unemployed", "merchant_population",
                "merchant_funds", "nonmerchant_population", "nonmerchant_funds",
            ):
                set_series(
                    f"cohorts.{name}", day, daily[name], "cohorts", "sampled",
                    "flow" if name in {"income", "expense", "in_kind_income"}
                    else "state",
                )
            for name, value in (
                ("funds_per_capita", safe_ratio(daily["funds"], population)),
                ("satisfaction_q16", safe_ratio(daily["satisfaction_weighted"], population)),
                ("livelihood_coverage_q16", safe_ratio(daily["livelihood_weighted"], population)),
                ("merchant_funds_share", safe_ratio(daily["merchant_funds"], daily["funds"])),
            ):
                set_series(
                    f"cohorts.{name}", day, value, "cohorts", "sampled",
                    "ratio" if name.endswith("share") or name.endswith("q16") else "state",
                )

    market_daily: dict[int, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    market_entities: dict[str, dict[str, Any]] = {}
    merchant_cell_day_seen: set[tuple[int, int]] = set()

    def on_market(row: dict[str | None, Any]) -> None:
        day = integer(row.get("day_index"), -1)
        cell = integer(row.get("cell_idx"), -1)
        good = str(row.get("good_id") or "")
        snapshot = {
            name: number(row.get(name)) or 0.0 for name in MARKET_ENTITY_FIELDS
        }
        active = any(snapshot[name] > 0 for name in (
            "stock", "demand_ema", "business_demand_ema", "offered_supply_ema",
            "realized_withdrawal_ema",
        ))
        daily = market_daily[day]
        for name in MARKET_SUM_FIELDS:
            daily[name] += snapshot[name]
        if active:
            daily["active_goods"] += 1
            daily["shortage_sum_q16"] += snapshot["shortage_q16"]
            if snapshot["shortage_q16"] > 0:
                daily["shortage_goods"] += 1
            if snapshot["shortage_q16"] >= Q16 / 2:
                daily["severe_shortage_goods"] += 1
            if snapshot["household_available_stock"] <= 0:
                daily["stockout_active_goods"] += 1

        merchant_key = (day, cell)
        if merchant_key not in merchant_cell_day_seen:
            merchant_cell_day_seen.add(merchant_key)
            daily["merchant_cells"] += 1
            for name in (
                "merchant_cash", "merchant_inventory_retail_value",
                "merchant_inventory_liquidation_value", "merchant_economic_assets",
                "merchant_procurement_margin_value", "merchant_trade_purchase_cash",
                "merchant_trade_sale_cash", "merchant_operating_outflow",
                "merchant_liquidity_coverage_q16", "merchant_effective_buy_factor_q16",
            ):
                daily[name] += number(row.get(name)) or 0.0

        state = market_entities.setdefault(good, {
            "good_id": good,
            "rows": 0,
            "active_rows": 0,
            "shortage_rows": 0,
            "severe_shortage_rows": 0,
            "sums": defaultdict(float),
            "late_sums": defaultdict(float),
            "late_rows": 0,
            "first": {"day": day, **snapshot},
            "last": {"day": day, **snapshot},
        })
        state["rows"] += 1
        if day < state["first"]["day"]:
            state["first"] = {"day": day, **snapshot}
        if day >= state["last"]["day"]:
            state["last"] = {"day": day, **snapshot}
        for name, value in snapshot.items():
            state["sums"][name] += value
            if day >= late_start:
                state["late_sums"][name] += value
        if day >= late_start:
            state["late_rows"] += 1
        if active:
            state["active_rows"] += 1
            state["shortage_rows"] += snapshot["shortage_q16"] > 0
            state["severe_shortage_rows"] += snapshot["shortage_q16"] >= Q16 / 2

    if "market" in available:
        profiles["market"] = scan("market", paths["market"], on_market)
        for day, daily in market_daily.items():
            for name in MARKET_SUM_FIELDS + (
                "active_goods", "shortage_goods", "severe_shortage_goods",
                "stockout_active_goods",
            ):
                semantic = "ema" if name.endswith("_ema") else (
                    "flow" if name in {"trade_inbound", "trade_outbound"} else "state"
                )
                set_series(
                    f"market.{name}", day, daily[name], "market", "sampled", semantic
                )
            set_series(
                "market.avg_shortage_q16", day,
                safe_ratio(daily["shortage_sum_q16"], daily["active_goods"]),
                "market", "sampled", "ratio",
            )
            cells = daily["merchant_cells"]
            for name in (
                "merchant_cash", "merchant_inventory_retail_value",
                "merchant_inventory_liquidation_value", "merchant_economic_assets",
                "merchant_procurement_margin_value", "merchant_trade_purchase_cash",
                "merchant_trade_sale_cash", "merchant_operating_outflow",
                "merchant_liquidity_coverage_q16", "merchant_effective_buy_factor_q16",
            ):
                set_series(
                    f"market.{name}", day, safe_ratio(daily[name], cells),
                    "market", "sampled", "ratio" if name.endswith("_q16") else "state",
                )

    building_days: dict[tuple[int, int], dict[str, float]] = defaultdict(
        lambda: defaultdict(float)
    )
    building_row_classes = defaultdict(int)
    investment_rejections = defaultdict(int)

    def on_building(row: dict[str | None, Any]) -> None:
        if bool_value(row.get("investment_candidate")):
            building_row_classes["candidate"] += 1
            investment_rejections[str(row.get("investment_rejection_reason") or "")] += 1
            return
        if bool_value(row.get("is_construction")):
            building_row_classes["construction"] += 1
            return
        if integer(row.get("group_index"), -1) < 0:
            building_row_classes["sentinel"] += 1
            return
        building_row_classes["actual"] += 1
        day = integer(row.get("day_index"), -1)
        type_id = integer(row.get("type_id"), -1)
        daily = building_days[(type_id, day)]
        daily["groups"] += 1
        count = max(0, integer(row.get("count")))
        daily["count"] += count
        for name in BUILDING_FLOW_FIELDS:
            daily[name] += number(row.get(name)) or 0.0
        for name in (
            "owner_capacity", "owner_required", "planned_owner_equivalent",
            "filled_owner", "owner_openings", "employee_required", "employee_filled",
        ):
            daily[name] += number(row.get(name)) or 0.0
        state = integer(row.get("operating_state"))
        daily["suspended_groups"] += state == 1
        daily["recovery_groups"] += state == 2
        weight = max(1, count)
        for name in (
            "planned_utilization_q16", "capacity_q16",
            "realized_profit_margin_q16",
        ):
            daily[f"{name}_weighted"] += (number(row.get(name)) or 0.0) * weight
            daily[f"{name}_weight"] += weight

    building_entities: list[dict[str, Any]] = []
    if "buildings" in available:
        profiles["buildings"] = scan("buildings", paths["buildings"], on_building)
        global_building_daily: dict[int, dict[str, float]] = defaultdict(
            lambda: defaultdict(float)
        )
        per_type: dict[int, list[dict[str, float]]] = defaultdict(list)
        for (type_id, day), daily in building_days.items():
            item = dict(daily)
            item["day"] = day
            for name in (
                "planned_utilization_q16", "capacity_q16",
                "realized_profit_margin_q16",
            ):
                item[name] = safe_ratio(
                    item.get(f"{name}_weighted", 0.0),
                    item.get(f"{name}_weight", 0.0),
                ) or 0.0
            per_type[type_id].append(item)
            target = global_building_daily[day]
            for name, value in item.items():
                if name != "day" and not name.endswith("_weight") and not name.endswith("_weighted"):
                    target[name] += value
            target["util_weighted"] += item["planned_utilization_q16"] * item["count"]
            target["util_weight"] += item["count"]

        for day, daily in global_building_daily.items():
            for name in (
                "groups", "count", "suspended_groups", "recovery_groups",
                "owner_required", "filled_owner", "owner_openings",
                "employee_required", "employee_filled", "last_input", "last_output",
                "last_sold", "last_discarded", "last_retained", "last_revenue",
                "last_input_cost", "last_wages_paid", "last_wages_due",
                "owner_livelihood_required", "viability_operating_cost",
                "merchant_debt_principal",
            ):
                set_series(
                    f"buildings.{name}", day, daily[name], "buildings", "sampled",
                    "flow" if name.startswith("last_") else "state",
                )
            set_series(
                "buildings.owner_fill_ratio", day,
                safe_ratio(daily["filled_owner"], daily["owner_required"]),
                "buildings", "sampled", "ratio",
            )
            set_series(
                "buildings.sell_through", day,
                safe_ratio(daily["last_sold"], daily["last_output"]),
                "buildings", "sampled", "ratio",
            )
            set_series(
                "buildings.planned_utilization_q16", day,
                safe_ratio(daily["util_weighted"], daily["util_weight"]),
                "buildings", "sampled", "ratio",
            )

        for type_id, values in per_type.items():
            values.sort(key=lambda item: item["day"])
            late = [item for item in values if item["day"] >= late_start]

            def total(name: str, source: list[dict[str, float]] = values) -> float:
                return sum(item.get(name, 0.0) for item in source)

            output = total("last_output")
            building_entities.append({
                "type_id": type_id,
                "building_id": building_ids.get(type_id, str(type_id)),
                "first_day": values[0]["day"],
                "last_day": values[-1]["day"],
                "count_first": values[0].get("count", 0.0),
                "count_last": values[-1].get("count", 0.0),
                "suspended_groups_last": values[-1].get("suspended_groups", 0.0),
                "recovery_groups_last": values[-1].get("recovery_groups", 0.0),
                "output_total": output,
                "sold_total": total("last_sold"),
                "discard_total": total("last_discarded"),
                "sell_through": safe_ratio(total("last_sold"), output),
                "discard_share": safe_ratio(total("last_discarded"), output),
                "revenue_to_viability_cost": safe_ratio(
                    total("last_revenue"), total("viability_operating_cost")
                ),
                "late_utilization_q16": safe_ratio(
                    total("planned_utilization_q16", late), len(late)
                ),
                "late_margin_q16": safe_ratio(
                    total("realized_profit_margin_q16", late), len(late)
                ),
                "debt_principal_last": values[-1].get("merchant_debt_principal", 0.0),
            })
        building_entities.sort(key=lambda item: (
            -item["suspended_groups_last"],
            item["late_utilization_q16"] if item["late_utilization_q16"] is not None else math.inf,
        ))

    resource_days: dict[tuple[str, int], dict[str, float]] = defaultdict(
        lambda: defaultdict(float)
    )

    def on_resource(row: dict[str | None, Any]) -> None:
        resource = str(row.get("resource_id") or "")
        day = integer(row.get("day_index"), -1)
        daily = resource_days[(resource, day)]
        daily["opening_reserve"] += number(row.get("opening_reserve")) or 0.0
        daily["reserve"] += number(row.get("reserve")) or 0.0
        daily["safe_yield"] += number(row.get("safe_yield")) or 0.0
        projected = integer(row.get("projected_life_days"), -1)
        if projected >= 0:
            if "projected_life_days" not in daily:
                daily["projected_life_days"] = projected
            else:
                daily["projected_life_days"] = min(
                    daily["projected_life_days"], projected
                )
        for name in RESOURCE_FLOW_FIELDS:
            daily[name] += number(row.get(name)) or 0.0

    resource_entities: list[dict[str, Any]] = []
    if "resources" in available:
        profiles["resources"] = scan("resources", paths["resources"], on_resource)
        resource_by_id: dict[str, list[dict[str, float]]] = defaultdict(list)
        resource_global_daily: dict[int, dict[str, float]] = defaultdict(
            lambda: defaultdict(float)
        )
        for (resource, day), daily in resource_days.items():
            item = {"day": day, **dict(daily)}
            resource_by_id[resource].append(item)
            target = resource_global_daily[day]
            for name in RESOURCE_FLOW_FIELDS:
                target[name] += item.get(name, 0.0)
            projected = item.get("projected_life_days", -1)
            target["critical_life_count"] += 0 <= projected <= 365

        for day, daily in resource_global_daily.items():
            for name in RESOURCE_FLOW_FIELDS + ("critical_life_count",):
                semantic = "pending" if name.endswith("_pending") else (
                    "flow" if name != "critical_life_count" else "state"
                )
                set_series(
                    f"resources.{name}", day, daily[name], "resources", "sampled",
                    semantic,
                )

        for resource, values in resource_by_id.items():
            values.sort(key=lambda item: item["day"])
            first, last = values[0], values[-1]
            opening = first.get("reserve", first.get("opening_reserve", 0.0))
            final = last.get("reserve", 0.0)
            resource_entities.append({
                "resource_id": resource,
                "first_day": first["day"],
                "last_day": last["day"],
                "reserve_first": opening,
                "reserve_last": final,
                "reserve_min": min(item.get("reserve", 0.0) for item in values),
                "reserve_delta": final - opening,
                "depletion_share": (
                    (opening - final) / opening if opening > 0 else None
                ),
                "natural_net_total": sum(
                    item.get("natural_net_change", 0.0) for item in values
                ),
                "artificial_applied_total": sum(
                    item.get("artificial_change_applied", 0.0) for item in values
                ),
                "artificial_pending_last": last.get("artificial_change_pending", 0.0),
                "extraction_applied_total": sum(
                    item.get("artificial_extraction_applied", 0.0) for item in values
                ),
                "projected_life_days_last": last.get("projected_life_days", -1),
            })
        resource_entities.sort(key=lambda item: (
            -(item["depletion_share"] or 0.0), item["resource_id"]
        ))

    cohort_output: list[dict[str, Any]] = []
    for state in cohort_entities.values():
        first = state["first"]
        last = state["last"]
        cohort_output.append({
            **state,
            "profession_id_stable": profession_ids.get(
                state["profession_id"], str(state["profession_id"])
            ),
            "worst_need_last_stable": need_ids.get(
                last["worst_need_id"], str(last["worst_need_id"])
            ),
            "population_delta": last["population"] - first["population"],
        })
    cohort_output.sort(key=lambda item: (item["population_delta"], item["signature_id"]))

    market_output: list[dict[str, Any]] = []
    for state in market_entities.values():
        rows_count = state["rows"]
        late_rows = state["late_rows"]
        item = {
            "good_id": state["good_id"],
            "rows": rows_count,
            "active_rows": state["active_rows"],
            "shortage_share_of_active": safe_ratio(
                state["shortage_rows"], state["active_rows"]
            ),
            "severe_shortage_share_of_active": safe_ratio(
                state["severe_shortage_rows"], state["active_rows"]
            ),
            "first": state["first"],
            "last": state["last"],
            "mean": {
                name: safe_ratio(state["sums"][name], rows_count)
                for name in MARKET_ENTITY_FIELDS
            },
            "late_mean": {
                name: safe_ratio(state["late_sums"][name], late_rows)
                for name in MARKET_ENTITY_FIELDS
            },
            "price_change_ratio": safe_ratio(
                state["last"]["price"], state["first"]["price"]
            ),
        }
        market_output.append(item)
    market_output.sort(key=lambda item: (
        -(item["late_mean"]["shortage_q16"] or 0.0),
        -(item["shortage_share_of_active"] or 0.0),
        -(
            (item["late_mean"]["demand_ema"] or 0.0)
            + (item["late_mean"]["business_demand_ema"] or 0.0)
        ),
    ))

    summary_epochs = profiles["summary"].epochs
    table_output = {
        kind: profile.public(summary_epochs)
        for kind, profile in profiles.items()
    }
    detail_cells = sorted({
        cell for kind, profile in profiles.items() if kind != "summary"
        for cell in profile.cells
    })

    signals: list[dict[str, Any]] = []

    def signal(priority: str, code: str, evidence: Any) -> None:
        signals.append({"priority": priority, "code": code, "evidence": evidence})

    for name, value in summary_audit_max.items():
        if value:
            signal("P0", f"nonzero_{name}", value)
    for kind, profile in profiles.items():
        if profile.bad_width_rows or profile.blank_core_rows or profile.duplicate_keys:
            signal("P0", f"{kind}_data_integrity", {
                "bad_width_rows": profile.bad_width_rows,
                "blank_core_rows": profile.blank_core_rows,
                "duplicate_primary_keys": profile.duplicate_keys,
            })
    births = summary_totals.get("births", 0.0)
    deaths = summary_totals.get("deaths", 0.0)
    if deaths > births:
        signal("P1", "global_deaths_exceed_births", {
            "births": births, "deaths": deaths, "net": births - deaths,
        })
    stressed_goods = [
        item for item in market_output
        if (item["late_mean"]["shortage_q16"] or 0.0) >= Q16 / 2
    ]
    if stressed_goods:
        signal("P1", "persistent_late_market_shortage", [
            {
                "good_id": item["good_id"],
                "late_shortage_q16": item["late_mean"]["shortage_q16"],
                "late_stock": item["late_mean"]["stock"],
            }
            for item in stressed_goods[:10]
        ])
    depleted = [
        item for item in resource_entities
        if (item["depletion_share"] or 0.0) >= 0.9
    ]
    if depleted:
        signal("P1", "resource_depletion_over_90_percent", depleted[:10])
    if building_entities:
        suspended = sum(item["suspended_groups_last"] > 0 for item in building_entities)
        if suspended / len(building_entities) >= 0.25:
            signal("P1", "widespread_building_suspension_at_end", {
                "types_with_suspension": suspended,
                "types_observed": len(building_entities),
            })
    if cohort_daily:
        first_local = cohort_daily[min(cohort_daily)]["population"]
        last_local = cohort_daily[max(cohort_daily)]["population"]
        if first_local > 0 and last_local / first_local <= 0.8:
            signal("P1", "sampled_population_decline_over_20_percent", {
                "first": first_local, "last": last_local,
                "change_share": last_local / first_local - 1.0,
            })

    output = {
        "tool_schema_version": 1,
        "record": {
            "prefix": str(prefix),
            "filename_version_hint": filename_version(prefix),
            "available_dimensions": sorted(available),
            "missing_dimensions": sorted(set(KINDS) - set(available)),
            "day_first": day_first,
            "day_last": day_last,
            "late_window_first_day": late_start,
            "detail_cells": detail_cells,
            "scope_warning": (
                "summary is global; detail tables are sampled/local and must not be "
                "silently generalized to the world"
            ),
        },
        "tables": table_output,
        "summary": {
            "first": summary_first,
            "last": summary_last,
            "flow_totals": dict(summary_totals),
            "audit_max_abs": summary_audit_max,
            "categorical_values": {
                name: sorted(values) for name, values in summary_categories.items()
            },
        },
        "entities": {
            "cohorts": cohort_output,
            "market_goods": market_output,
            "building_types": building_entities,
            "resources": resource_entities,
            "building_row_classes": dict(building_row_classes),
            "investment_rejection_counts": dict(investment_rejections),
        },
        "signals_not_findings": signals,
        "series_index": {
            "count": len(series),
            "metadata": series_metadata,
        },
        "correlations": correlation_report(
            dict(series), series_metadata,
            max(3, args.min_correlation_samples), max(1, args.top),
            max(8, args.max_correlation_series),
        ),
    }

    output_path = args.output
    if output_path is None:
        output_path = Path(f"{prefix}_profile.json")
    elif not output_path.is_absolute():
        output_path = (repo_root / output_path).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps({
        "output": str(output_path),
        "rows": {kind: profile.rows for kind, profile in profiles.items()},
        "signals": len(signals),
        "series": len(series),
        "correlations": {
            name: len(values)
            for name, values in output["correlations"].items()
            if name.startswith("top_")
        },
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
