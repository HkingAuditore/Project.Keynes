extends SceneTree

## Long research/economy soak.
## Run with:
##   godot --path Project/project-keynes --headless --script \
##     res://tests/economy_research_20y_soak_test.gd
##
## The worker is clocked at 50 simulation days/sec and runs 20 simulated years.
## Each day the first currently researchable technology is queued.  The test
## records population, unemployment, food stock, flint demand and building
## employment so a research-driven collapse can be reproduced from one cell.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectFacadeScript = preload("res://scripts/effect/effect_facade.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

const TARGET_DAYS := 365 * 20
const SPEED_DAYS_PER_SECOND := 50.0

var _sequence := 1
var _last_day := -1
var _rows: Array[Dictionary] = []
var _queued_ids := {}
var _forced_ids := {}
var _technology_nodes: Array = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var target_days_override := OS.get_environment("PK_RESEARCH_SOAK_DAYS")
	var target_days := TARGET_DAYS if target_days_override.is_empty() else int(target_days_override)
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		push_error("catalog compile failed: %s" % compiled)
		quit(1)
		return
	var network = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/technology/technology_network.json"))
	_technology_nodes = network.get("nodes", []) if network is Dictionary else []
	var native := compiled.duplicate(true)
	native.erase("ok")
	var ext := DCWorldExt.new()
	ext.create_entities(1)
	var modifier_facade = ModifierFacadeScript.new()
	_assert_ok(modifier_facade.configure(ext, 1), "configure modifiers")
	# Keep EffectRuntime disabled in this synchronous harness. With no worker peer
	# available to carry effect ACKs, Country Runtime uses its direct Modifier
	# path and commits the technology bit in the same authoritative slice.
	var effect_facade = null
	_register_cell_components(ext, compiled)
	var starting := PackedStringArray([
		"tech.gathering", "tech.hunting", "tech.deadwood_collection",
		"tech.early_trade", "tech.oral_memory_practice",
		"tech.early_knowledge_institution", "tech.flint_identification",
	])
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		# The synchronous headless soak has no worker peer to ACK pending effects;
		# commit completed research directly so technology completion is observable.
		"country_pending_queue_enabled": false,
		"starting_technology_ids": starting,
	}
	_assert_ok(ext.configure_country(native, country_profile, 1, 20260927),
		"configure country")
	var technology_ids: PackedStringArray = compiled.technology_ids
	var starting_indices := PackedInt32Array()
	for technology_id in starting:
		var technology_index := technology_ids.find(technology_id)
		if technology_index >= 0:
			starting_indices.append(technology_index)
	_assert_ok(ext.bootstrap_country({
		"country_ids": PackedStringArray(["country.research_soak"]),
		"country_names": PackedStringArray(["Research Soak"]),
		"country_cash": PackedInt64Array([1000000000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, starting_indices.size()]),
		"technology_indices": starting_indices,
		"discovered_technology_offsets": PackedInt32Array([0, starting_indices.size()]),
		"discovered_technology_indices": starting_indices,
	}, PackedByteArray([0])),
		"bootstrap country")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	profile.startup_demand_runtime_mode = "ACTIVE"
	profile.family_runtime_mode = "OFF"
	_assert_ok(ext.configure_economy(native, profile, 1, 20260927),
		"configure economy")
	var signatures: PackedStringArray = compiled.signature_keys
	var sigs := PackedInt32Array([
		signatures.find("forager|default"),
		signatures.find("hunter|default"),
		signatures.find("artisan|default"),
		signatures.find("researcher|default"),
		signatures.find("merchant|default"),
		signatures.find("industrialist|default"),
		signatures.find("lorekeeper|default"),
	])
	var populations := PackedInt64Array([20, 10, 8, 4, 2, 4, 4])
	var funds := PackedInt64Array([100000000, 100000000, 100000000,
		100000000, 1000000000, 100000000, 100000000])
	var stock := PackedInt64Array()
	stock.resize(compiled.good_ids.size())
	stock.fill(0)
	var good_ids: PackedStringArray = compiled.good_ids
	for good_name in ["gathered_plants", "game_meat", "flint", "raw_stone", "chipped_stone_tools", "technology_points", "logs"]:
		var good_index := good_ids.find(good_name)
		if good_index >= 0:
			stock[good_index] = 1000000000 if good_name == "technology_points" else 5000
	var building_ids: PackedStringArray = compiled.building_type_ids
	var gathering_id := building_ids.find("gathering_ground")
	var hunting_id := building_ids.find("stone_age_hunting_camp")
	var flint_id := building_ids.find("flint_quarry")
	var knapping_id := building_ids.find("knapping_workshop")
	var knowledge_id := building_ids.find("early_knowledge_institution")
	print("[research-soak] building ids gathering=%d hunting=%d flint=%d knapping=%d" % [gathering_id, hunting_id, flint_id, knapping_id])
	_assert_ok(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0, 0, 0, 0, 0, 0]),
		"signature_ids": sigs,
		"population": populations,
		"funds": funds,
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0, 0, 0, 0, 0]),
		"building_type_ids": PackedInt32Array([gathering_id, hunting_id, flint_id, knapping_id, knowledge_id]),
		"building_owner_signature_ids": PackedInt32Array([sigs[0], sigs[1], sigs[0], sigs[2], sigs[6]]),
		"building_counts": PackedInt64Array([8, 4, 2, 2, 1]),
	}), "bootstrap economy")
	var summary := ext.get_country_cell_summary(0)
	var country_handle := int(summary.get("country_handle", 0))
	if country_handle == 0:
		push_error("country handle unavailable")
		quit(1)
		return
	var budget_result := ext.submit_country_commands({
		"opcodes": PackedInt32Array([5, 9]),
		"effective_days": PackedInt64Array([0, 0]),
		"sequences": PackedInt64Array([_sequence, _sequence + 1]),
		"target_handles": PackedInt64Array([country_handle, country_handle]),
		"cell_indices": PackedInt32Array([-1, -1]),
		"aux_i32": PackedInt32Array([0, 1]),
		"domain_i32": PackedInt32Array([-1, -1]),
		"position_i32": PackedInt32Array([-1, -1]),
		"weight0_bp": PackedInt32Array([2500, 0]),
		"weight1_bp": PackedInt32Array([2500, 0]),
		"weight2_bp": PackedInt32Array([2500, 0]),
		"weight3_bp": PackedInt32Array([2500, 0]),
		"value_i64": PackedInt64Array([0, 1000000000]),
		"stable_ids": PackedStringArray(["", ""]),
		"display_names": PackedStringArray(["", ""]),
	})
	_assert_ok(budget_result, "set research budget")
	_sequence += 2
	# Commands with effective_day=0 are committed by the day-0 country slice.
	# Queue the first technology before that barrier so the budget and queue are
	# both active when economy day 1 begins.
	# Reveal the complete catalog for the soak. Research still respects each
	# technology's hard prerequisites through technology_states == 2.
	var reveal_result: Dictionary = ext.submit_country_commands({
		"opcodes": PackedInt32Array([10]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([_sequence]),
		"target_handles": PackedInt64Array([country_handle]),
		"cell_indices": PackedInt32Array([-1]),
		"aux_i32": PackedInt32Array([0]),
		"domain_i32": PackedInt32Array([-1]),
		"position_i32": PackedInt32Array([-1]),
		"weight0_bp": PackedInt32Array([0]),
		"weight1_bp": PackedInt32Array([0]),
		"weight2_bp": PackedInt32Array([0]),
		"weight3_bp": PackedInt32Array([0]),
		"value_i64": PackedInt64Array([0]),
		"stable_ids": PackedStringArray([""]),
		"display_names": PackedStringArray([""]),
	})
	_assert_ok(reveal_result, "reveal technology catalog")
	_sequence += 1
	_queue_next_research(ext, country_handle, compiled, 0)
	var bootstrap_country_day: Dictionary = ext.run_country_slice({
		"day_index": 0,
		"tick_index": 0,
	})
	if bool(bootstrap_country_day.get("fatal", false)):
		push_error("country day-0 slice failed: %s" % bootstrap_country_day)
		quit(1)
		return
	modifier_facade.dispatch_events()
	var bootstrap_economy_day: Dictionary = ext.run_economy_slice({
		"day_index": 0,
		"tick_index": 0,
	})
	if bool(bootstrap_economy_day.get("fatal", false)):
		push_error("economy day-0 slice failed: %s" % bootstrap_economy_day)
		quit(1)
		return
	# Headless scripts do not pump the SceneTree worker boundary. Drive the same
	# authoritative country slice synchronously for deterministic daily commits.
	var final_report: Dictionary = {}
	for day in range(1, target_days + 1):
		var slice_report: Dictionary = ext.run_country_slice({
			"day_index": day,
			"tick_index": day,
		})
		if bool(slice_report.get("fatal", false)) or not bool(slice_report.get("done", true)):
			push_error("runtime slice failed day=%d: %s" % [day, slice_report])
			final_report = slice_report
			break
		_last_day = day
		modifier_facade.dispatch_events()
		_queue_next_research(ext, country_handle, compiled, day)
		var economy_report: Dictionary = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day,
		})
		if bool(economy_report.get("fatal", false)):
			push_error("economy slice failed day=%d: %s" % [day, economy_report])
			final_report = economy_report
			break
		_capture_row(ext, day)
		if day % int(SPEED_DAYS_PER_SECOND * 10.0) == 0:
			print("[research-soak] day=%d" % day)
	final_report = ext.get_runtime_thread_report()
	_save_rows()
	var final_country_snapshot: Dictionary = ext.get_country_snapshot(country_handle)
	var final_research_snapshot: Dictionary = ext.get_country_research_snapshot(country_handle)
	var completed_technology_ids: PackedStringArray = final_country_snapshot.get(
		"technology_ids", PackedStringArray())
	print("research technologies: queued=%d completed=%d completed_total=%s progress_total=%s" % [
		_queued_ids.size(), completed_technology_ids.size(),
		str(final_research_snapshot.get("completed_total", -1)),
		str(final_research_snapshot.get("progress_total", -1))])
	print("research completed ids=%s" % [str(completed_technology_ids)])
	print("research 20y soak: day=%d rows=%d fatal=%s" % [
		_last_day, _rows.size(), str(final_report.get("fatal", false))])
	# `_last_day` is zero-based while rows are one-based; use the row count so
	# shorter diagnostic runs do not report a false process failure merely because
	# they intentionally stop before the full catalog is researched.
	quit(0 if _rows.size() >= target_days and not bool(final_report.get("fatal", false)) else 1)

func _queue_next_research(ext: Object, handle: int, catalog: Dictionary, day: int) -> void:
	var snapshot: Dictionary = ext.get_country_snapshot(handle)
	var completed: PackedStringArray = snapshot.get("technology_ids", PackedStringArray())
	var research: Dictionary = ext.get_country_research_snapshot(handle)
	var technology_states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	var ids: PackedStringArray = catalog.technology_ids
	var domains: PackedInt32Array = catalog.technology_domain_indices
	var priority_target := ""
	for candidate in ["tech.stone_knapping", "tech.ground_stone_tools"]:
		var candidate_index := ids.find(candidate)
		if candidate_index >= 0 and candidate_index < technology_states.size() \
				and technology_states[candidate_index] == 2 \
				and not completed.has(candidate) and not _queued_ids.has(candidate):
			priority_target = candidate
			break
	for node in _technology_nodes:
		if not node is Dictionary:
			continue
		var technology_id := String(node.get("id", ""))
		var i := ids.find(technology_id)
		if not priority_target.is_empty() and technology_id != priority_target:
			continue
		if i < 0 or i >= technology_states.size() or technology_states[i] != 2 \
				or completed.has(technology_id) or _queued_ids.has(technology_id):
			continue
		var result: Variant = ext.submit_country_commands({
			"opcodes": PackedInt32Array([6]),
			"effective_days": PackedInt64Array([0]),
			"sequences": PackedInt64Array([_sequence]),
			"target_handles": PackedInt64Array([handle]),
			"cell_indices": PackedInt32Array([-1]),
			"aux_i32": PackedInt32Array([i]),
			"domain_i32": PackedInt32Array([int(domains[i])]),
			"position_i32": PackedInt32Array([-1]),
			"weight0_bp": PackedInt32Array([0]),
			"weight1_bp": PackedInt32Array([0]),
			"weight2_bp": PackedInt32Array([0]),
			"weight3_bp": PackedInt32Array([0]),
			"value_i64": PackedInt64Array([0]),
			"stable_ids": PackedStringArray([""]),
			"display_names": PackedStringArray([""]),
		})
		if bool(result.get("ok", false)):
			_queued_ids[technology_id] = true
			_sequence += 1
		print("[research-soak] day=%d queued=%s" % [day, technology_id])
		return

func _force_next_technology_activation(ext: Object, handle: int, catalog: Dictionary, day: int) -> void:
	# The headless harness has no worker peer to ACK pending technology effects.
	# Explicitly activate one ready technology per day so the soak always walks
	# the full tree and exercises the economy under continuously changing tech.
	var snapshot: Dictionary = ext.get_country_snapshot(handle)
	var completed: PackedStringArray = snapshot.get("technology_ids", PackedStringArray())
	var ids: PackedStringArray = catalog.technology_ids
	var research: Dictionary = ext.get_country_research_snapshot(handle)
	var technology_states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	for node in _technology_nodes:
		var technology_id := String(node.get("id", ""))
		var technology_index := ids.find(technology_id)
		if technology_index < 0 or technology_index >= technology_states.size() \
				or technology_states[technology_index] != 2 \
				or completed.has(technology_id) or _forced_ids.has(technology_id):
			continue
		var result: Variant = ext.submit_country_commands({
			"opcodes": PackedInt32Array([4]),
			"effective_days": PackedInt64Array([day]),
			"sequences": PackedInt64Array([_sequence]),
			"target_handles": PackedInt64Array([handle]),
			"cell_indices": PackedInt32Array([-1]),
			"aux_i32": PackedInt32Array([technology_index]),
			"domain_i32": PackedInt32Array([-1]),
			"position_i32": PackedInt32Array([-1]),
			"weight0_bp": PackedInt32Array([0]),
			"weight1_bp": PackedInt32Array([0]),
			"weight2_bp": PackedInt32Array([0]),
			"weight3_bp": PackedInt32Array([0]),
			"value_i64": PackedInt64Array([0]),
			"stable_ids": PackedStringArray([""]),
			"display_names": PackedStringArray([""]),
		})
		if bool(result.get("ok", false)):
			_forced_ids[technology_id] = true
			_sequence += 1
			print("[research-soak] day=%d activated=%s" % [day, technology_id])
		return

func _capture_row(ext: Object, day: int) -> void:
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_rows.append({
		"day": day,
		"population": _sum_i64(pop.get("populations", PackedInt64Array())),
		"unemployed": _sum_i64(pop.get("unemployed_by_cohort", PackedInt64Array())),
		"gathered_plants_stock": _good(market, "stock", "gathered_plants"),
		"gathered_plants_shortage_q16": _good(market, "shortage_q16", "gathered_plants"),
		"gathered_plants_demand": _good(market, "demand_ema", "gathered_plants"),
		"gathered_plants_price": _good(market, "price", "gathered_plants"),
		"game_meat_stock": _good(market, "stock", "game_meat"),
		"game_meat_shortage_q16": _good(market, "shortage_q16", "game_meat"),
		"game_meat_demand": _good(market, "demand_ema", "game_meat"),
		"game_meat_price": _good(market, "price", "game_meat"),
		"flint_stock": _good(market, "stock", "flint"),
		"flint_price": _good(market, "price", "flint"),
		"flint_demand": _good(market, "demand_ema", "flint"),
		"flint_shortage_q16": _good(market, "shortage_q16", "flint"),
		"flint_business_demand": _good(market, "business_demand_ema", "flint"),
		"chipped_stone_tools_stock": _good(market, "stock", "chipped_stone_tools"),
		"chipped_stone_tools_business_demand": _good(market, "business_demand_ema", "chipped_stone_tools"),
		"food_buildings": (buildings.get("group_type_ids", PackedInt32Array()) as PackedInt32Array).size(),
		"building_diagnostics": _building_diagnostics(buildings),
	})

func _building_diagnostics(buildings: Dictionary) -> Array:
	var type_ids: PackedStringArray = buildings.get("building_type_ids", PackedStringArray())
	var groups: PackedInt32Array = buildings.get("group_type_ids", PackedInt32Array())
	var counts: PackedInt64Array = buildings.get("group_counts", PackedInt64Array())
	var owners: PackedInt64Array = buildings.get("filled_owner", PackedInt64Array())
	var owner_capacity: PackedInt64Array = buildings.get("owner_capacity", PackedInt64Array())
	var owner_required: PackedInt64Array = buildings.get("owner_required", PackedInt64Array())
	var employee_required: PackedInt64Array = buildings.get("employee_required", PackedInt64Array())
	var employee_filled: PackedInt64Array = buildings.get("employee_filled", PackedInt64Array())
	var util: PackedInt32Array = buildings.get("planned_utilization_q16", PackedInt32Array())
	var state: PackedByteArray = buildings.get("operating_state", PackedByteArray())
	var output: PackedInt64Array = buildings.get("last_output", PackedInt64Array())
	var input: PackedInt64Array = buildings.get("last_input", PackedInt64Array())
	var revenue: PackedInt64Array = buildings.get("last_expected_revenue", PackedInt64Array())
	var cost: PackedInt64Array = buildings.get("last_operating_cost", PackedInt64Array())
	var margin: PackedInt32Array = buildings.get("last_margin_gap_q16", PackedInt32Array())
	var out: Array = []
	for i in range(groups.size()):
		var type_index := int(groups[i])
		if type_index < 0 or type_index >= type_ids.size():
			continue
		var id := String(type_ids[type_index])
		if not (id.contains("gather") or id.contains("hunt") or id.contains("farm") or id.contains("hearth") or id.contains("food") or id.contains("flint") or id.contains("knapping") or id.contains("tool")):
			continue
		out.append({"id": id, "count": _arr_i64(counts, i), "owner": _arr_i64(owners, i), "owner_capacity": _arr_i64(owner_capacity, i), "owner_required": _arr_i64(owner_required, i), "employee_required": _arr_i64(employee_required, i), "employee_filled": _arr_i64(employee_filled, i), "util_q16": _arr_i32(util, i), "state": _arr_u8(state, i), "last_output": _arr_i64(output, i), "last_input": _arr_i64(input, i), "expected_revenue": _arr_i64(revenue, i), "operating_cost": _arr_i64(cost, i), "margin_gap_q16": _arr_i32(margin, i)})
	return out

func _arr_i64(values: PackedInt64Array, index: int) -> int:
	return int(values[index]) if index >= 0 and index < values.size() else 0

func _arr_i32(values: PackedInt32Array, index: int) -> int:
	return int(values[index]) if index >= 0 and index < values.size() else 0

func _arr_u8(values: PackedByteArray, index: int) -> int:
	return int(values[index]) if index >= 0 and index < values.size() else 0

func _good(snapshot: Dictionary, field: String, id: String) -> int:
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var values: Variant = snapshot.get(field, PackedInt64Array())
	var i := ids.find(id)
	return int(values[i]) if i >= 0 and i < values.size() else 0

func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total

func _register_cell_components(ext: Object, compiled: Dictionary) -> void:
	var scalar := PackedFloat32Array([0.5])
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip",
			&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, PackedByteArray([0]))
	var resources: PackedStringArray = compiled.building_resource_ids
	var reserve_slots: PackedStringArray = compiled.building_resource_reserve_slots
	var extra_slots: PackedStringArray = compiled.building_resource_extra_slots
	for i in range(resources.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, PackedFloat32Array([1000000000.0]))
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))

func _assert_ok(result: Dictionary, label: String) -> void:
	if not bool(result.get("ok", false)):
		push_error("%s failed: %s" % [label, result])

func _save_rows() -> void:
	var path := OS.get_environment("PK_RESEARCH_SOAK_OUTPUT")
	if path.is_empty():
		path = "user://economy_research_20y_soak.json"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_rows))
