#!/usr/bin/env python3
"""Project.Keynes 离线经济数学验证器。

直接消费 export_model.js 生成的只读模型和用户场景；不启动 Godot，不修改游戏数据。
"""

from __future__ import annotations

import argparse
import html
import json
import math
import subprocess
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

import numpy as np
from scipy.optimize import brentq, least_squares, minimize_scalar


Q16_ONE = 65536.0
EPS = 1e-9


DEFAULT_SCENARIO: dict[str, Any] = {
    "name": "reference",
    "era": "stone",
    "cumulative": True,
    "latest_upgrade_only": True,
    "default_building_count": 1.0,
    "building_counts": {},
    "solve_utilization": True,
    "target_utilization": 0.65,
    "utilization": 0.65,
    "building_utilization": {},
    "sell_through": 0.8,
    "profession_populations": {},
    "prices": {},
    "trade_enabled": False,
    "resource_context": {
        "default": {
            "temperature": 0.5,
            "moisture": 0.5,
            "reserve_fraction_of_capacity": 0.8,
        }
    },
    "projection_days": [365, 730, 3650],
    "corridors": {
        "renewable_replacement_warn": 0.9,
        "renewable_replacement_good": 1.0,
        "goods_coverage_warn": 0.9,
        "goods_coverage_excess": 2.0,
        "household_essential_coverage_warn": 1.0,
        "inventory_cover_cycles_min": 1.0,
    },
}


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def finite(value: Any, default: float = 0.0) -> float:
    try:
        number = float(value)
        return number if math.isfinite(number) else default
    except (TypeError, ValueError):
        return default


def add(mapping: dict[str, float], key: str, value: float) -> None:
    if key and math.isfinite(value) and value != 0:
        mapping[key] = mapping.get(key, 0.0) + value


class BalanceValidator:
    def __init__(self, model: dict[str, Any], scenario: dict[str, Any]):
        self.model = model
        self.scenario = deep_merge(DEFAULT_SCENARIO, scenario)
        self.goods_scale = finite(model.get("scales", {}).get("goods"), 1000.0)
        self.money_scale = finite(model.get("scales", {}).get("money"), 10000.0)
        self.resource_scale = finite(model.get("scales", {}).get("resource_quantity"), 100.0)
        self.economy = model.get("economy_profile", {})
        self.eras = model.get("eras", [])
        self.goods = model.get("goods", [])
        self.resources = model.get("resources", [])
        self.professions = model.get("professions", [])
        self.plans = model.get("plans", [])
        self.needs = model.get("needs", [])
        self.buildings = model.get("buildings", [])
        self.good_by_id = {str(x.get("id")): x for x in self.goods}
        self.resource_by_id = {str(x.get("id")): x for x in self.resources}
        self.profession_by_id = {str(x.get("id")): x for x in self.professions}
        self.plan_by_id = {str(x.get("id")): x for x in self.plans}
        self.need_by_id = {str(x.get("id")): x for x in self.needs}
        self.era_by_id = {str(x.get("id")): x for x in self.eras}
        self.era_order = self._resolve_era_order()
        self.prices = {
            gid: finite(self.scenario.get("prices", {}).get(gid), finite(g.get("default_price"), 1.0))
            for gid, g in self.good_by_id.items()
        }
        self.reference_cache: dict[str, dict[str, Any]] = {}
        self.active_buildings = self._select_buildings()
        self.residual_good_ids, self.residual_resource_ids = self._build_residual_ids()

    def _resolve_era_order(self) -> int:
        era_id = str(self.scenario.get("era", ""))
        if era_id not in self.era_by_id:
            known = ", ".join(self.era_by_id)
            raise ValueError(f"未知时代 '{era_id}'，可用值: {known}")
        return int(self.era_by_id[era_id].get("order", 0))

    def _select_buildings(self) -> list[dict[str, Any]]:
        cumulative = bool(self.scenario.get("cumulative", True))
        selected = []
        for building in self.buildings:
            order = int(building.get("eraOrder", 999))
            if (cumulative and order <= self.era_order) or (not cumulative and order == self.era_order):
                selected.append(building)
        if self.scenario.get("latest_upgrade_only", True):
            best: dict[str, dict[str, Any]] = {}
            for building in selected:
                family = str(building.get("upgrade_family_id", ""))
                if not family:
                    continue
                current = best.get(family)
                if current is None or int(building.get("upgrade_tier", 0)) > int(current.get("upgrade_tier", 0)):
                    best[family] = building
            selected = [b for b in selected if not b.get("upgrade_family_id") or best.get(str(b["upgrade_family_id"])) is b]
        counts = self.scenario.get("building_counts", {})
        default_count = finite(self.scenario.get("default_building_count"), 0.0)
        result = []
        for building in selected:
            bid = str(building.get("id"))
            count = max(0.0, finite(counts.get(bid), default_count))
            if count > 0:
                row = dict(building)
                row["_scenario_count"] = count
                result.append(row)
        return sorted(result, key=lambda b: str(b.get("id")))

    def _build_residual_ids(self) -> tuple[list[str], list[str]]:
        good_ids: set[str] = set()
        resource_ids: set[str] = set()
        for building in self.active_buildings:
            good_ids.update(str(x.get("good")) for x in building.get("produces", []))
            for item in building.get("consumes", []):
                good_ids.update(str(good.get("id")) for good, _ in self.input_candidates(item))
            resource_ids.update(str(x.get("resource")) for x in building.get("extracts", []))
            resource_ids.update(str(x) for x in building.get("resource_generation_ids", []))
            for job in building.get("jobs", []):
                good_ids.update(self.profession_reference(str(job.get("profession", "")))["goods"])
        return sorted(x for x in good_ids if x), sorted(x for x in resource_ids if x)

    def profession_reference(self, profession_id: str) -> dict[str, Any]:
        if profession_id in self.reference_cache:
            return self.reference_cache[profession_id]
        profession = self.profession_by_id.get(profession_id)
        plan = self.plan_by_id.get(str(profession.get("default_consumption_plan_id", ""))) if profession else None
        result = {"goods": {}, "total_cost": 0.0, "living_cost": 0.0, "needs": [], "has_plan": bool(plan)}
        if not plan:
            self.reference_cache[profession_id] = result
            return result
        for need in plan.get("needDetails", []):
            variants = []
            for variant in need.get("variants", []):
                if finite(variant.get("preferenceQ16")) <= 0:
                    continue
                available = True
                for component in variant.get("components", []):
                    good = self.good_by_id.get(str(component.get("good")))
                    if not good or (good.get("eraPrimary") is not None and int(good.get("eraOrder", 999)) > self.era_order):
                        available = False
                        break
                if available:
                    variants.append(variant)
            score_sum = sum(finite(v.get("preferenceQ16")) for v in variants)
            need_cost = 0.0
            need_goods: dict[str, float] = {}
            if score_sum > 0:
                for variant in variants:
                    share = finite(variant.get("preferenceQ16")) / score_sum
                    bundle = finite(need.get("baseQty")) * share
                    for component in variant.get("components", []):
                        gid = str(component.get("good"))
                        quantity = bundle * finite(component.get("qty")) / self.goods_scale
                        add(result["goods"], gid, quantity)
                        add(need_goods, gid, quantity)
                        need_cost += quantity * self.prices.get(gid, 0.0) / self.goods_scale
            weight = finite(self.need_by_id.get(str(need.get("id")), {}).get("living_cost_weight_q16")) / Q16_ONE
            result["total_cost"] += need_cost
            result["living_cost"] += need_cost * weight
            result["needs"].append({
                "id": str(need.get("id")), "cost": need_cost, "living_weight": weight, "goods": need_goods
            })
        self.reference_cache[profession_id] = result
        return result

    def input_candidates(self, item: dict[str, Any]) -> list[tuple[dict[str, Any], float]]:
        candidates: list[tuple[dict[str, Any], float]] = []
        if item.get("candidateEdge"):
            for candidate in item.get("candidates", []):
                good = self.good_by_id.get(str(candidate.get("good")))
                if good:
                    candidates.append((good, max(1.0, finite(candidate.get("efficiency"), Q16_ONE))))
        elif item.get("categoryEdge"):
            category = str(item.get("category", ""))
            min_quality = int(item.get("minQuality", 0))
            for good in self.goods:
                categories = good.get("substitutionCategories", [])
                if category in categories and int(good.get("production_quality_level", 0)) >= min_quality:
                    candidates.append((good, max(1.0, finite(good.get("production_efficiency_q16"), Q16_ONE))))
        else:
            good = self.good_by_id.get(str(item.get("good")))
            if good:
                candidates.append((good, Q16_ONE))
        return [x for x in candidates if x[0].get("eraPrimary") is None or int(x[0].get("eraOrder", 999)) <= self.era_order]

    def select_input(self, item: dict[str, Any]) -> tuple[dict[str, Any], float, float] | None:
        choices = []
        for good, efficiency in self.input_candidates(item):
            physical = finite(item.get("qty")) * Q16_ONE / efficiency
            cost = physical * self.prices.get(str(good.get("id")), 0.0) / self.goods_scale
            choices.append((cost, str(good.get("id")), good, physical))
        if not choices:
            return None
        choices.sort(key=lambda row: (row[0], row[1]))
        cost, _, good, physical = choices[0]
        return good, physical, cost

    def evaluate(self, utilization: np.ndarray) -> dict[str, Any]:
        sell_through = clamp(finite(self.scenario.get("sell_through"), 0.8), 0.0, 1.0)
        supply: dict[str, float] = {}
        full_supply: dict[str, float] = {}
        business_demand: dict[str, float] = {}
        household_demand: dict[str, float] = {}
        profession_population: dict[str, float] = {}
        profession_income: dict[str, float] = {}
        profession_owner_loss: dict[str, float] = {}
        harvest: dict[str, float] = {}
        generation: dict[str, float] = {}
        building_rows = []

        for index, building in enumerate(self.active_buildings):
            u = clamp(float(utilization[index]), 0.0, 1.0)
            count = finite(building.get("_scenario_count"), 0.0)
            production_units = count * u
            # 人口与已配置岗位属于场景存量，不能通过把利用率压到 0 消除居民需求。
            job_units = count
            input_cost = 0.0
            selected_inputs = []
            for item in building.get("consumes", []):
                selected = self.select_input(item)
                if not selected:
                    selected_inputs.append({"missing": True, "slot": item})
                    continue
                good, physical, unit_cost = selected
                quantity = physical * production_units
                gid = str(good.get("id"))
                add(business_demand, gid, quantity)
                input_cost += unit_cost * production_units
                selected_inputs.append({"good": gid, "quantity": quantity})

            retail_output = 0.0
            accepted_revenue = 0.0
            full_revenue = 0.0
            is_monetary_issue = False
            for output in building.get("produces", []):
                gid = str(output.get("good"))
                good = self.good_by_id.get(gid)
                if not good:
                    continue
                quantity = finite(output.get("qty")) * production_units
                accepted = quantity * sell_through
                add(full_supply, gid, quantity)
                add(supply, gid, accepted)
                retail = quantity * self.prices.get(gid, 0.0) / self.goods_scale
                buy_factor = finite(good.get("merchant_buy_price_factor_q16"), 0.0) / Q16_ONE
                retail_output += retail
                full_revenue += retail * buy_factor
                accepted_revenue += retail * buy_factor * sell_through
                is_monetary_issue = is_monetary_issue or finite(good.get("monetary_issue_value")) > 0

            wages = 0.0
            employee_slots = 0.0
            for job in building.get("jobs", []):
                pid = str(job.get("profession", ""))
                slots = finite(job.get("slots"), 0.0) * job_units
                add(profession_population, pid, slots)
                if job.get("role") == "employee":
                    wage = finite(job.get("refWage"), finite(building.get("wage_per_employee_per_day")))
                    paid = wage * slots
                    wages += paid
                    employee_slots += slots
                    add(profession_income, pid, paid)

            owner_id = str(building.get("owner_profession_id", ""))
            owner_slots = finite(building.get("owner_slots_per_building"), 1.0) * job_units if owner_id else 0.0
            owner_living = self.profession_reference(owner_id)["living_cost"] * owner_slots if owner_id else 0.0
            operating_cost = input_cost + wages
            distributable = accepted_revenue - operating_cost
            if owner_id:
                add(profession_income, owner_id, max(0.0, distributable))
                add(profession_owner_loss, owner_id, max(0.0, -distributable))
            target_margin = finite(building.get("target_operating_margin_q16")) / Q16_ONE
            required_revenue = max(operating_cost / max(1.0 / Q16_ONE, 1.0 - target_margin), operating_cost + owner_living)
            margin = (accepted_revenue - operating_cost) / accepted_revenue if accepted_revenue > 0 else (-1.0 if operating_cost > 0 else 0.0)
            break_even = required_revenue / full_revenue if full_revenue > 0 else math.inf

            for item in building.get("extracts", []):
                rid = str(item.get("resource", ""))
                mode = str(item.get("mode", "extract"))
                if mode != "capacity":
                    add(harvest, rid, finite(item.get("qty")) * production_units)
            generation_floor = finite(building.get("resource_generation_floor_q16")) / Q16_ONE
            generation_units = count * max(u, generation_floor)
            for rid, quantity in zip(
                building.get("resource_generation_ids", []),
                building.get("resource_generation_quantities_per_day", []), strict=False
            ):
                add(generation, str(rid), finite(quantity) * generation_units)

            building_rows.append({
                "id": str(building.get("id")), "name": str(building.get("display_name", "")),
                "count": count, "utilization": u, "accepted_revenue": accepted_revenue,
                "retail_output_value": retail_output, "input_cost": input_cost, "wages": wages,
                "owner_living_cost": owner_living, "operating_cost": operating_cost,
                "surplus_after_owner_living": accepted_revenue - operating_cost - owner_living,
                "margin": margin, "target_margin": target_margin,
                "break_even_sell_through": break_even, "sustainable": is_monetary_issue or accepted_revenue + 10 >= required_revenue,
                "is_monetary_issue": is_monetary_issue, "selected_inputs": selected_inputs,
            })

        overrides = self.scenario.get("profession_populations", {})
        for pid, value in overrides.items():
            profession_population[str(pid)] = max(0.0, finite(value))
        for pid, population in profession_population.items():
            reference = self.profession_reference(pid)
            for gid, per_person in reference["goods"].items():
                add(household_demand, gid, per_person * population)

        goods_rows = []
        active_good_ids = sorted(set(supply) | set(full_supply) | set(business_demand) | set(household_demand))
        for gid in active_good_ids:
            produced = supply.get(gid, 0.0)
            full = full_supply.get(gid, 0.0)
            business = business_demand.get(gid, 0.0)
            household = household_demand.get(gid, 0.0)
            demand = business + household
            coverage = produced / demand if demand > EPS else (math.inf if produced > EPS else 1.0)
            goods_rows.append({
                "id": gid, "name": str(self.good_by_id.get(gid, {}).get("display_name", "")),
                "supply": produced, "full_output": full, "business_demand": business,
                "household_demand": household, "demand": demand, "net": produced - demand,
                "coverage": coverage,
            })

        cohort_rows = []
        for pid in sorted(profession_population):
            population = profession_population[pid]
            reference = self.profession_reference(pid)
            income = profession_income.get(pid, 0.0)
            expense = reference["total_cost"] * population
            essential = reference["living_cost"] * population
            essential_coverage = income / essential if essential > EPS else (math.inf if income > 0 else 1.0)
            savings = income - expense
            cohort_rows.append({
                "id": pid, "name": str(self.profession_by_id.get(pid, {}).get("display_name", "")),
                "population": population, "income": income, "expense": expense,
                "essential_expense": essential, "savings": savings,
                "savings_rate": savings / income if income > EPS else (-math.inf if expense > 0 else 0.0),
                "essential_coverage": essential_coverage,
                "reference_satisfaction": clamp(essential_coverage, 0.0, 1.0) if math.isfinite(essential_coverage) else 1.0,
                "owner_loss": profession_owner_loss.get(pid, 0.0), "has_plan": reference["has_plan"],
            })

        return {
            "buildings": building_rows, "goods": goods_rows, "cohorts": cohort_rows,
            "harvest": harvest, "generation": generation,
            "profession_population": profession_population,
        }

    def _resource_runtime(self, resource: dict[str, Any]) -> dict[str, float]:
        context_all = self.scenario.get("resource_context", {})
        context = deep_merge(context_all.get("default", {}), context_all.get(str(resource.get("id")), {}))
        temperature = finite(context.get("temperature"), 0.5)
        moisture = clamp(finite(context.get("moisture"), 0.5), 0.0, 1.0)
        lo, hi = finite(resource.get("temp_lo"), 0.0), finite(resource.get("temp_hi"), 1.0)
        tn = clamp((temperature - lo) / max(0.0001, hi - lo), 0.0, 1.0)
        temp_fit = 1.0 - clamp(abs(tn - finite(resource.get("climate_temp_opt"), 0.5)) /
                               max(0.0001, finite(resource.get("climate_temp_tol"), 1.0)), 0.0, 1.0)
        moisture_fit = 1.0 - clamp(abs(moisture - finite(resource.get("climate_moisture_opt"), 0.5)) /
                                   max(0.0001, finite(resource.get("climate_moisture_tol"), 1.0)), 0.0, 1.0)
        climate_fit = temp_fit * moisture_fit
        weight = clamp(finite(resource.get("runtime_climate_fit_weight")), 0.0, 1.0)
        runtime_fit = 1.0 + (climate_fit - 1.0) * weight
        return {
            "temperature": temperature, "moisture": moisture, "tn": tn,
            "climate_fit": climate_fit, "runtime_fit": runtime_fit,
            "reserve_fraction": clamp(finite(context.get("reserve_fraction_of_capacity"), 0.8), 0.0, 2.0),
            "reserve_override": context.get("reserve"),
        }

    def _resource_step(self, resource: dict[str, Any], runtime: dict[str, float], reserve: float, extra: float) -> float:
        fit = runtime["runtime_fit"]
        capacity = max(0.0, finite(resource.get("ecology_capacity")) * self.resource_scale * fit)
        value = max(0.0, reserve + extra)
        if capacity > EPS:
            growth = 1.0 + max(0.0, finite(resource.get("ecology_growth_rate"))) * fit
            immigration = max(0.0, finite(resource.get("ecology_immigration"))) * self.resource_scale * fit
            seeded = value + immigration
            denom = 1.0 + (growth - 1.0) * seeded / capacity
            value = growth * seeded / denom if denom > 0 else 0.0
            acute = clamp((0.25 - runtime["climate_fit"]) / 0.25, 0.0, 1.0)
            stress = 1.0 + max(0.0, finite(resource.get("ecology_stress_mortality_rate"))) * acute
            return max(0.0, value / stress)
        gen_climate = self.resource_scale * (finite(resource.get("gen_base")) +
            finite(resource.get("gen_temp")) * runtime["tn"] + finite(resource.get("gen_moisture")) * runtime["moisture"])
        decay_climate = self.resource_scale * (finite(resource.get("decay_base")) +
            finite(resource.get("decay_temp")) * runtime["tn"] + finite(resource.get("decay_moisture")) * runtime["moisture"])
        production = gen_climate + self.resource_scale * finite(resource.get("gen_self")) * fit - decay_climate - \
            self.resource_scale * finite(resource.get("decay_stress")) * (1.0 - fit)
        loss = max(0.0, finite(resource.get("decay_self")))
        return max(0.0, (value + production) / (1.0 + loss))

    def _default_reserve(self, resource: dict[str, Any], runtime: dict[str, float]) -> float | None:
        if runtime["reserve_override"] is not None:
            return max(0.0, finite(runtime["reserve_override"]))
        capacity = finite(resource.get("ecology_capacity")) * self.resource_scale * runtime["runtime_fit"]
        if capacity > EPS:
            return capacity * runtime["reserve_fraction"]
        loss = max(0.0, finite(resource.get("decay_self")))
        if loss > EPS:
            zero_step = self._resource_step(resource, runtime, 0.0, 0.0)
            equilibrium = zero_step * (1.0 + loss) / loss
            return max(0.0, equilibrium * runtime["reserve_fraction"])
        return None

    def _resource_equilibria(self, resource: dict[str, Any], runtime: dict[str, float], net_external: float,
                             search_hi: float) -> list[dict[str, float]]:
        def residual(reserve: float) -> float:
            return self._resource_step(resource, runtime, reserve, net_external) - reserve
        grid = np.linspace(0.0, max(1.0, search_hi), 257)
        roots: list[float] = []
        last_x, last_y = float(grid[0]), residual(float(grid[0]))
        if abs(last_y) < 1e-7:
            roots.append(last_x)
        for raw_x in grid[1:]:
            x = float(raw_x)
            y = residual(x)
            if y == 0 or y * last_y < 0:
                try:
                    root = brentq(residual, last_x, x)
                    if not roots or abs(root - roots[-1]) > 1e-4:
                        roots.append(root)
                except ValueError:
                    pass
            last_x, last_y = x, y
        result = []
        for root in roots:
            step = max(1e-3, root * 1e-5)
            derivative = (self._resource_step(resource, runtime, root + step, net_external) -
                          self._resource_step(resource, runtime, max(0.0, root - step), net_external)) / (2.0 * step)
            result.append({"reserve": root, "derivative": derivative, "stable": abs(derivative) < 1.0})
        return result

    def resource_report(self, evaluated: dict[str, Any]) -> list[dict[str, Any]]:
        rows = []
        active_ids = sorted(set(evaluated["harvest"]) | set(evaluated["generation"]))
        horizons = sorted({max(0, int(x)) for x in self.scenario.get("projection_days", [])})
        for rid in active_ids:
            resource = self.resource_by_id.get(rid)
            if not resource:
                rows.append({"id": rid, "status": "fail", "reason": "建筑引用了不存在的自然资源"})
                continue
            runtime = self._resource_runtime(resource)
            reserve = self._default_reserve(resource, runtime)
            harvest = evaluated["harvest"].get(rid, 0.0)
            generated = evaluated["generation"].get(rid, 0.0)
            renewable = finite(resource.get("ecology_capacity")) > 0 or finite(resource.get("decay_self")) > 0 or any(
                abs(finite(resource.get(key))) > EPS for key in ("gen_base", "gen_temp", "gen_moisture", "gen_self")
            )
            if reserve is None:
                rows.append({
                    "id": rid, "name": str(resource.get("display_name", "")), "renewable": renewable,
                    "status": "warn", "reason": "不可从目录参数唯一推导本格初始储量；请在 resource_context 中提供 reserve",
                    "harvest_per_day": harvest, "generation_per_day": generated,
                })
                continue
            natural_next = self._resource_step(resource, runtime, reserve, 0.0)
            natural_gain = natural_next - reserve
            sustainable_inflow = max(0.0, natural_gain + generated)
            replacement = sustainable_inflow / harvest if harvest > EPS else math.inf
            capacity = finite(resource.get("ecology_capacity")) * self.resource_scale * runtime["runtime_fit"]
            search_hi = max(reserve * 2.0, capacity * 1.5, 1.0)
            equilibria = self._resource_equilibria(resource, runtime, generated - harvest, search_hi) if renewable else []
            stable = [x for x in equilibria if x["stable"]]

            max_sustainable = None
            if renewable:
                objective = lambda x: -(self._resource_step(resource, runtime, float(x), generated) - float(x))
                optimum = minimize_scalar(objective, bounds=(0.0, search_hi), method="bounded")
                max_sustainable = max(0.0, -float(optimum.fun))

            projections: dict[str, Any] = {}
            value = reserve
            natural_total = 0.0
            artificial_total = 0.0
            exhausted_day = None
            max_day = max(horizons, default=0)
            horizon_set = set(horizons)
            for day in range(1, max_day + 1):
                after_external = max(0.0, value + generated - harvest)
                next_value = self._resource_step(resource, runtime, value, generated - harvest)
                natural_total += next_value - after_external
                artificial_total += generated - min(harvest, value + generated)
                value = next_value
                if exhausted_day is None and value <= 1e-6 and harvest > generated:
                    exhausted_day = day
                if day in horizon_set:
                    projections[str(day)] = {
                        "reserve": value, "change": value - reserve,
                        "change_ratio": (value - reserve) / reserve if reserve > EPS else math.inf,
                        "natural_change": natural_total, "artificial_change": artificial_total,
                    }

            warn_line = finite(self.scenario["corridors"].get("renewable_replacement_warn"), 0.9)
            if renewable and replacement < warn_line:
                status = "fail"
                reason = "当前储量下自然补充不足以覆盖本格采集"
            elif renewable and not stable:
                status = "warn"
                reason = "给定持续采集下未找到稳定正储量平衡点"
            elif not renewable and harvest > EPS:
                status = "warn"
                reason = "不可再生资源按耗尽年限设计，不要求自然替代"
            else:
                status = "pass"
                reason = "存在稳定资源走廊" if renewable else "当前无持续采集"
            rows.append({
                "id": rid, "name": str(resource.get("display_name", "")), "renewable": renewable,
                "status": status, "reason": reason, "initial_reserve": reserve,
                "climate_fit": runtime["climate_fit"], "runtime_fit": runtime["runtime_fit"],
                "harvest_per_day": harvest, "generation_per_day": generated,
                "natural_change_at_initial_per_day": natural_gain,
                "replacement_ratio_at_initial": replacement,
                "max_sustainable_harvest_per_day": max_sustainable,
                "equilibria": equilibria, "projections": projections, "exhausted_day": exhausted_day,
            })
        return rows

    def static_audit(self) -> list[dict[str, str]]:
        findings: list[dict[str, str]] = []
        producer_ids = {str(output.get("good")) for b in self.active_buildings for output in b.get("produces", [])}
        for building in self.active_buildings:
            bid = str(building.get("id"))
            for item in building.get("consumes", []):
                if not self.input_candidates(item):
                    findings.append({"severity": "fail", "code": "missing_input", "entity": bid,
                                     "message": "当前时代没有可用的配方投入候选"})
            for output in building.get("produces", []):
                if str(output.get("good")) not in self.good_by_id:
                    findings.append({"severity": "fail", "code": "missing_output", "entity": bid,
                                     "message": f"产出引用不存在的物资 {output.get('good')}"})
            for item in building.get("extracts", []):
                rid = str(item.get("resource"))
                if rid not in self.resource_by_id:
                    findings.append({"severity": "fail", "code": "missing_resource", "entity": bid,
                                     "message": f"引用不存在的自然资源 {rid}"})
                if str(item.get("access", "local")) not in ("", "local"):
                    findings.append({"severity": "fail", "code": "nonlocal_harvest", "entity": bid,
                                     "message": f"资源 {rid} 的 access={item.get('access')}，违反本格采集约束"})
        demanded = set()
        for building in self.active_buildings:
            for item in building.get("consumes", []):
                demanded.update(str(g.get("id")) for g, _ in self.input_candidates(item))
            for job in building.get("jobs", []):
                demanded.update(self.profession_reference(str(job.get("profession")))["goods"])
        for gid in sorted(demanded - producer_ids):
            good = self.good_by_id.get(gid, {})
            if not bool(good.get("trade_enabled", True)) or not self.scenario.get("trade_enabled", False):
                findings.append({"severity": "warn", "code": "no_local_producer", "entity": gid,
                                 "message": "场景存在需求但没有本地生产建筑"})
        if self.scenario.get("trade_enabled", False):
            findings.append({"severity": "warn", "code": "trade_topology_missing", "entity": "scenario",
                             "message": "已启用贸易，但离线场景未提供邻格价格与运输拓扑；报告仅计算本格缺口"})
        if not findings:
            findings.append({"severity": "pass", "code": "structural_ok", "entity": "catalog",
                             "message": "当前场景引用完整，所有自然资源采集均为本格"})
        return findings

    def _solver_residual(self, utilization: np.ndarray) -> np.ndarray:
        evaluated = self.evaluate(utilization)
        residuals = []
        by_good = {row["id"]: row for row in evaluated["goods"]}
        for gid in self.residual_good_ids:
            row = by_good.get(gid, {"supply": 0.0, "demand": 0.0})
            scale = max(row["supply"], row["demand"], self.goods_scale)
            gap = row["supply"] - row["demand"]
            weight = 2.0 if gap < 0 else 0.35
            residuals.append(weight * gap / scale)
        for rid in self.residual_resource_ids:
            harvest = evaluated["harvest"].get(rid, 0.0)
            resource = self.resource_by_id.get(rid)
            if not resource:
                residuals.append(1.0)
                continue
            runtime = self._resource_runtime(resource)
            reserve = self._default_reserve(resource, runtime)
            if reserve is None:
                residuals.append(0.0)
                continue
            natural = max(0.0, self._resource_step(resource, runtime, reserve, 0.0) - reserve)
            renewable = finite(resource.get("ecology_capacity")) > 0 or finite(resource.get("decay_self")) > 0
            excess = max(0.0, harvest - natural - evaluated["generation"].get(rid, 0.0)) if renewable else 0.0
            residuals.append(2.0 * excess / max(harvest, natural, 1.0))
        for row in evaluated["buildings"]:
            if row["is_monetary_issue"]:
                residuals.append(0.0)
                continue
            required = max(0.0, row["operating_cost"] + row["owner_living_cost"])
            deficit = max(0.0, required - row["accepted_revenue"])
            residuals.append(1.5 * deficit / max(required, 1.0))
        target = clamp(finite(self.scenario.get("target_utilization"), 0.65), 0.0, 1.0)
        residuals.extend(0.04 * (float(value) - target) for value in utilization)
        return np.asarray(residuals or [0.0], dtype=float)

    def solve(self) -> tuple[np.ndarray, dict[str, Any]]:
        count = len(self.active_buildings)
        base = clamp(finite(self.scenario.get("utilization"), 0.65), 0.0, 1.0)
        overrides = self.scenario.get("building_utilization", {})
        initial = np.asarray([clamp(finite(overrides.get(str(b.get("id"))), base), 0.0, 1.0)
                              for b in self.active_buildings], dtype=float)
        if count == 0 or not self.scenario.get("solve_utilization", True):
            return initial, {"attempted": False, "success": True, "message": "使用场景给定利用率", "cost": 0.0}
        result = least_squares(self._solver_residual, initial, bounds=(np.zeros(count), np.ones(count)),
                               xtol=1e-10, ftol=1e-10, gtol=1e-10, max_nfev=1000)
        return result.x, {
            "attempted": True, "success": bool(result.success), "message": str(result.message),
            "cost": float(result.cost), "optimality": float(result.optimality), "evaluations": int(result.nfev),
            "residual_norm": float(np.linalg.norm(result.fun)),
        }

    def market_stability(self, evaluated: dict[str, Any]) -> dict[str, Any]:
        market_days = finite(self.economy.get("merchant_market_making_days_q16"), 30 * Q16_ONE) / Q16_ONE
        cycle_days = max(1.0, finite(self.economy.get("market_cycle_days"), 5.0))
        rows = []
        maximum = 0.0
        for row in evaluated["goods"]:
            if row["demand"] <= EPS:
                continue
            good = self.good_by_id.get(row["id"], {})
            ratio = finite(good.get("inventory_target_ratio_q16"), Q16_ONE) / Q16_ONE
            target_days = market_days * ratio
            target_stock = row["demand"] * target_days
            price = max(1.0, self.prices.get(row["id"], 1.0))
            elasticity = max(0.0, finite(good.get("demand_price_elasticity_q16"), Q16_ONE) / Q16_ONE)
            adjust = clamp(finite(good.get("price_adjust_q16"), 0.0) / Q16_ONE, 0.0, 1.0)
            supply = row["demand"]

            def mapping(state: np.ndarray) -> np.ndarray:
                inventory, current_price = float(state[0]), max(1.0, float(state[1]))
                demand = row["demand"] * (current_price / price) ** (-elasticity)
                desired = demand * target_days
                next_inventory = max(0.0, inventory + supply - demand)
                pressure = (desired - inventory) / max(desired, self.goods_scale)
                next_price = clamp(current_price * (1.0 + adjust * pressure),
                                   finite(good.get("min_price"), 1.0), finite(good.get("max_price"), 1e8))
                return np.asarray([next_inventory, next_price])

            state = np.asarray([target_stock, price])
            jacobian = np.zeros((2, 2))
            for axis in range(2):
                step = max(1e-4, abs(state[axis]) * 1e-5)
                plus, minus = state.copy(), state.copy()
                plus[axis] += step
                minus[axis] -= step
                jacobian[:, axis] = (mapping(plus) - mapping(minus)) / (2.0 * step)
            radius = float(max(abs(np.linalg.eigvals(jacobian))))
            maximum = max(maximum, radius)
            rows.append({
                "id": row["id"], "target_days": target_days,
                "inventory_cover_cycles": target_days / cycle_days,
                "spectral_radius": radius, "locally_stable": radius < 1.0,
            })
        return {
            "model": "本格库存—价格二状态参考线性化；不等同于运行时 EMA/资金/贸易回放",
            "maximum_spectral_radius": maximum, "locally_stable": maximum < 1.0, "goods": rows,
        }

    def recommendations(self, evaluated: dict[str, Any], resources: list[dict[str, Any]]) -> list[dict[str, str]]:
        recommendations = []
        warn_replacement = finite(self.scenario["corridors"].get("renewable_replacement_warn"), 0.9)
        for row in resources:
            ratio = row.get("replacement_ratio_at_initial")
            if row.get("renewable") and isinstance(ratio, (int, float)) and math.isfinite(ratio) and ratio < warn_replacement:
                multiplier = 1.0 / max(ratio, 1e-6)
                recommendations.append({
                    "domain": "resource", "entity": row["id"],
                    "message": f"当前替代率 {ratio:.3f}；先验证有效自然补充约 ×{multiplier:.2f}，或等比例降低采集，再做长期投影。",
                })
        for row in evaluated["buildings"]:
            if not row["sustainable"] and not row["is_monetary_issue"]:
                required = row["break_even_sell_through"]
                recommendations.append({
                    "domain": "building", "entity": row["id"],
                    "message": f"目标盈亏平衡承接率为 {required:.1%}；检查物理产出、收购价和工资，勿用缩小库存目标掩盖亏损。",
                })
        for row in evaluated["cohorts"]:
            coverage = row["essential_coverage"]
            if math.isfinite(coverage) and coverage < 1.0:
                recommendations.append({
                    "domain": "cohort", "entity": row["id"],
                    "message": f"必要生活费覆盖率 {coverage:.1%}；优先修复对应建筑营收与已支付工资。",
                })
        for row in evaluated["goods"]:
            if row["demand"] > EPS and row["coverage"] < finite(self.scenario["corridors"].get("goods_coverage_warn"), 0.9):
                if row["coverage"] <= 1e-6:
                    message = "当前完全没有本格供给；补齐生产/替代链，或在场景中显式启用可用贸易。"
                else:
                    message = f"本格供给覆盖率 {row['coverage']:.1%}；需要约 ×{1/row['coverage']:.2f} 的有效供给或替代品。"
                recommendations.append({
                    "domain": "market", "entity": row["id"],
                    "message": message,
                })
        return recommendations

    def run(self) -> dict[str, Any]:
        audit = self.static_audit()
        utilization, solver = self.solve()
        evaluated = self.evaluate(utilization)
        resources = self.resource_report(evaluated)
        stability = self.market_stability(evaluated)
        recommendations = self.recommendations(evaluated, resources)
        failures = sum(1 for row in audit if row["severity"] == "fail")
        failures += sum(1 for row in resources if row.get("status") == "fail")
        failures += sum(1 for row in evaluated["buildings"] if not row["sustainable"] and not row["is_monetary_issue"])
        warnings = sum(1 for row in audit if row["severity"] == "warn")
        warnings += sum(1 for row in resources if row.get("status") == "warn")
        warnings += sum(1 for row in evaluated["cohorts"] if math.isfinite(row["essential_coverage"]) and row["essential_coverage"] < 1.0)
        verdict = "fail" if failures else ("warn" if warnings or not stability["locally_stable"] else "pass")
        return {
            "schema": "project-keynes-economy-balance-report", "schema_version": 1,
            "method": {
                "engine": "offline_catalog_math", "godot_started": False,
                "resource_formula": "current IMEX / Beverton-Holt profile formula",
                "resource_topology": "local_cell_only",
                "runtime_parity": False,
                "limitations": [
                    "不包含 NativeEconomyRuntime 的冻结周期、整数取整、EMA 历史、商人现金上限和实际贸易拓扑",
                    "配方候选在当前价格下选择最低有效成本物资",
                    "阶层满意度是必要生活费预算覆盖的设计时近似值",
                ],
            },
            "scenario": self.scenario,
            "summary": {
                "verdict": verdict, "failures": failures, "warnings": warnings,
                "active_buildings": len(self.active_buildings), "active_goods": len(evaluated["goods"]),
                "active_cohorts": len(evaluated["cohorts"]), "active_resources": len(resources),
            },
            "solver": solver, "audit": audit, "buildings": evaluated["buildings"],
            "goods": evaluated["goods"], "cohorts": evaluated["cohorts"], "resources": resources,
            "market_stability": stability, "recommendations": recommendations,
        }


def json_safe(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_safe(item) for item in value]
    if isinstance(value, float) and not math.isfinite(value):
        return "Infinity" if value > 0 else "-Infinity"
    return value


def fmt(value: Any, digits: int = 3) -> str:
    if isinstance(value, str):
        return value
    if value is None:
        return "—"
    try:
        number = float(value)
    except (TypeError, ValueError):
        return str(value)
    if not math.isfinite(number):
        return "∞" if number > 0 else "-∞"
    return f"{number:,.{digits}f}"


def make_html(report: dict[str, Any]) -> str:
    verdict = report["summary"]["verdict"]
    def table(headers: list[str], rows: list[list[Any]]) -> str:
        head = "".join(f"<th>{html.escape(x)}</th>" for x in headers)
        body = "".join("<tr>" + "".join(f"<td>{html.escape(str(x))}</td>" for x in row) + "</tr>" for row in rows)
        return f"<div class='scroll'><table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table></div>"

    building_rows = [[x["id"], fmt(x["utilization"] * 100, 1) + "%", fmt(x["accepted_revenue"] / 10000, 2),
                      fmt(x["input_cost"] / 10000, 2), fmt(x["wages"] / 10000, 2), fmt(x["margin"] * 100, 1) + "%",
                      "通过" if x["sustainable"] else "失败"] for x in report["buildings"]]
    good_rows = [[x["id"], fmt(x["supply"] / 1000), fmt(x["demand"] / 1000), fmt(x["coverage"] * 100, 1) + "%"]
                 for x in report["goods"]]
    cohort_rows = [[x["id"], fmt(x["population"]), fmt(x["income"] / 10000, 2), fmt(x["expense"] / 10000, 2),
                    fmt(x["essential_coverage"] * 100, 1) + "%", fmt(x["savings"] / 10000, 2)] for x in report["cohorts"]]
    resource_rows = [[x.get("id"), x.get("status"), fmt(x.get("initial_reserve")), fmt(x.get("harvest_per_day")),
                      fmt(x.get("natural_change_at_initial_per_day")), fmt(x.get("replacement_ratio_at_initial")), x.get("reason", "")]
                     for x in report["resources"]]
    audit_rows = [[x["severity"], x["code"], x["entity"], x["message"]] for x in report["audit"]]
    recs = "".join(f"<li><b>{html.escape(x['domain'])}/{html.escape(x['entity'])}</b>：{html.escape(x['message'])}</li>"
                   for x in report["recommendations"]) or "<li>当前没有自动调参建议。</li>"
    return f"""<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width'>
<title>Project.Keynes 离线经济校验报告</title><style>
body{{font:14px/1.55 system-ui;margin:0;background:#111827;color:#e5e7eb}}main{{max-width:1400px;margin:auto;padding:28px}}
h1,h2{{color:#f9fafb}}.cards{{display:flex;gap:12px;flex-wrap:wrap}}.card{{background:#1f2937;padding:14px 18px;border-radius:10px}}
.verdict{{color:{'#f87171' if verdict == 'fail' else '#fbbf24' if verdict == 'warn' else '#34d399'}}}
section{{background:#172033;margin:16px 0;padding:18px;border-radius:12px}}table{{width:100%;border-collapse:collapse}}th,td{{padding:8px;border-bottom:1px solid #374151;text-align:right}}th:first-child,td:first-child{{text-align:left}}
.scroll{{overflow:auto}}code{{color:#93c5fd}}.muted{{color:#9ca3af}}</style></head><body><main>
<h1>Project.Keynes 离线经济数学校验</h1><p class='muted'>未启动 Godot；直接读取目录模型并求解参考稳态。</p>
<div class='cards'><div class='card'>结论<br><b class='verdict'>{verdict.upper()}</b></div><div class='card'>失败<br><b>{report['summary']['failures']}</b></div><div class='card'>警告<br><b>{report['summary']['warnings']}</b></div><div class='card'>求解残差<br><b>{fmt(report['solver'].get('residual_norm'))}</b></div><div class='card'>市场谱半径<br><b>{fmt(report['market_stability']['maximum_spectral_radius'])}</b></div></div>
<section><h2>结构审计</h2>{table(['级别','代码','实体','说明'], audit_rows)}</section>
<section><h2>自然资源</h2>{table(['资源','状态','期初储量','日采集','期初自然变化','替代率','判断'], resource_rows)}</section>
<section><h2>建筑</h2>{table(['建筑','利用率','承接收入','投入成本','工资','利润率','可持续'], building_rows)}</section>
<section><h2>阶层</h2>{table(['职业','人口','收入','消费','必要覆盖','储蓄'], cohort_rows)}</section>
<section><h2>商品市场</h2>{table(['物资','承接供给','需求','覆盖率'], good_rows)}</section>
<section><h2>自动建议</h2><ul>{recs}</ul></section>
<section><h2>口径限制</h2><ul>{''.join('<li>'+html.escape(x)+'</li>' for x in report['method']['limitations'])}</ul></section>
</main></body></html>"""


def ensure_model(args: argparse.Namespace, tool_dir: Path) -> Path:
    if args.model:
        return Path(args.model).resolve()
    output = Path(args.output_dir).resolve() / "compiled_model.json"
    exporter = tool_dir / "export_model.js"
    repo_root = Path(args.repo_root).resolve() if args.repo_root else tool_dir.parent.parent
    command = [args.node, str(exporter), "--repo-root", str(repo_root), "--output", str(output)]
    completed = subprocess.run(
        command, text=True, capture_output=True, check=False,
        encoding="utf-8", errors="replace",
    )
    if completed.returncode != 0:
        raise RuntimeError(f"模型导出失败: {completed.stderr or completed.stdout}")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description="Project.Keynes 离线经济数学验证器（不启动 Godot）")
    parser.add_argument("--scenario", required=True, help="场景 JSON")
    parser.add_argument("--model", help="已编译模型 JSON；省略时自动调用 export_model.js")
    parser.add_argument("--repo-root", help="Project.Keynes 仓库根目录")
    parser.add_argument("--output-dir", default="tmp/economy-balance", help="输出目录")
    parser.add_argument("--node", default="node", help="Node.js 可执行文件")
    args = parser.parse_args()
    tool_dir = Path(__file__).resolve().parent
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    try:
        model_path = ensure_model(args, tool_dir)
        model = json.loads(model_path.read_text(encoding="utf-8"))
        scenario = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
        report = BalanceValidator(model, scenario).run()
        safe_report = json_safe(report)
        json_path = output_dir / "balance_report.json"
        html_path = output_dir / "balance_report.html"
        json_path.write_text(json.dumps(safe_report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        html_path.write_text(make_html(report), encoding="utf-8")
        print(json.dumps({
            "verdict": report["summary"]["verdict"], "json": str(json_path), "html": str(html_path),
            "godot_started": False, "active_buildings": report["summary"]["active_buildings"],
        }, ensure_ascii=False))
        return 0 if report["summary"]["verdict"] != "fail" else 2
    except Exception as exc:  # CLI boundary: keep failures machine-readable.
        print(json.dumps({"error": str(exc), "godot_started": False}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
