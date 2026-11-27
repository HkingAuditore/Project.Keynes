extends RefCounted

const Inputs = preload("res://scripts/economy/bootstrap/test_start_inputs.gd")
const Finance = preload("res://scripts/economy/bootstrap/test_start_finance.gd")
const Policy = preload("res://scripts/economy/bootstrap/test_start_policy.gd")

const GOODS_SCALE = Policy.GOODS_SCALE
const Q16_ONE = Policy.Q16_ONE
const INT64_MAX = Policy.INT64_MAX
const COLLECTOR_COUNT_CAP = Policy.COLLECTOR_COUNT_CAP
const CELL_POPULATION_CAP = Policy.CELL_POPULATION_CAP
const RESOURCE_TIERED_POPULATION_SCALE = Policy.RESOURCE_TIERED_POPULATION_SCALE
const DEFAULT_POPULATION_SCALE = Policy.DEFAULT_POPULATION_SCALE
const SUPPORTED_POPULATION_SCALES = Policy.SUPPORTED_POPULATION_SCALES
const RESOURCE_TIER_SCALES = Policy.RESOURCE_TIER_SCALES
const INITIAL_RESOURCE_HORIZON_DAYS = Policy.INITIAL_RESOURCE_HORIZON_DAYS
const CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS = Policy.CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS
const FOOD_REQUIREMENT_PER_CAPITA = Policy.FOOD_REQUIREMENT_PER_CAPITA
const CLOTHING_REQUIREMENT_PER_CAPITA = Policy.CLOTHING_REQUIREMENT_PER_CAPITA
const SURVIVAL_FUND_DAYS = Policy.SURVIVAL_FUND_DAYS
const INITIAL_HOUSEHOLD_STOCK_DAYS = Policy.INITIAL_HOUSEHOLD_STOCK_DAYS
const INITIAL_BUILDING_INPUT_STOCK_DAYS = Policy.INITIAL_BUILDING_INPUT_STOCK_DAYS
const RESOURCE_BUILDING_RUNWAY_DAYS = Policy.RESOURCE_BUILDING_RUNWAY_DAYS
const RENEWABLE_SAFE_HARVEST_Q16 = Policy.RENEWABLE_SAFE_HARVEST_Q16
const RENEWABLE_MIN_RESERVE_Q16 = Policy.RENEWABLE_MIN_RESERVE_Q16
const RENEWABLE_GROWTH_DIVISOR = Policy.RENEWABLE_GROWTH_DIVISOR
const OWNER_OPERATING_CYCLES = Policy.OWNER_OPERATING_CYCLES
const PLANNED_UTILIZATION_Q16 = Policy.PLANNED_UTILIZATION_Q16
const TARGET_EMPLOYMENT_Q16 = Policy.TARGET_EMPLOYMENT_Q16
const INITIAL_CARRYING_CAPACITY_SHARE_Q16 = Policy.INITIAL_CARRYING_CAPACITY_SHARE_Q16
const BOOTSTRAP_BRIDGE_STOCK = Policy.BOOTSTRAP_BRIDGE_STOCK
const TEST_COLLECTOR_COUNT_CAPS = Policy.TEST_COLLECTOR_COUNT_CAPS
const TEST_INDUSTRY_COUNTS = Policy.TEST_INDUSTRY_COUNTS
const FOOD_GOOD_IDS = Policy.FOOD_GOOD_IDS
const CLOTHING_GOOD_IDS = Policy.CLOTHING_GOOD_IDS
const MID_STONE_TECHNOLOGY_IDS = Policy.MID_STONE_TECHNOLOGY_IDS

const CapacityInputs = preload("res://scripts/economy/bootstrap/test_settlement_capacity_inputs.gd")
const SettlementBalance = preload("res://scripts/economy/bootstrap/test_settlement_balance.gd")


static func build(map: Inputs, population_scale: int = 1) -> Dictionary:
	if population_scale not in SUPPORTED_POPULATION_SCALES:
		return {"ok": false, "reason": "test_bootstrap_population_scale_invalid", "population_scale": population_scale}
	var profession_ids: PackedStringArray = map.profession_ids
	var signatures: Dictionary = map.signatures
	var building_ids: PackedStringArray = map.building_ids
	var finance: Dictionary = map.finance
	var building_specs: Dictionary = map.building_specs
	var eligible_building_ids: PackedStringArray = map.eligible_building_ids.duplicate()
	var highest_tier_by_family := {}
	for building_id in eligible_building_ids:
		var spec: Dictionary = building_specs[StringName(building_id)]
		var family := String(spec.get("upgrade_family_id", ""))
		if family != "":
			highest_tier_by_family[family] = maxi(
				int(highest_tier_by_family.get(family, 0)), int(spec.get("upgrade_tier", 0)))
	var filtered_eligible := PackedStringArray()
	for building_id in eligible_building_ids:
		var spec: Dictionary = building_specs[StringName(building_id)]
		var family := String(spec.get("upgrade_family_id", ""))
		if String(building_id) in [
				"gathering_ground", "timber_collector", "stone_collector"] or \
				family == "" or int(spec.get("upgrade_tier", 0)) == int(
				highest_tier_by_family.get(family, 0)):
			filtered_eligible.append(building_id)
	eligible_building_ids = filtered_eligible
	if eligible_building_ids.is_empty():
		return {"ok": false, "reason": "test_bootstrap_mid_stone_catalog_empty"}

	var passable_cells: PackedInt32Array = map.passable_cells
	if passable_cells.is_empty():
		return {"ok": false, "reason": "test_bootstrap_no_passable_land"}
	var resource_arrays: Dictionary = map.resources
	var resource_peaks := CapacityInputs._resource_peaks(resource_arrays, passable_cells)
	var groups_by_cell := {}
	var outputs_by_cell := {}
	for cell_idx in passable_cells:
		groups_by_cell[cell_idx] = []
		outputs_by_cell[cell_idx] = {}

	for building_id_raw in eligible_building_ids:
		var building_id := StringName(building_id_raw)
		var spec: Dictionary = building_specs[building_id]
		if int(spec.kind) != 0:
			continue
		for cell_idx in passable_cells:
			var count := CapacityInputs._collector_count_at(
				spec, cell_idx, resource_arrays, resource_peaks)
			if count <= 0:
				continue
			(groups_by_cell[cell_idx] as Array).append({"spec": spec, "count": count})
			CapacityInputs._mark_outputs(spec, outputs_by_cell[cell_idx])
	# 常规聚落规模仍按十年储量计算；建设根建筑只要求一年跑道，避免有真实
	# 资源但不足十年连续满负荷的地图被误判为空经济。
	var source_root_fallback_counts := SettlementBalance._ensure_construction_source_roots(
		passable_cells, groups_by_cell, outputs_by_cell, building_specs,
		resource_arrays, resource_peaks)

	# Protect one local gathering root wherever the resource placement pass made
	# it physically valid. This root is part of the initial settlement, so later
	# copies still pay the catalog's non-zero construction bill.
	var gathering_spec: Dictionary = building_specs.get(&"gathering_ground", {})
	for cell_idx in passable_cells:
		var groups: Array = groups_by_cell[cell_idx]
		if groups.is_empty():
			continue
		var gathering_group := CapacityInputs._find_group(groups, &"gathering_ground")
		if gathering_group.is_empty() and not gathering_spec.is_empty() and \
				CapacityInputs._collector_count_at(gathering_spec, cell_idx,
					resource_arrays, resource_peaks) > 0:
			gathering_group = {
				"spec": gathering_spec,
				"count": 1,
			}
			groups.append(gathering_group)
			CapacityInputs._mark_outputs(gathering_spec, outputs_by_cell[cell_idx])
		if not gathering_group.is_empty():
			gathering_group["bootstrap_root"] = true
			gathering_group["bootstrap_min_count"] = 1
	# Only source-complete trade regions may become initial settlements. Random
	# maps commonly contain isolated resource-bearing islands; leaving those
	# regions empty is valid, while seeding population there would create the
	# permanently closed economy this preflight is intended to prevent.
	var source_report := SettlementBalance._protect_construction_sources(
		map, passable_cells, groups_by_cell, outputs_by_cell, true)
	if not bool(source_report.get("ok", false)):
		source_report["source_diagnostics"] = SettlementBalance._construction_source_diagnostics(
			passable_cells, groups_by_cell, resource_arrays, resource_peaks,
			source_root_fallback_counts)
		return source_report
	var skipped_source_components: Array = source_report.get(
		"skipped_components", []).duplicate(true)
	var source_components: Array = source_report.get("components", []).duplicate(true)
	var source_candidate_component_count := int(source_report.get(
		"candidate_component_count", 0))

	var pending_industries := []
	for building_id_raw in eligible_building_ids:
		var building_id := StringName(building_id_raw)
		var spec: Dictionary = building_specs[building_id]
		if int(spec.kind) == 1:
			pending_industries.append(spec)
	while not pending_industries.is_empty():
		var placed_any := false
		for i in range(pending_industries.size() - 1, -1, -1):
			var spec: Dictionary = pending_industries[i]
			var selected_cells := PackedInt32Array()
			for cell_idx in passable_cells:
				if CapacityInputs._inputs_ready(spec, outputs_by_cell[cell_idx]):
					selected_cells.append(cell_idx)
			if selected_cells.is_empty():
				continue
			pending_industries.remove_at(i)
			placed_any = true
			for cell_idx in selected_cells:
				var count := maxi(1, int(TEST_INDUSTRY_COUNTS.get(
					String(spec.get("stable_id", "")), 1)))
				(groups_by_cell[cell_idx] as Array).append({"spec": spec, "count": count})
				CapacityInputs._mark_outputs(spec, outputs_by_cell[cell_idx])
		if not placed_any:
			break
	# Keep a frozen regional candidate graph. The normal path below remains
	# strictly cell-local; this copy is used only if that stricter pass erases
	# every source-complete trade component merely because its food, clothing,
	# tools and construction roots live on different cells.
	var regional_groups_fallback: Dictionary = groups_by_cell.duplicate(true)

	var merchant_post_spec: Dictionary = building_specs.get(StringName(Policy.MERCHANT_BUILDING_ID), {})
	var merchant_post_available := not merchant_post_spec.is_empty() \
		and Policy.building_available(merchant_post_spec)
	if not merchant_post_available:
		return {"ok": false, "reason": "bootstrap_merchant_root_missing"}
	var basic_capacity_initial_buildings := 0
	var basic_capacity_trimmed_buildings := 0
	var basic_capacity_deficient_cells := 0
	var carrying_capacity_cell_indices := PackedInt32Array()
	var carrying_capacity_population := PackedInt64Array()
	var carrying_capacity_min := CELL_POPULATION_CAP
	var carrying_capacity_max := 0
	var carrying_capacity_total := 0
	var basic_capacity_cell_indices := PackedInt32Array()
	var basic_capacity_population := PackedInt64Array()
	var basic_food_capacity := PackedInt64Array()
	var basic_clothing_capacity := PackedInt64Array()
	var chain_input_coverage_q16 := PackedInt32Array()
	for cell_idx in passable_cells:
		# Every locally valid catalog chain is part of the initial economy. Keep
		# at least one of each type while trimming only redundant copies.
		for group in groups_by_cell[cell_idx]:
			group["bootstrap_min_count"] = maxi(
				1, int(group.get("bootstrap_min_count", 0)))
		for group in groups_by_cell[cell_idx]:
			basic_capacity_initial_buildings += maxi(0, int(group.count))
		var reserved_population := 1 if merchant_post_available and not \
			(groups_by_cell[cell_idx] as Array).is_empty() else 0
		var balance := SettlementBalance._balance_basic_capacity(
			groups_by_cell[cell_idx], reserved_population)
		basic_capacity_trimmed_buildings += int(balance.trimmed_buildings)
		carrying_capacity_cell_indices.append(cell_idx)
		var target_population := int(balance.target_population)
		carrying_capacity_population.append(target_population)
		carrying_capacity_min = mini(carrying_capacity_min, target_population)
		carrying_capacity_max = maxi(carrying_capacity_max, target_population)
		carrying_capacity_total += target_population
		if not bool(balance.covered):
			basic_capacity_deficient_cells += 1
		var totals: Dictionary = balance.totals
		chain_input_coverage_q16.append(int(balance.input_coverage_q16))
		if int(totals.population) > 0:
			basic_capacity_cell_indices.append(cell_idx)
			basic_capacity_population.append(target_population)
			basic_food_capacity.append(int(totals.food))
			basic_clothing_capacity.append(int(totals.clothing))
	# Capacity pruning must not silently erase the only regional construction
	# source. Revalidate the actual final root set used to build the packets.
	source_report = SettlementBalance._protect_construction_sources(
		map, passable_cells, groups_by_cell)
	var regional_capacity_fallback := false
	var regional_capacity_fallback_cells := 0
	if not bool(source_report.get("ok", false)):
		var fallback := SettlementBalance._prepare_regional_capacity_fallback(
			regional_groups_fallback, source_components)
		if not bool(fallback.get("ok", false)):
			source_report["source_diagnostics"] = SettlementBalance._construction_source_diagnostics(
				passable_cells, groups_by_cell, resource_arrays, resource_peaks,
				source_root_fallback_counts)
			source_report["regional_fallback"] = fallback
			return source_report
		groups_by_cell = fallback.groups_by_cell
		skipped_source_components.append_array(
			fallback.get("skipped_components", []))
		regional_capacity_fallback = true
		regional_capacity_fallback_cells = int(fallback.populated_cells)
		basic_capacity_initial_buildings = 0
		basic_capacity_trimmed_buildings = 0
		basic_capacity_deficient_cells = 0
		carrying_capacity_cell_indices.clear()
		carrying_capacity_population.clear()
		basic_capacity_cell_indices.clear()
		basic_capacity_population.clear()
		basic_food_capacity.clear()
		basic_clothing_capacity.clear()
		chain_input_coverage_q16.clear()
		var fallback_targets: Dictionary = fallback.target_population_by_cell
		var fallback_coverage: Dictionary = fallback.input_coverage_q16_by_cell
		for cell_idx in passable_cells:
			var groups: Array = groups_by_cell[cell_idx]
			for group in groups:
				basic_capacity_initial_buildings += maxi(0, int(group.count))
			var target_population := int(fallback_targets.get(cell_idx, 0))
			var totals := CapacityInputs._basic_capacity_totals(groups, 1 if not groups.is_empty() else 0)
			carrying_capacity_cell_indices.append(cell_idx)
			carrying_capacity_population.append(target_population)
			chain_input_coverage_q16.append(int(fallback_coverage.get(cell_idx, 0)))
			if target_population > 0:
				basic_capacity_cell_indices.append(cell_idx)
				basic_capacity_population.append(target_population)
				basic_food_capacity.append(int(totals.food))
				basic_clothing_capacity.append(int(totals.clothing))
		source_report = SettlementBalance._protect_construction_sources(
			map, passable_cells, groups_by_cell)
		if not bool(source_report.get("ok", false)):
			return source_report
	source_report["skipped_components"] = skipped_source_components
	source_report["components"] = CapacityInputs._construction_source_component_summaries(
		source_report.get("components", []))

	# Capacity balancing remains physically calibrated. Resource-tiered mode
	# ranks viable settlements by that capacity, hard-input coverage, and local
	# visible resource abundance, then assigns deterministic quartile scales.
	# Explicit stress scales may expand unemployed population for load testing.
	# The normal resource-tiered fixture is capped again by its generated jobs
	# below, after demand and resource-safe building counts have converged.
	var capacity_calibrated_population := carrying_capacity_population.duplicate()
	var resource_population_scores := CapacityInputs._resource_population_scores(
		carrying_capacity_cell_indices, capacity_calibrated_population,
		chain_input_coverage_q16, resource_arrays, resource_peaks)
	var population_scales_by_cell := CapacityInputs._population_scales_by_resource(
		carrying_capacity_cell_indices, capacity_calibrated_population,
		resource_population_scores) if population_scale == \
		RESOURCE_TIERED_POPULATION_SCALE else CapacityInputs._uniform_population_scales(
			carrying_capacity_population.size(), population_scale)
	var maximum_population_scale := RESOURCE_TIER_SCALES[-1] \
		if population_scale == RESOURCE_TIERED_POPULATION_SCALE else population_scale
	var scaled_cell_population_cap := CELL_POPULATION_CAP * maximum_population_scale
	for i in range(carrying_capacity_population.size()):
		carrying_capacity_population[i] = mini(
			int(carrying_capacity_population[i]) * int(population_scales_by_cell[i]),
			scaled_cell_population_cap)
	var population_tier_counts := CapacityInputs._population_tier_counts(
		capacity_calibrated_population, population_scales_by_cell)
	SettlementBalance._rebalance_building_groups(groups_by_cell, carrying_capacity_cell_indices,
		carrying_capacity_population, population_scales_by_cell, finance,
		resource_arrays, map.resource_rules)

	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var populated_cells := PackedInt32Array()
	var total_population := 0
	var total_unemployed_population := 0
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	var generated_professions := {}
	var placed_building_types := {}
	var merchant_bootstrap_substitutions := 0
	var owner_daily_input_cost_by_key := {}
	var merchant_daily_inventory_value_by_cell := {}
	var job_capacity_by_cell := PackedInt64Array()
	job_capacity_by_cell.resize(carrying_capacity_population.size())
	var job_limited_population_trimmed := 0
	var job_limited_cells := 0

	# Route B: every populated cell gets exactly one merchant post (商栈). Its
	# owner (merchant) is the cell's market maker and now lives inside the
	# employment system as a real building owner. A cell has population iff it
	# already holds at least one collector/industrial group, so we attach the
	# post to those cells. This replaces the old "carve a merchant out of the
	# largest non-merchant profession" substitution (189-199 below): the post's
	# owner accumulates merchant jobs directly, so that path stops firing.
	for cell_idx in passable_cells:
		var generated_groups: Array = groups_by_cell[cell_idx]
		if generated_groups.is_empty():
			continue
		if merchant_post_available:
			# A merchant post is cell-level market infrastructure, not a
			# population-scaled producer. One post supplies the invariant market
			# maker; additional merchants must be justified by runtime demand.
			generated_groups.append({"spec": merchant_post_spec, "count": 1})
		generated_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.spec.type_id) < int(b.spec.type_id))
		for group in generated_groups:
			var job_spec: Dictionary = group.spec
			var count := int(group.count)
			var owner_signature := int(signatures.get(StringName(job_spec.owner_profession), -1))
			CapacityInputs._append_building_group(building_cells, building_types, building_owners,
				building_counts, cell_idx, int(job_spec.type_id),
				owner_signature, count)
			var owner_key := "%d:%d" % [cell_idx, owner_signature]
			owner_daily_input_cost_by_key[owner_key] = int(
				owner_daily_input_cost_by_key.get(owner_key, 0)) + \
				Finance.default_input_cost_per_day(job_spec, finance) * count
			merchant_daily_inventory_value_by_cell[cell_idx] = int(
				merchant_daily_inventory_value_by_cell.get(cell_idx, 0)) + \
				Finance.default_output_inventory_value_per_day(job_spec, finance) * count
			placed_building_types[StringName(job_spec.stable_id)] = true

		var jobs_by_profession := {}
		for group in generated_groups:
			CapacityInputs._accumulate_building_jobs(group.spec, int(group.count), jobs_by_profession)
		if int(jobs_by_profession.get(&"merchant", 0)) <= 0:
			var merchant_source := CapacityInputs._largest_nonmerchant_profession(
				jobs_by_profession, profession_ids)
			if merchant_source != &"":
				jobs_by_profession[merchant_source] = \
					int(jobs_by_profession.get(merchant_source, 0)) - 1
				jobs_by_profession[&"merchant"] = 1
				merchant_bootstrap_substitutions += 1
		var capacity_idx := carrying_capacity_cell_indices.find(cell_idx)
		var target_population := int(carrying_capacity_population[capacity_idx]) \
			if capacity_idx >= 0 else 0
		var job_capacity := 0
		for profession in jobs_by_profession:
			job_capacity = Finance.sat_add_nonnegative(
				job_capacity, maxi(0, int(jobs_by_profession[profession])))
		if capacity_idx >= 0:
			job_capacity_by_cell[capacity_idx] = job_capacity
		if population_scale == RESOURCE_TIERED_POPULATION_SCALE and \
				target_population > 0:
			var job_limited_population := job_capacity * Q16_ONE / \
				TARGET_EMPLOYMENT_Q16
			if job_limited_population < target_population:
				job_limited_population_trimmed += \
					target_population - job_limited_population
				job_limited_cells += 1
				target_population = job_limited_population
				carrying_capacity_population[capacity_idx] = target_population
		var actual_population := 0
		if target_population > 0 and int(jobs_by_profession.get(&"merchant", 0)) > 0:
			var merchant_population := mini(
				int(jobs_by_profession.get(&"merchant", 0)), target_population)
			cell_indices.append(cell_idx)
			signature_ids.append(int(signatures[&"merchant"]))
			populations.append(merchant_population)
			funds.append(0)
			actual_population = merchant_population
			generated_professions[&"merchant"] = true
		for profession_id in profession_ids:
			var profession := StringName(profession_id)
			if profession == &"merchant" or profession == &"unemployed":
				continue
			var population := int(jobs_by_profession.get(profession, 0))
			population = mini(population, maxi(0, target_population - actual_population))
			if population <= 0:
				continue
			cell_indices.append(cell_idx)
			signature_ids.append(int(signatures[profession]))
			populations.append(population)
			funds.append(0)
			actual_population += population
			generated_professions[profession] = true
		var unemployed := maxi(0, target_population - actual_population)
		if unemployed > 0 and signatures.has(&"unemployed"):
			cell_indices.append(cell_idx)
			signature_ids.append(int(signatures[&"unemployed"]))
			populations.append(unemployed)
			funds.append(0)
			actual_population += unemployed
			generated_professions[&"unemployed"] = true
			total_unemployed_population += unemployed
		if actual_population > 0:
			if not CapacityInputs._has_survival_food_root(generated_groups):
				if regional_capacity_fallback:
					populated_cells.append(cell_idx)
					total_population += actual_population
					continue
				return {
					"ok": false,
					"reason": "bootstrap_survival_root_missing",
					"cell_idx": cell_idx,
				}
			populated_cells.append(cell_idx)
			total_population += actual_population

	carrying_capacity_min = scaled_cell_population_cap
	carrying_capacity_max = 0
	carrying_capacity_total = 0
	for population in carrying_capacity_population:
		carrying_capacity_min = mini(carrying_capacity_min, int(population))
		carrying_capacity_max = maxi(carrying_capacity_max, int(population))
		carrying_capacity_total += int(population)
	var total_job_capacity := 0
	for job_capacity in job_capacity_by_cell:
		total_job_capacity = Finance.sat_add_nonnegative(
			total_job_capacity, maxi(0, int(job_capacity)))
	var initial_job_coverage_q16 := Q16_ONE if total_population <= 0 else \
		mini(Q16_ONE, total_job_capacity * Q16_ONE / total_population)

	var cycle_days: int = map.cycle_days
	var initial_survival_funds := 0
	var initial_owner_operating_funds := 0
	var initial_merchant_inventory_funds := 0
	var survival_funds_by_cohort := PackedInt64Array()
	var owner_operating_funds_by_cohort := PackedInt64Array()
	var merchant_inventory_funds_by_cohort := PackedInt64Array()
	var merchant_signature := int(signatures.get(&"merchant", -1))
	for cohort in range(populations.size()):
		var cell_idx := int(cell_indices[cohort])
		var signature_id := int(signature_ids[cohort])
		var survival := Finance.sat_mul_nonnegative(Finance.sat_mul_nonnegative(
			Finance.survival_cost_per_person_per_day(map, cell_idx, signature_id, finance),
			int(populations[cohort])), SURVIVAL_FUND_DAYS)
		var owner := Finance.sat_mul_nonnegative(Finance.sat_mul_nonnegative(int(
			owner_daily_input_cost_by_key.get("%d:%d" % [cell_idx, signature_id], 0)),
			cycle_days), OWNER_OPERATING_CYCLES) * PLANNED_UTILIZATION_Q16 / Q16_ONE
		var merchant := int(merchant_daily_inventory_value_by_cell.get(cell_idx, 0)) \
			if signature_id == merchant_signature else 0
		funds[cohort] = Finance.sat_add_nonnegative(
			Finance.sat_add_nonnegative(survival, owner), merchant)
		survival_funds_by_cohort.append(survival)
		owner_operating_funds_by_cohort.append(owner)
		merchant_inventory_funds_by_cohort.append(merchant)
		initial_survival_funds = Finance.sat_add_nonnegative(initial_survival_funds, survival)
		initial_owner_operating_funds = Finance.sat_add_nonnegative(
			initial_owner_operating_funds, owner)
		initial_merchant_inventory_funds = Finance.sat_add_nonnegative(
			initial_merchant_inventory_funds, merchant)
	var bootstrap_market := Finance.bootstrap_market_packet(
		map, finance, cell_indices, signature_ids, populations,
		groups_by_cell, populated_cells, cycle_days)

	return {
		"ok": true,
		"population_packet": {
			"cell_indices": cell_indices,
			"signature_ids": signature_ids,
			"population": populations,
			"funds": funds,
		},
		"market_packet": bootstrap_market.packet,
		"building_packet": {
			"building_cells": building_cells,
			"building_type_ids": building_types,
			"building_owner_signature_ids": building_owners,
			"building_counts": building_counts,
		},
		"populated_cells": populated_cells.size(),
		"cohort_count": populations.size(),
		"building_group_count": building_counts.size(),
		"total_population": total_population,
		"target_population": carrying_capacity_total,
		"minimum_building_count":
			basic_capacity_initial_buildings - basic_capacity_trimmed_buildings,
		"initial_unemployed_population": total_unemployed_population,
		"chain_input_coverage_q16": chain_input_coverage_q16,
		"population_source": "resource_tiered_complete_chain_test_bootstrap_v21",
		"collector_placement_model": "resource_backed_complete_chain_v18",
		"initial_resource_horizon_days": INITIAL_RESOURCE_HORIZON_DAYS,
		"construction_source_min_horizon_days":
			CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS,
		"construction_source_root_fallback_counts":
			source_root_fallback_counts,
		"cell_population_cap": scaled_cell_population_cap,
		"capacity_calibrated_cell_population_cap": CELL_POPULATION_CAP,
		"population_scale": population_scale,
		"population_scale_mode": "resource_tiered" if population_scale == \
			RESOURCE_TIERED_POPULATION_SCALE else (
				"capacity" if population_scale == 1 else "uniform_stress"),
		"population_scales_by_cell": population_scales_by_cell,
		"population_tier_counts": population_tier_counts,
		"resource_population_scores": resource_population_scores,
		"building_scale_model": "household_demand_input_fixed_point_safe_yield_v2",
		"resource_building_runway_days": RESOURCE_BUILDING_RUNWAY_DAYS,
		"renewable_safe_harvest_q16": RENEWABLE_SAFE_HARVEST_Q16,
		"renewable_harvest_model": "reserve_responsive_safe_yield_v1",
		"planned_utilization_q16": PLANNED_UTILIZATION_Q16,
		"target_employment_q16": TARGET_EMPLOYMENT_Q16,
		"job_capacity_by_cell": job_capacity_by_cell,
		"total_job_capacity": total_job_capacity,
		"initial_job_coverage_q16": initial_job_coverage_q16,
		"employment_acceptance_ok": population_scale != \
			RESOURCE_TIERED_POPULATION_SCALE or \
			initial_job_coverage_q16 >= TARGET_EMPLOYMENT_Q16,
		"job_limited_population_trimmed": job_limited_population_trimmed,
		"job_limited_cells": job_limited_cells,
		"initial_employment": "unemployed",
		"initial_stock_units": int(bootstrap_market.total_stock),
		"initial_household_stock_units": int(bootstrap_market.household_stock),
		"initial_building_input_stock_units": int(bootstrap_market.building_input_stock),
		"initial_bridge_stock_units": int(bootstrap_market.bridge_stock),
		"initial_household_stock_days": INITIAL_HOUSEHOLD_STOCK_DAYS,
		"initial_building_input_stock_days": INITIAL_BUILDING_INPUT_STOCK_DAYS,
		"bootstrap_bridge_stock_per_market": BOOTSTRAP_BRIDGE_STOCK.duplicate(),
		"bootstrap_root_building_counts": {
			Policy.MERCHANT_BUILDING_ID: populated_cells.size(),
			"gathering_ground": CapacityInputs._count_buildings(
				groups_by_cell, &"gathering_ground"),
			"timber_collector": CapacityInputs._count_buildings(
				groups_by_cell, &"timber_collector"),
			"stone_collector": CapacityInputs._count_buildings(
				groups_by_cell, &"stone_collector"),
		},
		"construction_closure_ok": true,
		"construction_source_component_count": int(
			source_report.get("component_count", 0)),
		"construction_source_candidate_component_count":
			source_candidate_component_count,
		"construction_source_components": source_report.get("components", []),
		"construction_source_skipped_components": source_report.get(
			"skipped_components", []),
		"regional_capacity_fallback": regional_capacity_fallback,
		"regional_capacity_fallback_cells": regional_capacity_fallback_cells,
		"bootstrap_cycle_days": cycle_days,
		"survival_fund_days": SURVIVAL_FUND_DAYS,
		"owner_operating_cycles": OWNER_OPERATING_CYCLES,
		"initial_carrying_capacity_share_q16": INITIAL_CARRYING_CAPACITY_SHARE_Q16,
		"initial_survival_funds": initial_survival_funds,
		"initial_owner_operating_funds": initial_owner_operating_funds,
		"initial_merchant_inventory_funds": initial_merchant_inventory_funds,
		"survival_funds_by_cohort": survival_funds_by_cohort,
		"owner_operating_funds_by_cohort": owner_operating_funds_by_cohort,
		"merchant_inventory_funds_by_cohort": merchant_inventory_funds_by_cohort,
		"merchant_bootstrap_substitutions": merchant_bootstrap_substitutions,
		"technology_ids": PackedStringArray(MID_STONE_TECHNOLOGY_IDS),
		"visible_resource_type_count": resource_arrays.size(),
		"building_type_count": building_ids.size(),
		"eligible_building_type_count": eligible_building_ids.size(),
		"placed_building_type_count": placed_building_types.size(),
		"unplaced_building_type_count": building_ids.size() - placed_building_types.size(),
		"catalog_profession_count": profession_ids.size(),
		"generated_profession_count": generated_professions.size(),
		"basic_capacity_initial_buildings": basic_capacity_initial_buildings,
		"basic_capacity_final_buildings":
			basic_capacity_initial_buildings - basic_capacity_trimmed_buildings,
		"basic_capacity_trimmed_buildings": basic_capacity_trimmed_buildings,
		"basic_capacity_deficient_cells": basic_capacity_deficient_cells,
		"carrying_capacity_cell_indices": carrying_capacity_cell_indices,
		"carrying_capacity_population": carrying_capacity_population,
		"capacity_calibrated_population": capacity_calibrated_population,
		"carrying_capacity_min": carrying_capacity_min,
		"carrying_capacity_max": carrying_capacity_max,
		"carrying_capacity_total": carrying_capacity_total,
		"food_requirement_per_capita": FOOD_REQUIREMENT_PER_CAPITA,
		"clothing_requirement_per_capita": CLOTHING_REQUIREMENT_PER_CAPITA,
		"basic_capacity_cell_indices": basic_capacity_cell_indices,
		"basic_capacity_population": basic_capacity_population,
		"basic_food_capacity": basic_food_capacity,
		"basic_clothing_capacity": basic_clothing_capacity,
		"good_count": (finance.good_ids as PackedStringArray).size(),
	}


static func _prepare_regional_capacity_fallback(
		candidate_groups_by_cell: Dictionary, source_components: Array) -> Dictionary:
	return SettlementBalance._prepare_regional_capacity_fallback(
		candidate_groups_by_cell, source_components)
