extends RefCounted

## Balances local and regional capacity and protects construction supply.

const CapacityInputs = preload("res://scripts/economy/bootstrap/test_settlement_capacity_inputs.gd")
const Inputs = preload("res://scripts/economy/bootstrap/test_start_inputs.gd")
const Finance = preload("res://scripts/economy/bootstrap/test_start_finance.gd")
const Policy = preload("res://scripts/economy/bootstrap/test_start_policy.gd")
const Q16_ONE = Policy.Q16_ONE
const CELL_POPULATION_CAP = Policy.CELL_POPULATION_CAP
const CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS = Policy.CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS
const INITIAL_CARRYING_CAPACITY_SHARE_Q16 = Policy.INITIAL_CARRYING_CAPACITY_SHARE_Q16
const FOOD_GOOD_IDS = Policy.FOOD_GOOD_IDS
const CLOTHING_GOOD_IDS = Policy.CLOTHING_GOOD_IDS


static func _rebalance_building_groups(groups_by_cell: Dictionary,
		cell_indices: PackedInt32Array, populations: PackedInt64Array,
		population_scales: PackedInt32Array, finance: Dictionary,
		resource_arrays: Dictionary, resource_rules: Dictionary) -> void:
	for i in range(mini(cell_indices.size(), population_scales.size())):
		var scale := maxi(1, int(population_scales[i]))
		var cell_idx := int(cell_indices[i])
		var population := int(populations[i]) if i < populations.size() else 0
		var groups: Array = groups_by_cell.get(cell_idx, [])
		if population <= 0 or groups.is_empty():
			continue
		for group_raw in groups:
			var group: Dictionary = group_raw
			group.count = Finance.sat_mul_nonnegative(maxi(0, int(group.count)), scale)
			# The capacity-balanced base fixture already proved that these
			# owner-lots support its jobs and survival chain. Preserve that
			# per-capita employment structure when population is scaled.
			# Renewable/non-renewable physical caps below may still trim an
			# extractor, after which the final population pass follows the
			# actually surviving jobs.
			group["bootstrap_scaled_employment_floor"] = int(group.count)
		# Demand and upstream inputs depend on one another. A small deterministic
		# fixed-point loop converges the sparse stone-age graph without adding a
		# second runtime economy.
		for _iteration in range(8):
			var supply := CapacityInputs._building_supply_by_good(groups)
			var demand := CapacityInputs._household_basic_demand(population, supply)
			CapacityInputs._add_building_input_demand(demand, groups, finance)
			var changed := false
			for group_raw in groups:
				var group: Dictionary = group_raw
				var spec: Dictionary = group.spec
				var current := maxi(1, int(group.count))
				var required := maxi(1, int(group.get(
					"bootstrap_scaled_employment_floor", 1)))
				var outputs: PackedStringArray = spec.get(
					"output_good_ids", PackedStringArray())
				var quantities: PackedInt64Array = spec.get(
					"output_quantities", PackedInt64Array())
				for output_idx in range(mini(outputs.size(), quantities.size())):
					var good := StringName(outputs[output_idx])
					var total_supply := int(supply.get(good, 0))
					var wanted := int(demand.get(good, 0))
					if wanted > 0 and total_supply > 0:
						required = maxi(required,
							(current * wanted + total_supply - 1) / total_supply)
				var resource_cap := CapacityInputs._resource_building_count_cap(
					spec, cell_idx, resource_arrays, resource_rules)
				if resource_cap >= 0:
					required = mini(required, maxi(1, resource_cap))
				if required != current:
					group.count = required
					changed = true
			if not changed:
				break

static func _balance_basic_capacity(groups: Array, reserved_population: int = 0) -> Dictionary:
	var trimmed := 0
	var initial_totals := CapacityInputs._basic_capacity_totals(groups, reserved_population)
	var sustainable_population := CapacityInputs._planned_survival_capacity(initial_totals)
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
			var trial_totals := CapacityInputs._basic_capacity_totals(groups, reserved_population)
			var covered := CapacityInputs._planned_survival_capacity(trial_totals) >= target_population \
				and CapacityInputs._groups_input_covered(groups)
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
	var final_totals := CapacityInputs._basic_capacity_totals(groups, reserved_population)
	var covered := target_population > 0 and \
		CapacityInputs._planned_survival_capacity(final_totals) >= target_population and \
		CapacityInputs._groups_input_covered(groups)
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
		"input_coverage_q16": CapacityInputs._groups_input_coverage_q16(groups),
	}

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
		elif not CapacityInputs._groups_have_survival_output(component_groups, FOOD_GOOD_IDS):
			failure_reason = "regional_food_root_missing"
		elif not CapacityInputs._groups_have_survival_output(component_groups, CLOTHING_GOOD_IDS):
			failure_reason = "regional_clothing_root_missing"
		elif not CapacityInputs._groups_input_paths_exist(component_groups):
			failure_reason = "regional_hard_input_path_missing"
		var coverage_q16 := CapacityInputs._groups_input_coverage_q16(component_groups)
		if failure_reason == "" and coverage_q16 <= 0:
			failure_reason = "regional_hard_input_coverage_zero"
		var target_population := 0
		if failure_reason == "":
			var totals := CapacityInputs._basic_capacity_totals(
				component_groups, active_cells.size())
			var survival_capacity := CapacityInputs._regional_planned_survival_capacity(
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
		# The regional food capacity cannot overfill the physical cell limit.
		# Divide the bounded total directly; no retry loop can run out of slots.
		target_population = mini(target_population, active_cells.size() * CELL_POPULATION_CAP)
		var per_cell: int = target_population / active_cells.size()
		var extra: int = target_population % active_cells.size()
		for index in active_cells.size():
			target_population_by_cell[active_cells[index]] = per_cell + (1 if index < extra else 0)
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
					not CapacityInputs._spec_outputs_needed(spec, needed):
				continue
			keep[entry_idx] = true
			changed = true
			CapacityInputs._mark_required_inputs(spec, needed)
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

static func _ensure_construction_source_roots(passable_cells: PackedInt32Array,
		groups_by_cell: Dictionary, outputs_by_cell: Dictionary,
		building_specs: Dictionary, resource_arrays: Dictionary,
		resource_peaks: Dictionary) -> Dictionary:
	var added := {"timber_collector": 0, "stone_collector": 0}
	for stable_id in [&"timber_collector", &"stone_collector"]:
		var spec: Dictionary = building_specs.get(stable_id, {})
		if spec.is_empty() or not Policy.building_available(spec):
			continue
		for cell_idx_raw in passable_cells:
			var cell_idx := int(cell_idx_raw)
			var groups: Array = groups_by_cell[cell_idx]
			if not CapacityInputs._find_group(groups, stable_id).is_empty():
				continue
			if CapacityInputs._collector_count_at(spec, cell_idx, resource_arrays,
					resource_peaks, CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS) <= 0:
				continue
			groups.append({"spec": spec, "count": 1})
			CapacityInputs._mark_outputs(spec, outputs_by_cell[cell_idx])
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
			"timber_collector": CapacityInputs._count_buildings(
				groups_by_cell, &"timber_collector"),
			"stone_collector": CapacityInputs._count_buildings(
				groups_by_cell, &"stone_collector"),
		},
		"fallback_roots": fallback_counts.duplicate(),
	}

static func _protect_construction_sources(map: Inputs,
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
				if timber_cell < 0 and not CapacityInputs._find_group(groups, &"timber_collector").is_empty():
					timber_cell = cell_idx
				if stone_cell < 0 and not CapacityInputs._find_group(groups, &"stone_collector").is_empty():
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
		var timber_group := CapacityInputs._find_group(groups_by_cell[timber_cell], &"timber_collector")
		var stone_group := CapacityInputs._find_group(groups_by_cell[stone_cell], &"stone_collector")
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
