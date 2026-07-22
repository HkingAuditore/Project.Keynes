class_name EconomyTestBootstrap
extends RefCounted

const GOODS_SCALE := 1000
const Q16_ONE := 65536
const INT64_MAX := 9223372036854775807
const COLLECTOR_COUNT_CAP := 24
const CELL_POPULATION_CAP := 300
const INITIAL_RESOURCE_HORIZON_DAYS := 3650
const CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS := 365
const FOOD_REQUIREMENT_PER_CAPITA := 1300
const CLOTHING_REQUIREMENT_PER_CAPITA := 4
const SURVIVAL_FUND_DAYS := 30
const OWNER_OPERATING_CYCLES := 2
const PLANNED_UTILIZATION_Q16 := 49152
const INITIAL_CARRYING_CAPACITY_SHARE_Q16 := 32768
const BOOTSTRAP_BRIDGE_STOCK := {
	"logs": 1000,
	"gathered_plants": 250,
	"flint": 500,
}

const TEST_COLLECTOR_COUNT_CAPS := {
	"flint_quarry": 1,
	"household_weaving_shelter": 2,
	"placer_gold_working": 1,
	"stone_age_hunting_camp": 12,
	"stone_collector": 1,
	"surface_silver_working": 1,
	"timber_collector": 3,
}

const TEST_INDUSTRY_COUNTS := {
	"communal_hearth": 2,
	"knapping_workshop": 2,
}

const MID_STONE_EXCLUDED_BUILDING_IDS := {
	"lumber_plant": true,
}

const FOOD_GOOD_IDS := {
	"prepared_staples": true, "bread": true, "grain": true, "gathered_plants": true,
	"game_meat": true, "meat": true, "fish": true, "canned_fish": true,
	"dairy_products": true, "vegetables": true, "processed_food": true,
}
const CLOTHING_GOOD_IDS := {
	"cloth": true, "fur": true, "clothing": true, "footwear": true,
}

const MID_STONE_TECHNOLOGY_IDS := [
	"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control",
]


static func build(map: MapData, facade: EconomyFacade, _seed: int) -> Dictionary:
	if map == null or facade == null or not facade.is_configured():
		return {"ok": false, "reason": "test_bootstrap_runtime_unavailable"}
	var profession_ids := facade.profession_ids()
	var signatures := {}
	for profession_id in profession_ids:
		var signature := facade.signature_id(StringName(profession_id), &"default")
		if signature < 0:
			return {
				"ok": false,
				"reason": "test_bootstrap_catalog_incomplete",
				"missing_signature": "%s|default" % String(profession_id),
			}
		signatures[StringName(profession_id)] = signature
	var building_ids := facade.building_type_ids()
	var finance: Dictionary = facade.bootstrap_finance_columns()
	var finance_good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	for bridge_good in BOOTSTRAP_BRIDGE_STOCK:
		if finance_good_ids.find(String(bridge_good)) < 0:
			return {
				"ok": false,
				"reason": "test_bootstrap_bridge_good_missing",
				"good_id": String(bridge_good),
			}
	if building_ids.is_empty():
		return {"ok": false, "reason": "test_bootstrap_building_catalog_empty"}
	var building_specs := {}
	var eligible_building_ids := PackedStringArray()
	for building_id in building_ids:
		var job_spec: Dictionary = facade.building_job_spec(StringName(building_id))
		var placement_spec: Dictionary = facade.building_placement_spec(StringName(building_id))
		if not bool(job_spec.get("ok", false)) or not bool(placement_spec.get("ok", false)):
			return {
				"ok": false,
				"reason": "test_bootstrap_building_catalog_incomplete",
				"missing_building": String(building_id),
			}
		for key in placement_spec:
			job_spec[key] = placement_spec[key]
		building_specs[StringName(building_id)] = job_spec
		if _technology_available(placement_spec.technology_tags) and not \
			MID_STONE_EXCLUDED_BUILDING_IDS.has(String(building_id)):
			eligible_building_ids.append(building_id)
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

	var passable_cells := PackedInt32Array()
	for cell_idx in range(map.cell_count()):
		var terrain := _terrain_at(map, cell_idx)
		if not MapData.terrain_is_water(terrain) and TerrainType.is_passable_land(terrain):
			passable_cells.append(cell_idx)
	if passable_cells.is_empty():
		return {"ok": false, "reason": "test_bootstrap_no_passable_land"}
	var resource_arrays := _resource_arrays(map, PackedStringArray(MID_STONE_TECHNOLOGY_IDS))
	var resource_peaks := _resource_peaks(resource_arrays, passable_cells)
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
			var count := _collector_count_at(
				spec, cell_idx, resource_arrays, resource_peaks)
			if count <= 0:
				continue
			(groups_by_cell[cell_idx] as Array).append({"spec": spec, "count": count})
			_mark_outputs(spec, outputs_by_cell[cell_idx])
	# 常规聚落规模仍按十年储量计算；建设根建筑只要求一年跑道，避免有真实
	# 资源但不足十年连续满负荷的地图被误判为空经济。
	var source_root_fallback_counts := _ensure_construction_source_roots(
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
		var gathering_group := _find_group(groups, &"gathering_ground")
		if gathering_group.is_empty() and not gathering_spec.is_empty() and \
				_collector_count_at(gathering_spec, cell_idx,
					resource_arrays, resource_peaks) > 0:
			gathering_group = {
				"spec": gathering_spec,
				"count": 1,
			}
			groups.append(gathering_group)
			_mark_outputs(gathering_spec, outputs_by_cell[cell_idx])
		if not gathering_group.is_empty():
			gathering_group["bootstrap_root"] = true
			gathering_group["bootstrap_min_count"] = 1
	# Only source-complete trade regions may become initial settlements. Random
	# maps commonly contain isolated resource-bearing islands; leaving those
	# regions empty is valid, while seeding population there would create the
	# permanently closed economy this preflight is intended to prevent.
	var source_report := _protect_construction_sources(
		map, passable_cells, groups_by_cell, outputs_by_cell, true)
	if not bool(source_report.get("ok", false)):
		source_report["source_diagnostics"] = _construction_source_diagnostics(
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
				if _inputs_ready(spec, outputs_by_cell[cell_idx]):
					selected_cells.append(cell_idx)
			if selected_cells.is_empty():
				continue
			pending_industries.remove_at(i)
			placed_any = true
			for cell_idx in selected_cells:
				var count := maxi(1, int(TEST_INDUSTRY_COUNTS.get(
					String(spec.get("stable_id", "")), 1)))
				(groups_by_cell[cell_idx] as Array).append({"spec": spec, "count": count})
				_mark_outputs(spec, outputs_by_cell[cell_idx])
		if not placed_any:
			break
	# Keep a frozen regional candidate graph. The normal path below remains
	# strictly cell-local; this copy is used only if that stricter pass erases
	# every source-complete trade component merely because its food, clothing,
	# tools and construction roots live on different cells.
	var regional_groups_fallback: Dictionary = groups_by_cell.duplicate(true)

	var merchant_post_spec: Dictionary = building_specs.get(&"merchant_post", {})
	var merchant_post_available := not merchant_post_spec.is_empty() \
		and _technology_available(merchant_post_spec.get("technology_tags", PackedStringArray()))
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
		_prune_nonessential_groups(groups_by_cell[cell_idx])
		for group in groups_by_cell[cell_idx]:
			basic_capacity_initial_buildings += maxi(0, int(group.count))
		var reserved_population := 1 if merchant_post_available and not \
			(groups_by_cell[cell_idx] as Array).is_empty() else 0
		var balance := _balance_basic_capacity(
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
	source_report = _protect_construction_sources(
		map, passable_cells, groups_by_cell)
	var regional_capacity_fallback := false
	var regional_capacity_fallback_cells := 0
	if not bool(source_report.get("ok", false)):
		var fallback := _prepare_regional_capacity_fallback(
			regional_groups_fallback, source_components)
		if not bool(fallback.get("ok", false)):
			source_report["source_diagnostics"] = _construction_source_diagnostics(
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
			var totals := _basic_capacity_totals(groups, 1 if not groups.is_empty() else 0)
			carrying_capacity_cell_indices.append(cell_idx)
			carrying_capacity_population.append(target_population)
			chain_input_coverage_q16.append(int(fallback_coverage.get(cell_idx, 0)))
			if target_population > 0:
				basic_capacity_cell_indices.append(cell_idx)
				basic_capacity_population.append(target_population)
				basic_food_capacity.append(int(totals.food))
				basic_clothing_capacity.append(int(totals.clothing))
		source_report = _protect_construction_sources(
			map, passable_cells, groups_by_cell)
		if not bool(source_report.get("ok", false)):
			return source_report
	source_report["skipped_components"] = skipped_source_components
	source_report["components"] = _construction_source_component_summaries(
		source_report.get("components", []))

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
			generated_groups.append({"spec": merchant_post_spec, "count": 1})
		generated_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.spec.type_id) < int(b.spec.type_id))
		for group in generated_groups:
			var job_spec: Dictionary = group.spec
			var count := int(group.count)
			var owner_signature := facade.signature_id(
				StringName(job_spec.owner_profession), &"default")
			_append_building_group(building_cells, building_types, building_owners,
				building_counts, cell_idx, int(job_spec.type_id),
				owner_signature, count)
			var owner_key := "%d:%d" % [cell_idx, owner_signature]
			owner_daily_input_cost_by_key[owner_key] = int(
				owner_daily_input_cost_by_key.get(owner_key, 0)) + \
				_default_input_cost_per_day(job_spec, finance) * count
			merchant_daily_inventory_value_by_cell[cell_idx] = int(
				merchant_daily_inventory_value_by_cell.get(cell_idx, 0)) + \
				_default_output_inventory_value_per_day(job_spec, finance) * count
			placed_building_types[StringName(job_spec.stable_id)] = true

		var jobs_by_profession := {}
		for group in generated_groups:
			_accumulate_building_jobs(group.spec, int(group.count), jobs_by_profession)
		if int(jobs_by_profession.get(&"merchant", 0)) <= 0:
			var merchant_source := _largest_nonmerchant_profession(
				jobs_by_profession, profession_ids)
			if merchant_source != &"":
				jobs_by_profession[merchant_source] = \
					int(jobs_by_profession.get(merchant_source, 0)) - 1
				jobs_by_profession[&"merchant"] = 1
				merchant_bootstrap_substitutions += 1
		var capacity_idx := carrying_capacity_cell_indices.find(cell_idx)
		var target_population := int(carrying_capacity_population[capacity_idx]) \
			if capacity_idx >= 0 else 0
		var actual_population := 0
		if target_population > 0 and int(jobs_by_profession.get(&"merchant", 0)) > 0:
			cell_indices.append(cell_idx)
			signature_ids.append(int(signatures[&"merchant"]))
			populations.append(1)
			funds.append(0)
			actual_population = 1
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
			if not _has_survival_food_root(generated_groups):
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

	carrying_capacity_min = CELL_POPULATION_CAP
	carrying_capacity_max = 0
	carrying_capacity_total = 0
	for population in carrying_capacity_population:
		carrying_capacity_min = mini(carrying_capacity_min, int(population))
		carrying_capacity_max = maxi(carrying_capacity_max, int(population))
		carrying_capacity_total += int(population)

	var active_building_cells := {}
	for building_cell in building_cells:
		active_building_cells[int(building_cell)] = true
	var cycle_days := facade.bootstrap_cycle_days(
		populations.size(), map.cell_count(), active_building_cells.size(),
		building_cells.size())
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
		var survival := _sat_mul_nonnegative(_sat_mul_nonnegative(
			_survival_cost_per_person_per_day(map, cell_idx, signature_id, finance),
			int(populations[cohort])), SURVIVAL_FUND_DAYS)
		var owner := _sat_mul_nonnegative(_sat_mul_nonnegative(int(
			owner_daily_input_cost_by_key.get("%d:%d" % [cell_idx, signature_id], 0)),
			cycle_days), OWNER_OPERATING_CYCLES) * PLANNED_UTILIZATION_Q16 / Q16_ONE
		var merchant := int(merchant_daily_inventory_value_by_cell.get(cell_idx, 0)) \
			if signature_id == merchant_signature else 0
		funds[cohort] = _sat_add_nonnegative(
			_sat_add_nonnegative(survival, owner), merchant)
		survival_funds_by_cohort.append(survival)
		owner_operating_funds_by_cohort.append(owner)
		merchant_inventory_funds_by_cohort.append(merchant)
		initial_survival_funds = _sat_add_nonnegative(initial_survival_funds, survival)
		initial_owner_operating_funds = _sat_add_nonnegative(
			initial_owner_operating_funds, owner)
		initial_merchant_inventory_funds = _sat_add_nonnegative(
			initial_merchant_inventory_funds, merchant)

	return {
		"ok": true,
		"population_packet": {
			"cell_indices": cell_indices,
			"signature_ids": signature_ids,
			"population": populations,
			"funds": funds,
		},
		"market_packet": _bootstrap_market_packet(
			map.cell_count(), finance, populated_cells),
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
		"population_source": "demand_driven_survival_capacity_bootstrap_v16",
		"collector_placement_model": "demand_driven_minimum_chain_v16",
		"initial_resource_horizon_days": INITIAL_RESOURCE_HORIZON_DAYS,
		"construction_source_min_horizon_days":
			CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS,
		"construction_source_root_fallback_counts":
			source_root_fallback_counts,
		"cell_population_cap": CELL_POPULATION_CAP,
		"initial_employment": "unemployed",
		"initial_stock_units": populated_cells.size() * 1750,
		"bootstrap_bridge_stock_per_market": BOOTSTRAP_BRIDGE_STOCK.duplicate(),
		"bootstrap_root_building_counts": {
			"merchant_post": populated_cells.size(),
			"gathering_ground": _count_buildings(
				groups_by_cell, &"gathering_ground"),
			"timber_collector": _count_buildings(
				groups_by_cell, &"timber_collector"),
			"stone_collector": _count_buildings(
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
		"planned_utilization_q16": PLANNED_UTILIZATION_Q16,
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
		"carrying_capacity_min": carrying_capacity_min,
		"carrying_capacity_max": carrying_capacity_max,
		"carrying_capacity_total": carrying_capacity_total,
		"food_requirement_per_capita": FOOD_REQUIREMENT_PER_CAPITA,
		"clothing_requirement_per_capita": CLOTHING_REQUIREMENT_PER_CAPITA,
		"basic_capacity_cell_indices": basic_capacity_cell_indices,
		"basic_capacity_population": basic_capacity_population,
		"basic_food_capacity": basic_food_capacity,
		"basic_clothing_capacity": basic_clothing_capacity,
		"good_count": facade.good_ids().size(),
	}


static func _balance_basic_capacity(groups: Array, reserved_population: int = 0) -> Dictionary:
	var trimmed := 0
	var initial_totals := _basic_capacity_totals(groups, reserved_population)
	var sustainable_population := _planned_survival_capacity(initial_totals)
	var target_population := clampi(maxi(reserved_population,
		sustainable_population * INITIAL_CARRYING_CAPACITY_SHARE_Q16 / Q16_ONE),
		0, CELL_POPULATION_CAP)
	while true:
		var best := -1
		for i in range(groups.size() - 1, -1, -1):
			var group: Dictionary = groups[i]
			if int(group.count) <= maxi(0, int(
					group.get("bootstrap_min_count", 0))):
				continue
			group.count = int(group.count) - 1
			var trial_totals := _basic_capacity_totals(groups, reserved_population)
			var covered := _planned_survival_capacity(trial_totals) >= target_population \
				and _groups_input_covered(groups)
			group.count = int(group.count) + 1
			if covered:
				best = i
				break
		if best < 0:
			break
		groups[best].count = int(groups[best].count) - 1
		trimmed += 1
	for i in range(groups.size() - 1, -1, -1):
		if int(groups[i].count) <= 0:
			groups.remove_at(i)
	var final_totals := _basic_capacity_totals(groups, reserved_population)
	var covered := target_population > 0 and \
		_planned_survival_capacity(final_totals) >= target_population and \
		_groups_input_covered(groups)
	if not covered:
		for group in groups:
			trimmed += maxi(0, int(group.count))
		groups.clear()
		target_population = 0
		final_totals = {"population": 0, "food": 0, "clothing": 0}
	return {
		"trimmed_buildings": trimmed,
		"target_population": target_population,
		"covered": covered,
		"totals": final_totals,
		"sustainable_population": sustainable_population,
		"input_coverage_q16": _groups_input_coverage_q16(groups),
	}


static func _planned_survival_capacity(totals: Dictionary) -> int:
	var food := maxi(0, int(totals.food)) * PLANNED_UTILIZATION_Q16 / Q16_ONE
	var clothing := maxi(0, int(totals.clothing)) * PLANNED_UTILIZATION_Q16 / Q16_ONE
	return clampi(mini(food / FOOD_REQUIREMENT_PER_CAPITA,
		clothing / CLOTHING_REQUIREMENT_PER_CAPITA), 0, CELL_POPULATION_CAP)


static func _groups_input_covered(groups: Array) -> bool:
	return _groups_input_paths_exist(groups) and \
		_groups_input_coverage_q16(groups) >= Q16_ONE


static func _groups_input_coverage_q16(groups: Array) -> int:
	var outputs := {}
	var inputs := {}
	for group in groups:
		var count := int(group.count)
		if count <= 0:
			continue
		var spec: Dictionary = group.spec
		var output_ids: PackedStringArray = spec.get("output_good_ids", PackedStringArray())
		var output_quantities: PackedInt64Array = spec.get(
			"output_quantities", PackedInt64Array())
		var output_categories: PackedStringArray = spec.get(
			"output_category_ids", PackedStringArray())
		for i in range(mini(output_ids.size(), output_quantities.size())):
			var output_id := StringName(output_ids[i])
			var quantity := count * int(output_quantities[i])
			outputs[output_id] = int(outputs.get(output_id, 0)) + quantity
			if i < output_categories.size() and String(output_categories[i]) != "":
				var category_id := StringName(
					"category:%s" % String(output_categories[i]))
				outputs[category_id] = int(outputs.get(category_id, 0)) + quantity
		var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
		var input_quantities: PackedInt64Array = spec.get(
			"input_quantities", PackedInt64Array())
		var input_categories: PackedStringArray = spec.get(
			"input_category_ids", PackedStringArray())
		var input_required_q16: PackedInt32Array = spec.get(
			"input_required_q16", PackedInt32Array())
		for i in range(mini(input_ids.size(), input_quantities.size())):
			if i < input_required_q16.size() and input_required_q16[i] < Q16_ONE:
				continue
			var input_id := StringName("category:%s" % String(input_categories[i])) \
				if i < input_categories.size() and String(input_categories[i]) != "" \
				else StringName(input_ids[i])
			inputs[input_id] = int(inputs.get(input_id, 0)) + \
				count * int(input_quantities[i])
	var coverage := Q16_ONE
	for input_id in inputs:
		var required := int(inputs[input_id])
		if required <= 0:
			continue
		coverage = mini(coverage, int(outputs.get(input_id, 0)) * Q16_ONE / required)
	return maxi(0, coverage)


static func _groups_input_paths_exist(groups: Array) -> bool:
	var outputs := {}
	for group in groups:
		if int(group.count) > 0:
			_mark_outputs(group.spec, outputs)
	for group in groups:
		var inputs: PackedStringArray = group.spec.get("input_good_ids", PackedStringArray())
		var required_q16: PackedInt32Array = group.spec.get(
			"input_required_q16", PackedInt32Array())
		if int(group.count) <= 0:
			continue
		for i in range(inputs.size()):
			if i < required_q16.size() and required_q16[i] < Q16_ONE:
				continue
			if not _input_slot_ready(group.spec, i, outputs):
				return false
	return true


static func _prune_nonessential_groups(groups: Array) -> void:
	var needed := {}
	for good_id in FOOD_GOOD_IDS:
		needed[StringName(good_id)] = true
	for good_id in CLOTHING_GOOD_IDS:
		needed[StringName(good_id)] = true
	var keep := {}
	var changed := true
	while changed:
		changed = false
		for i in range(groups.size()):
			if keep.has(i):
				continue
			if bool((groups[i] as Dictionary).get("bootstrap_root", false)):
				keep[i] = true
				changed = true
				continue
			var spec: Dictionary = groups[i].spec
			var outputs: PackedStringArray = spec.get("output_good_ids", PackedStringArray())
			var required := false
			for good_id in outputs:
				if needed.has(StringName(good_id)):
					required = true
					break
			if not required:
				continue
			keep[i] = true
			changed = true
			for input_id in spec.get("input_good_ids", PackedStringArray()):
				needed[StringName(input_id)] = true
	for i in range(groups.size() - 1, -1, -1):
		if not keep.has(i):
			groups.remove_at(i)


static func _prepare_regional_capacity_fallback(
		candidate_groups_by_cell: Dictionary, source_components: Array) -> Dictionary:
	var groups_by_cell: Dictionary = candidate_groups_by_cell.duplicate(true)
	var target_population_by_cell := {}
	var input_coverage_q16_by_cell := {}
	var skipped_components := []
	var accepted_components := 0
	var populated_cells := 0
	for component_idx in range(source_components.size()):
		var component: Dictionary = source_components[component_idx]
		var component_cells: Array = component.get("cells", [])
		_prune_nonessential_region(groups_by_cell, component_cells)
		var component_groups := []
		var active_cells := []
		for cell_idx_raw in component_cells:
			var cell_idx := int(cell_idx_raw)
			var cell_groups: Array = groups_by_cell.get(cell_idx, [])
			if cell_groups.is_empty():
				continue
			active_cells.append(cell_idx)
			component_groups.append_array(cell_groups)
		var failure_reason := ""
		if active_cells.is_empty():
			failure_reason = "regional_groups_empty"
		elif not _groups_have_survival_output(component_groups, FOOD_GOOD_IDS):
			failure_reason = "regional_food_root_missing"
		elif not _groups_have_survival_output(component_groups, CLOTHING_GOOD_IDS):
			failure_reason = "regional_clothing_root_missing"
		elif not _groups_input_paths_exist(component_groups):
			failure_reason = "regional_hard_input_path_missing"
		var coverage_q16 := _groups_input_coverage_q16(component_groups)
		if failure_reason == "" and coverage_q16 <= 0:
			failure_reason = "regional_hard_input_coverage_zero"
		var target_population := 0
		if failure_reason == "":
			var totals := _basic_capacity_totals(
				component_groups, active_cells.size())
			var survival_capacity := _regional_planned_survival_capacity(
				totals, active_cells.size())
			target_population = survival_capacity * \
				INITIAL_CARRYING_CAPACITY_SHARE_Q16 / Q16_ONE
			if target_population < active_cells.size():
				failure_reason = "regional_survival_capacity_too_small"
		if failure_reason != "":
			skipped_components.append({
				"component_index": component_idx,
				"reason": failure_reason,
				"cell_count": component_cells.size(),
			})
			for cell_idx_raw in component_cells:
				groups_by_cell[int(cell_idx_raw)] = []
			continue
		# Every retained production cell needs its merchant owner. Allocate the
		# remaining regional carrying capacity deterministically across those
		# cells; trade, rather than co-location, closes their survival chain.
		for cell_idx in active_cells:
			target_population_by_cell[cell_idx] = 1
			input_coverage_q16_by_cell[cell_idx] = coverage_q16
		var remaining := target_population - active_cells.size()
		var cursor := 0
		while remaining > 0:
			var cell_idx := int(active_cells[cursor % active_cells.size()])
			if int(target_population_by_cell[cell_idx]) < CELL_POPULATION_CAP:
				target_population_by_cell[cell_idx] = \
					int(target_population_by_cell[cell_idx]) + 1
				remaining -= 1
			cursor += 1
		accepted_components += 1
		populated_cells += active_cells.size()
	if accepted_components <= 0:
		return {
			"ok": false,
			"reason": "regional_capacity_fallback_empty",
			"skipped_components": skipped_components,
		}
	return {
		"ok": true,
		"groups_by_cell": groups_by_cell,
		"target_population_by_cell": target_population_by_cell,
		"input_coverage_q16_by_cell": input_coverage_q16_by_cell,
		"component_count": accepted_components,
		"populated_cells": populated_cells,
		"skipped_components": skipped_components,
	}


static func _prune_nonessential_region(groups_by_cell: Dictionary,
		component_cells: Array) -> void:
	var entries := []
	for cell_idx_raw in component_cells:
		var cell_idx := int(cell_idx_raw)
		var groups: Array = groups_by_cell.get(cell_idx, [])
		for group_idx in range(groups.size()):
			entries.append({
				"cell_idx": cell_idx,
				"group_idx": group_idx,
				"group": groups[group_idx],
			})
	var needed := {}
	for good_id in FOOD_GOOD_IDS:
		needed[StringName(good_id)] = true
	for good_id in CLOTHING_GOOD_IDS:
		needed[StringName(good_id)] = true
	var keep := {}
	var changed := true
	while changed:
		changed = false
		for entry_idx in range(entries.size()):
			if keep.has(entry_idx):
				continue
			var group: Dictionary = entries[entry_idx].group
			var spec: Dictionary = group.spec
			if not bool(group.get("bootstrap_root", false)) and \
					not _spec_outputs_needed(spec, needed):
				continue
			keep[entry_idx] = true
			changed = true
			_mark_required_inputs(spec, needed)
	var keep_by_cell := {}
	for entry_idx in keep:
		var entry: Dictionary = entries[int(entry_idx)]
		var cell_keep: Dictionary = keep_by_cell.get(int(entry.cell_idx), {})
		cell_keep[int(entry.group_idx)] = true
		keep_by_cell[int(entry.cell_idx)] = cell_keep
	for cell_idx_raw in component_cells:
		var cell_idx := int(cell_idx_raw)
		var groups: Array = groups_by_cell.get(cell_idx, [])
		var cell_keep: Dictionary = keep_by_cell.get(cell_idx, {})
		for group_idx in range(groups.size() - 1, -1, -1):
			if not cell_keep.has(group_idx):
				groups.remove_at(group_idx)


static func _spec_outputs_needed(spec: Dictionary, needed: Dictionary) -> bool:
	var output_ids: PackedStringArray = spec.get(
		"output_good_ids", PackedStringArray())
	var output_categories: PackedStringArray = spec.get(
		"output_category_ids", PackedStringArray())
	for i in range(output_ids.size()):
		if needed.has(StringName(output_ids[i])):
			return true
		if i < output_categories.size() and String(output_categories[i]) != "" and \
				needed.has(StringName("category:%s" % String(output_categories[i]))):
			return true
	return false


static func _mark_required_inputs(spec: Dictionary, needed: Dictionary) -> void:
	var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
	var input_categories: PackedStringArray = spec.get(
		"input_category_ids", PackedStringArray())
	var required_q16: PackedInt32Array = spec.get(
		"input_required_q16", PackedInt32Array())
	for i in range(input_ids.size()):
		if i < required_q16.size() and required_q16[i] < Q16_ONE:
			continue
		if i < input_categories.size() and String(input_categories[i]) != "":
			needed[StringName("category:%s" % String(input_categories[i]))] = true
		else:
			needed[StringName(input_ids[i])] = true


static func _groups_have_survival_output(groups: Array,
		good_ids: Dictionary) -> bool:
	for group_raw in groups:
		var group: Dictionary = group_raw
		for good_id in group.spec.get("output_good_ids", PackedStringArray()):
			if good_ids.has(String(good_id)):
				return true
	return false


static func _regional_planned_survival_capacity(totals: Dictionary,
		active_cell_count: int) -> int:
	var food := maxi(0, int(totals.food)) * PLANNED_UTILIZATION_Q16 / Q16_ONE
	var clothing := maxi(0, int(totals.clothing)) * PLANNED_UTILIZATION_Q16 / Q16_ONE
	return clampi(mini(food / FOOD_REQUIREMENT_PER_CAPITA,
		clothing / CLOTHING_REQUIREMENT_PER_CAPITA), 0,
		maxi(0, active_cell_count) * CELL_POPULATION_CAP)


static func _find_group(groups: Array, stable_id: StringName) -> Dictionary:
	for group_raw in groups:
		var group: Dictionary = group_raw
		if StringName(group.spec.get("stable_id", "")) == stable_id:
			return group
	return {}


static func _count_buildings(groups_by_cell: Dictionary,
		stable_id: StringName) -> int:
	var total := 0
	for groups_raw in groups_by_cell.values():
		for group_raw in groups_raw:
			var group: Dictionary = group_raw
			if StringName(group.spec.get("stable_id", "")) == stable_id:
				total += maxi(0, int(group.count))
	return total


static func _ensure_construction_source_roots(passable_cells: PackedInt32Array,
		groups_by_cell: Dictionary, outputs_by_cell: Dictionary,
		building_specs: Dictionary, resource_arrays: Dictionary,
		resource_peaks: Dictionary) -> Dictionary:
	var added := {"timber_collector": 0, "stone_collector": 0}
	for stable_id in [&"timber_collector", &"stone_collector"]:
		var spec: Dictionary = building_specs.get(stable_id, {})
		if spec.is_empty():
			continue
		for cell_idx_raw in passable_cells:
			var cell_idx := int(cell_idx_raw)
			var groups: Array = groups_by_cell[cell_idx]
			if not _find_group(groups, stable_id).is_empty():
				continue
			if _collector_count_at(spec, cell_idx, resource_arrays,
					resource_peaks, CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS) <= 0:
				continue
			groups.append({"spec": spec, "count": 1})
			_mark_outputs(spec, outputs_by_cell[cell_idx])
			added[String(stable_id)] = int(added[String(stable_id)]) + 1
	return added


static func _construction_source_diagnostics(passable_cells: PackedInt32Array,
		groups_by_cell: Dictionary, resource_arrays: Dictionary,
		resource_peaks: Dictionary, fallback_counts: Dictionary) -> Dictionary:
	var positive_cells := {}
	for resource_id in [&"fertile_soil", &"timber", &"stone"]:
		var count := 0
		var reserves: PackedFloat32Array = resource_arrays.get(
			resource_id, PackedFloat32Array())
		for cell_idx_raw in passable_cells:
			var cell_idx := int(cell_idx_raw)
			if cell_idx >= 0 and cell_idx < reserves.size() and reserves[cell_idx] > 0.0:
				count += 1
		positive_cells[String(resource_id)] = count
	return {
		"passable_cells": passable_cells.size(),
		"resource_positive_cells": positive_cells,
		"resource_peaks": {
			"fertile_soil": float(resource_peaks.get(&"fertile_soil", 0.0)),
			"timber": float(resource_peaks.get(&"timber", 0.0)),
			"stone": float(resource_peaks.get(&"stone", 0.0)),
		},
		"root_buildings": {
			"timber_collector": _count_buildings(
				groups_by_cell, &"timber_collector"),
			"stone_collector": _count_buildings(
				groups_by_cell, &"stone_collector"),
		},
		"fallback_roots": fallback_counts.duplicate(),
	}


static func _has_survival_food_root(groups: Array) -> bool:
	for group_raw in groups:
		var group: Dictionary = group_raw
		var outputs: PackedStringArray = group.spec.get(
			"output_good_ids", PackedStringArray())
		for good_id in outputs:
			if FOOD_GOOD_IDS.has(String(good_id)):
				return true
	return false


static func _protect_construction_sources(map: MapData,
		passable_cells: PackedInt32Array, groups_by_cell: Dictionary,
		outputs_by_cell: Dictionary = {}, drop_incomplete_regions: bool = false
		) -> Dictionary:
	var passable := {}
	for cell_idx in passable_cells:
		passable[int(cell_idx)] = true
	var visited := {}
	var components := []
	var skipped_components := []
	var candidate_component_count := 0
	for start_raw in passable_cells:
		var start := int(start_raw)
		if visited.has(start):
			continue
		var queue: Array[int] = [start]
		visited[start] = true
		var cursor := 0
		var populated := false
		var timber_cell := -1
		var stone_cell := -1
		var component_cells: Array[int] = []
		while cursor < queue.size():
			var cell_idx := queue[cursor]
			cursor += 1
			component_cells.append(cell_idx)
			var groups: Array = groups_by_cell.get(cell_idx, [])
			if not groups.is_empty():
				populated = true
				if timber_cell < 0 and not _find_group(groups, &"timber_collector").is_empty():
					timber_cell = cell_idx
				if stone_cell < 0 and not _find_group(groups, &"stone_collector").is_empty():
					stone_cell = cell_idx
			for direction in range(6):
				var neighbor := int(map.neighbor_index(cell_idx, direction))
				if neighbor >= 0 and passable.has(neighbor) and not visited.has(neighbor):
					visited[neighbor] = true
					queue.append(neighbor)
		if not populated:
			continue
		candidate_component_count += 1
		if timber_cell < 0 or stone_cell < 0:
			var missing_component := {
				"component_index": candidate_component_count - 1,
				"missing_timber": timber_cell < 0,
				"missing_stone": stone_cell < 0,
				"cell_count": component_cells.size(),
				"first_cell": component_cells[0] if not component_cells.is_empty() else -1,
			}
			if not drop_incomplete_regions:
				missing_component["ok"] = false
				missing_component["reason"] = "bootstrap_construction_source_missing"
				return missing_component
			skipped_components.append(missing_component)
			for component_cell in component_cells:
				groups_by_cell[component_cell] = []
				if outputs_by_cell.has(component_cell):
					outputs_by_cell[component_cell] = {}
			continue
		var timber_group := _find_group(groups_by_cell[timber_cell], &"timber_collector")
		var stone_group := _find_group(groups_by_cell[stone_cell], &"stone_collector")
		timber_group["bootstrap_root"] = true
		stone_group["bootstrap_root"] = true
		timber_group["bootstrap_min_count"] = 1
		stone_group["bootstrap_min_count"] = 1
		components.append({
			"timber_cell": timber_cell,
			"stone_cell": stone_cell,
			"cells": component_cells.duplicate(),
		})
	if components.is_empty():
		return {
			"ok": false,
			"reason": "bootstrap_construction_source_missing",
			"candidate_component_count": candidate_component_count,
			"skipped_components": skipped_components,
		}
	return {
		"ok": true,
		"component_count": components.size(),
		"components": components,
		"candidate_component_count": candidate_component_count,
		"skipped_components": skipped_components,
	}


static func _construction_source_component_summaries(components: Array) -> Array:
	var summaries := []
	for component_raw in components:
		var component: Dictionary = component_raw
		summaries.append({
			"timber_cell": int(component.get("timber_cell", -1)),
			"stone_cell": int(component.get("stone_cell", -1)),
			"cell_count": (component.get("cells", []) as Array).size(),
		})
	return summaries


static func _bootstrap_market_packet(cell_count: int, finance: Dictionary,
		populated_cells: PackedInt32Array) -> Dictionary:
	var good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	var stock := PackedInt64Array()
	stock.resize(cell_count * good_ids.size())
	stock.fill(0)
	for cell_idx_raw in populated_cells:
		var cell_idx := int(cell_idx_raw)
		for good_id in BOOTSTRAP_BRIDGE_STOCK:
			var good_idx := good_ids.find(String(good_id))
			stock[cell_idx * good_ids.size() + good_idx] = int(
				BOOTSTRAP_BRIDGE_STOCK[good_id])
	return {"stock": stock}


static func _basic_capacity_deficit_people(totals: Dictionary) -> int:
	var population := maxi(0, int(totals.population))
	var food_deficit := maxi(
		0, population * FOOD_REQUIREMENT_PER_CAPITA - int(totals.food))
	var clothing_deficit := maxi(
		0, population * CLOTHING_REQUIREMENT_PER_CAPITA - int(totals.clothing))
	return ceili(float(food_deficit) / float(FOOD_REQUIREMENT_PER_CAPITA)) + \
		ceili(float(clothing_deficit) / float(CLOTHING_REQUIREMENT_PER_CAPITA))


static func _carrying_capacity_population(totals: Dictionary) -> int:
	var workforce := maxi(0, int(totals.population))
	var food_capacity := int(maxi(0, int(totals.food)) / FOOD_REQUIREMENT_PER_CAPITA)
	var clothing_capacity := int(
		maxi(0, int(totals.clothing)) / CLOTHING_REQUIREMENT_PER_CAPITA)
	return clampi(mini(workforce, mini(food_capacity, clothing_capacity)),
		0, CELL_POPULATION_CAP)


static func _basic_capacity_totals(groups: Array, reserved_population: int = 0) -> Dictionary:
	var population := maxi(0, reserved_population)
	var food := 0
	var clothing := 0
	for group in groups:
		var count := int(group.count)
		var per_building := _building_basic_capacity(group.spec)
		population += count * int(per_building.jobs)
		food += count * int(per_building.food)
		clothing += count * int(per_building.clothing)
	return {"population": population, "food": food, "clothing": clothing}


static func _building_basic_capacity(spec: Dictionary) -> Dictionary:
	var jobs := int(spec.owner_slots)
	for slots in spec.employee_slots:
		jobs += int(slots)
	var food := 0
	var clothing := 0
	var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
	var input_quantities: PackedInt64Array = spec.get("input_quantities", PackedInt64Array())
	for i in range(mini(input_ids.size(), input_quantities.size())):
		if FOOD_GOOD_IDS.has(String(input_ids[i])):
			food -= int(input_quantities[i])
		if CLOTHING_GOOD_IDS.has(String(input_ids[i])):
			clothing -= int(input_quantities[i])
	var output_ids: PackedStringArray = spec.get("output_good_ids", PackedStringArray())
	var output_quantities: PackedInt64Array = spec.get("output_quantities", PackedInt64Array())
	for i in range(mini(output_ids.size(), output_quantities.size())):
		if FOOD_GOOD_IDS.has(String(output_ids[i])):
			food += int(output_quantities[i])
		if CLOTHING_GOOD_IDS.has(String(output_ids[i])):
			clothing += int(output_quantities[i])
	return {"jobs": jobs, "food": food, "clothing": clothing}


static func _resource_arrays(map: MapData, technology_ids: PackedStringArray) -> Dictionary:
	ResourceProfileRegistry.ensure_loaded()
	var out := {}
	for profile in ResourceProfileRegistry.ordered():
		if not ResourceProfileRegistry.discovery_visible(profile, technology_ids):
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values: PackedFloat32Array = map.get(field)
		if values.size() >= map.cell_count():
			out[StringName(profile.id)] = values
	return out


static func _resource_peaks(resource_arrays: Dictionary,
		passable_cells: PackedInt32Array) -> Dictionary:
	var out := {}
	for resource_id in resource_arrays:
		var reserves: PackedFloat32Array = resource_arrays[resource_id]
		var peak := 0.0
		for cell_idx in passable_cells:
			if cell_idx >= 0 and cell_idx < reserves.size():
				peak = maxf(peak, maxf(0.0, reserves[cell_idx]))
		out[resource_id] = peak
	return out


static func _collector_count_at(spec: Dictionary, cell_idx: int,
		resource_arrays: Dictionary, resource_peaks: Dictionary,
		resource_horizon_days: int = INITIAL_RESOURCE_HORIZON_DAYS) -> int:
	var resource_ids: PackedStringArray = spec.resource_ids
	var quantities: PackedInt64Array = spec.resource_quantities
	var modes: PackedInt32Array = spec.resource_modes
	var access_modes: PackedInt32Array = spec.resource_access_modes
	if resource_ids.is_empty() or resource_ids.size() != quantities.size() \
			or resource_ids.size() != modes.size() or resource_ids.size() != access_modes.size():
		return 0
	var count_cap := clampi(int(TEST_COLLECTOR_COUNT_CAPS.get(
		String(spec.get("stable_id", "")), COLLECTOR_COUNT_CAP)), 1, COLLECTOR_COUNT_CAP)
	var supported := count_cap
	for i in range(resource_ids.size()):
		var resource_id := StringName(resource_ids[i])
		if not resource_arrays.has(resource_id):
			return 0
		var reserves: PackedFloat32Array = resource_arrays[resource_id]
		var required := float(quantities[i]) / float(GOODS_SCALE)
		if cell_idx < 0 or cell_idx >= reserves.size() or required <= 0.0:
			return 0
		if int(access_modes[i]) != 0:
			return 0
		var available := maxf(0.0, reserves[cell_idx])
		var peak := float(resource_peaks.get(resource_id, 0.0))
		if available <= 0.0 or peak <= 0.0:
			return 0
		var abundance_supported := clampi(
			ceili(float(count_cap) * available / peak), 1, count_cap)
		var reserve_days := maxi(1, resource_horizon_days) if int(modes[i]) == 0 else 1
		var horizon_supported := int(floor(
			available / (required * float(reserve_days))))
		var local_supported := mini(abundance_supported, horizon_supported)
		if local_supported <= 0:
			return 0
		supported = mini(supported, local_supported)
	return clampi(supported, 0, count_cap)


static func _mark_outputs(spec: Dictionary, local_outputs: Dictionary) -> void:
	var output_ids: PackedStringArray = spec.output_good_ids
	var output_categories: PackedStringArray = spec.get(
		"output_category_ids", PackedStringArray())
	for i in range(output_ids.size()):
		var good_id := output_ids[i]
		local_outputs[StringName(good_id)] = true
		if i < output_categories.size() and String(output_categories[i]) != "":
			local_outputs[StringName("category:%s" % String(output_categories[i]))] = true


static func _inputs_ready(spec: Dictionary, available_outputs: Dictionary) -> bool:
	var input_ids: PackedStringArray = spec.input_good_ids
	if input_ids.is_empty():
		return false
	for i in range(input_ids.size()):
		if not _input_slot_ready(spec, i, available_outputs):
			return false
	return true


static func _input_slot_ready(spec: Dictionary, input_idx: int,
		available_outputs: Dictionary) -> bool:
	var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
	var input_categories: PackedStringArray = spec.get(
		"input_category_ids", PackedStringArray())
	if input_idx < 0 or input_idx >= input_ids.size():
		return false
	var category := String(input_categories[input_idx]) \
		if input_idx < input_categories.size() else ""
	if category != "" and available_outputs.has(StringName("category:%s" % category)):
		return true
	return available_outputs.has(StringName(input_ids[input_idx]))


static func _technology_available(tags: PackedStringArray) -> bool:
	for tag in tags:
		var stable_id := String(tag)
		if stable_id.begins_with("tech.") and not MID_STONE_TECHNOLOGY_IDS.has(stable_id):
			return false
	return true


static func _default_input_cost_per_day(spec: Dictionary, finance: Dictionary) -> int:
	var good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var quantities: PackedInt64Array = spec.get("input_quantities", PackedInt64Array())
	var offsets: PackedInt32Array = spec.get("input_candidate_offsets", PackedInt32Array())
	var candidates: PackedStringArray = spec.get("input_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = spec.get(
		"input_candidate_efficiency_q16", PackedInt32Array())
	var total := 0
	for input_idx in range(quantities.size()):
		if input_idx + 1 >= offsets.size():
			continue
		var cheapest := -1
		for candidate_idx in range(int(offsets[input_idx]), int(offsets[input_idx + 1])):
			if candidate_idx >= candidates.size() or candidate_idx >= efficiencies.size():
				continue
			var good_idx := good_ids.find(String(candidates[candidate_idx]))
			var efficiency := int(efficiencies[candidate_idx])
			if good_idx < 0 or good_idx >= prices.size() or efficiency <= 0:
				continue
			var physical := (int(quantities[input_idx]) * Q16_ONE + efficiency - 1) / efficiency
			var cost := physical * int(prices[good_idx]) / GOODS_SCALE
			if cheapest < 0 or cost < cheapest:
				cheapest = cost
		if cheapest > 0:
			total += cheapest
	return total


static func _default_output_inventory_value_per_day(
		spec: Dictionary, finance: Dictionary) -> int:
	var good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var target_days: PackedInt32Array = finance.get(
		"good_target_inventory_days_q16", PackedInt32Array())
	var buy_factors: PackedInt32Array = finance.get(
		"good_merchant_buy_factor_q16", PackedInt32Array())
	var issue_values: PackedInt64Array = finance.get(
		"good_monetary_issue_values", PackedInt64Array())
	var outputs: PackedStringArray = spec.get("output_good_ids", PackedStringArray())
	var quantities: PackedInt64Array = spec.get("output_quantities", PackedInt64Array())
	var total := 0
	for output_idx in range(mini(outputs.size(), quantities.size())):
		var good_idx := good_ids.find(String(outputs[output_idx]))
		if good_idx < 0 or good_idx >= prices.size() or good_idx >= target_days.size() \
				or good_idx >= buy_factors.size():
			continue
		if good_idx < issue_values.size() and int(issue_values[good_idx]) > 0:
			continue
		var market_share_q16 := Q16_ONE / 2 if FOOD_GOOD_IDS.has(
			String(outputs[output_idx])) or CLOTHING_GOOD_IDS.has(
			String(outputs[output_idx])) else Q16_ONE
		var planned_quantity := int(quantities[output_idx]) * \
			PLANNED_UTILIZATION_Q16 / Q16_ONE
		var target_quantity := planned_quantity * int(target_days[good_idx]) / Q16_ONE
		target_quantity = target_quantity * market_share_q16 / Q16_ONE
		var buy_price := int(prices[good_idx]) * int(buy_factors[good_idx]) / Q16_ONE
		total += target_quantity * buy_price / GOODS_SCALE
	return total


static func _survival_cost_per_person_per_day(
		map: MapData, cell_idx: int, signature_id: int, finance: Dictionary) -> int:
	var plan_ids: PackedStringArray = finance.get("plan_ids", PackedStringArray())
	var plan_id := plan_ids.find(String(finance.get(
		"living_cost_base_plan_id", "survival_household")))
	var plan_offsets: PackedInt32Array = finance.get("plan_need_offsets", PackedInt32Array())
	var signature_ethnicity: PackedInt32Array = finance.get(
		"signature_ethnicity_ids", PackedInt32Array())
	if plan_id < 0 or plan_id + 1 >= plan_offsets.size() \
			or signature_id < 0 or signature_id >= signature_ethnicity.size():
		return 0
	var need_ids: PackedStringArray = finance.get("need_ids", PackedStringArray())
	var living_weights: PackedInt32Array = finance.get(
		"need_living_cost_weights_q16", PackedInt32Array())
	var stable_needs: PackedInt32Array = finance.get("need_stable_ids", PackedInt32Array())
	var base_quantities: PackedInt64Array = finance.get(
		"need_base_qty_per_person", PackedInt64Array())
	var need_curves: PackedInt32Array = finance.get(
		"need_quantity_env_curve_ids", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = finance.get(
		"need_variant_offsets", PackedInt32Array())
	var preferences: PackedInt32Array = finance.get(
		"variant_preference_q16", PackedInt32Array())
	var preference_curves: PackedInt32Array = finance.get(
		"variant_preference_env_curve_ids", PackedInt32Array())
	var component_offsets: PackedInt32Array = finance.get(
		"variant_component_offsets", PackedInt32Array())
	var component_goods: PackedInt32Array = finance.get(
		"component_good_ids", PackedInt32Array())
	var component_quantities: PackedInt64Array = finance.get(
		"component_qty_per_need", PackedInt64Array())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var ethnicity_factors: PackedInt32Array = finance.get(
		"ethnicity_need_factor_q16", PackedInt32Array())
	var ethnicity := int(signature_ethnicity[signature_id])
	var total := 0
	for need_idx in range(int(plan_offsets[plan_id]), int(plan_offsets[plan_id + 1])):
		if need_idx >= stable_needs.size() or need_idx >= base_quantities.size() \
				or need_idx >= need_curves.size() or need_idx + 1 >= need_variant_offsets.size():
			continue
		var stable_need := int(stable_needs[need_idx])
		if stable_need < 0 or stable_need >= living_weights.size():
			continue
		var score_sum := 0
		var weighted_price := 0
		for variant in range(int(need_variant_offsets[need_idx]),
				int(need_variant_offsets[need_idx + 1])):
			if variant >= preferences.size() or variant >= preference_curves.size() \
					or variant + 1 >= component_offsets.size():
				continue
			var unit_price := 0
			for component in range(int(component_offsets[variant]),
					int(component_offsets[variant + 1])):
				if component >= component_goods.size() or component >= component_quantities.size():
					continue
				var good_idx := int(component_goods[component])
				if good_idx >= 0 and good_idx < prices.size():
					unit_price += int(component_quantities[component]) * int(prices[good_idx]) / GOODS_SCALE
			var score := int(preferences[variant]) * _sample_environment_curve(
				finance, int(preference_curves[variant]), map, cell_idx) / Q16_ONE
			score_sum += maxi(0, score)
			weighted_price += maxi(1, unit_price) * maxi(0, score)
		if score_sum <= 0:
			continue
		var quantity := int(base_quantities[need_idx]) * int(living_weights[stable_need]) / Q16_ONE
		quantity = quantity * _sample_environment_curve(
			finance, int(need_curves[need_idx]), map, cell_idx) / Q16_ONE
		var factor_index := ethnicity * need_ids.size() + stable_need
		if factor_index >= 0 and factor_index < ethnicity_factors.size():
			quantity = quantity * int(ethnicity_factors[factor_index]) / Q16_ONE
		total += quantity * (weighted_price / score_sum) / GOODS_SCALE
	return maxi(0, total)


static func _sample_environment_curve(
		finance: Dictionary, curve_id: int, map: MapData, cell_idx: int) -> int:
	if curve_id < 0:
		return Q16_ONE
	var signals: PackedInt32Array = finance.get(
		"environment_curve_signal_ids", PackedInt32Array())
	var values: PackedInt32Array = finance.get(
		"environment_curve_values_q16", PackedInt32Array())
	if curve_id >= signals.size() or (curve_id + 1) * 17 > values.size():
		return 0
	var signal_q16 := _environment_signal_q16(map, cell_idx, int(signals[curve_id]))
	var scaled := clampi(signal_q16, 0, Q16_ONE) * 16
	var lo := mini(16, scaled / Q16_ONE)
	var hi := mini(16, lo + 1)
	var fraction := scaled - lo * Q16_ONE
	var begin := curve_id * 17
	return int(values[begin + lo]) + \
		(int(values[begin + hi]) - int(values[begin + lo])) * fraction / Q16_ONE


static func _environment_signal_q16(map: MapData, cell_idx: int, signal_id: int) -> int:
	var values: PackedFloat32Array
	var fallback := 0.0
	match signal_id:
		0:
			values = map.temp_arr
			fallback = 0.5
		1:
			values = map.moisture_arr
			fallback = 0.5
		2:
			values = map.snow_cover_arr
		3:
			values = map.weather_intensity_arr
		_:
			return 0
	var value := float(values[cell_idx]) if cell_idx >= 0 and cell_idx < values.size() else fallback
	if not is_finite(value):
		value = fallback
	return clampi(roundi(clampf(value, 0.0, 1.0) * Q16_ONE), 0, Q16_ONE)


static func _sat_add_nonnegative(a: int, b: int) -> int:
	a = maxi(0, a)
	b = maxi(0, b)
	return INT64_MAX if a > INT64_MAX - b else a + b


static func _sat_mul_nonnegative(a: int, b: int) -> int:
	a = maxi(0, a)
	b = maxi(0, b)
	if a == 0 or b == 0:
		return 0
	return INT64_MAX if a > INT64_MAX / b else a * b


static func _largest_nonmerchant_profession(jobs: Dictionary,
		profession_ids: PackedStringArray) -> StringName:
	var selected := StringName()
	var selected_population := 0
	for profession_id in profession_ids:
		var profession := StringName(profession_id)
		if profession == &"merchant":
			continue
		var population := int(jobs.get(profession, 0))
		if population > selected_population:
			selected = profession
			selected_population = population
	return selected


static func _append_building_group(cells: PackedInt32Array, types: PackedInt32Array,
		owners: PackedInt32Array, counts: PackedInt64Array, cell: int, type_id: int,
		owner_signature: int, count: int) -> void:
	if count <= 0:
		return
	cells.append(cell)
	types.append(type_id)
	owners.append(owner_signature)
	counts.append(count)


static func _accumulate_building_jobs(spec: Dictionary, count: int, jobs: Dictionary) -> void:
	if count <= 0:
		return
	var owner_profession := StringName(spec.owner_profession)
	jobs[owner_profession] = int(jobs.get(owner_profession, 0)) + count * int(spec.owner_slots)
	var professions: PackedStringArray = spec.employee_professions
	var slots: PackedInt64Array = spec.employee_slots
	for i in range(professions.size()):
		var profession := StringName(professions[i])
		jobs[profession] = int(jobs.get(profession, 0)) + count * int(slots[i])


static func _terrain_at(map: MapData, cell_idx: int) -> int:
	if cell_idx >= 0 and cell_idx < map.terrain_arr.size():
		return int(map.terrain_arr[cell_idx])
	var cell := map.cell_at(cell_idx)
	return int(cell.terrain) if cell != null else TerrainType.TERRAIN.OCEAN
