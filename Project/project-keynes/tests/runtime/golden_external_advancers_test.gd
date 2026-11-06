extends "res://tests/runtime/golden_day_hash_test.gd"

# Independent world and command log; the v1-v4 fixture is never modified.
const EXTERNAL_BASELINE := "res://tests/runtime/golden_external_advancers_baseline.v5.json"
const EXTERNAL_DAYS := 4
const FAMILY_FIELDS := ["family_handles", "stable_ids", "populations", "cash_claims",
    "owned_buildings", "home_cells", "origin_cells", "origin_ethnicity_ids",
    "culture_group_ids", "notable_person_counts", "prestige_levels", "prestige_scores_q16"]
const PERSON_FIELDS := ["person_handle", "stable_id", "family_handle", "cohort_handle",
    "notable_since_day", "cell_idx", "profession_id", "cash_claim", "family_equity_share_q32",
    "epoch_job_income", "epoch_business_result", "epoch_consumption_expense", "epoch_tax",
    "income_ema", "needs_satisfaction_q16", "worst_need_id", "building_handle", "job_kind",
    "employee_role_index", "job_since_day"]

func _run() -> void:
	OS.set_environment("PK_GOLDEN_DOMAINS", "0")
	var config := NewGameConfig.create_default()
	config.country.name = "External Golden Nation"
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	var host := _create_host()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	_expect("golden configures", bool(host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()}).get("ok", false)))
	await host.generate_world()
	var generator := host.get_generator()
	var start: Dictionary = generator.gameplay_start_report()
	var cell := int(start.get("cell", -1))
	var economy = generator.get_economy_facade()
	_expect("replay cadence is fixed", preload("res://tests/runtime/replay_cadence.gd").install(economy.world_ext()))
	_expect("golden has a populated starter", bool(start.get("ok", false)) and cell >= 0)
	var ext: Object = economy.world_ext()
	var military = generator.get_military_facade()
	_expect("v5 military configured", military != null and military.is_configured())
	var handle := int(ext.get_country_cell_summary(cell).get("country_handle", 0))
	var opening_resources := _resource_state(ext)
	var opening_reserves: Array = opening_resources.reserves
	var rows: Array = []
	var chain := "keynes-external-v5:seed=20260727:days1-4:target=2,3,4,5"
	clock.pause(false)
	for day in range(1, EXTERNAL_DAYS + 1):
		# This is a real player command, accepted before the next day is released.
		_expect("v5 military target accepted", bool(military.set_target(handle, 0, day + 1).get("ok", false)))
		var report := await _run_day(host, economy, clock, day)
		_expect("v5 economy commits", bool(report.get("done", false)))
		_expect("v5 all ledgers conserved", int(report.get("money_error", -1)) == 0
			and int(report.get("goods_error", -1)) == 0 and int(report.get("population_error", -1)) == 0)
		_expect("v5 full ACTIVE grant", int(generator.get_runtime_thread_report().get("authoritative_domain_mask", 0)) == 0xFFF)
		_expect("v5 economy same-day writeback", await _wait_golden_read_boundary(host, economy, day))
		var caught_up := false
		for _slice in range(MAX_SLICES_PER_DAY):
			host._process(0.0)
			if host._runtime_military_last_commit_day == day and host._runtime_natural_resource_last_commit_day == day:
				caught_up = true
				break
			await process_frame
		_expect("v5 main-thread advancers caught up", caught_up)
		if not caught_up:
			break
		var army: Dictionary = military.country_snapshot(handle)
		_expect("v5 military command applied, not only a date change", int(army.get("target_value", -1)) == day + 1)
		var resource := _resource_state(ext)
		var recovery_count := 0
		for i in range(resource.reserves.size()):
			var previous: PackedFloat32Array = opening_reserves[i]
			var current: PackedFloat32Array = resource.reserves[i]
			for j in range(current.size()):
				if current[j] > previous[j]:
					recovery_count += 1
		_expect("v5 resource recovery actually increases reserves", recovery_count > 0)
		var families: Array = []
		var people: Array = []
		var handles: Array[int] = []
		var all_family_reads := true
		for index in range(host.get_current_map().cell_count()):
			var offset := 0
			while true:
				var family: Dictionary = ext.get_family_cell_snapshot(index, offset, 64)
				all_family_reads = all_family_reads and _current_read(family, day)
				if not _current_read(family, day):
					break
				if int(family.get("total", 0)) > 0:
					families.append([index, offset, _fields(family, FAMILY_FIELDS)])
					for id in family.get("family_handles", PackedInt64Array()):
						if not handles.has(int(id)):
							handles.append(int(id))
				if not bool(family.get("has_more", false)):
					break
				offset += 64
		_expect("v5 all family reads are current committed state", all_family_reads)
		for id in handles:
			var offset := 0
			while true:
				var list: Dictionary = ext.get_family_notable_people(id, offset, 64)
				_expect("v5 people list is committed", _current_read(list, day))
				for person_id in list.get("person_handles", PackedInt64Array()):
					var person: Dictionary = ext.get_notable_person_snapshot(person_id)
					_expect("v5 person is committed", _current_read(person, day))
					people.append(_fields(person, PERSON_FIELDS))
				if not bool(list.get("has_more", false)):
					break
				offset += 64
		_expect("v5 populated family/person coverage", not families.is_empty() and not people.is_empty())
		var map := host.get_current_map()
		var vision: Array = [host._physical_visible_arr.hex_encode(), map.explored_arr.hex_encode(), map.fog_k_arr.hex_encode()]
		var hashes := {"MILITARY": _digest(_canonical(army)), "NATURAL_RESOURCE": resource.hash,
			"FAMILY": _digest(families), "PERSON": _digest(people), "VISION": _digest(vision)}
		if OS.get_environment("PK_GOLDEN_DIAGNOSTICS") == "1":
			print("GOLDEN_EXTERNAL_DIAGNOSTIC=" + JSON.stringify({"day": day, "military": _canonical(army),
				"family": families, "person": people, "vision": vision, "resources": resource.columns}))
		chain = (chain + ":" + JSON.stringify(_canonical(hashes))).sha256_text()
		rows.append({"day": day, "hashes": hashes, "chain": chain,
			"military_target": army.target_value, "soldiers": army.get("soldiers_total", 0),
			"recovered_cells": recovery_count, "families": handles.size(), "people": people.size()})
	var result := {"version": 5, "seed": 20260727, "days": rows,
		"scope": "military_country_projection;all_resource_reserve_and_pending_columns;family_cell_and_person_projections;physical_vision"}
	_expect("v5 every day sampled", rows.size() == EXTERNAL_DAYS)
	print("GOLDEN_EXTERNAL_RESULT=" + JSON.stringify(result))
	if OS.get_environment("PK_GOLDEN_EXTERNAL_CAPTURE") != "1":
		_expect("v5 matches reviewed baseline", JSON.parse_string(FileAccess.get_file_as_string(EXTERNAL_BASELINE)) == JSON.parse_string(JSON.stringify(result)))
	_expect("v5 closes", bool((await host.close_world()).get("ok", false)))
	host.free()
	clock.free()
	_finish()

func _current_read(value: Dictionary, day: int) -> bool:
	return bool(value.get("ok", false)) and not bool(value.get("read_view_pending", false)) and int(value.get("read_view_day", day)) == day

func _fields(value: Dictionary, fields: Array) -> Array:
	var result: Array = []
	for field in fields:
		_expect("v5 projection contains " + field, value.has(field))
		result.append(value.get(field))
	return result

func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort()
		var result: Array = []
		for key in keys:
			result.append([key, _canonical(value[key])])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_canonical(item))
		return result
	return value

func _digest(value: Variant) -> String:
	return JSON.stringify(value).sha256_text()

func _resource_state(ext: Object) -> Dictionary:
	var columns: Array = []
	var reserves: Array = []
	for profile in ResourceProfileRegistry.ordered():
		var reserve_name := ResourceProfileRegistry.reserve_cpp_name(profile)
		var extra_name := ResourceProfileRegistry.extra_change_cpp_name(profile)
		var reserve: PackedFloat32Array = ext.snapshot_f32(ext.component_id(reserve_name))
		var extra: PackedFloat32Array = ext.snapshot_f32(ext.component_id(extra_name))
		_expect("v5 complete resource columns", reserve.size() == 40 * 28 and extra.size() == reserve.size())
		reserves.append(reserve)
		columns.append([String(profile.id), reserve.to_byte_array().hex_encode(), extra.to_byte_array().hex_encode()])
	return {"hash": _digest(columns), "reserves": reserves, "columns": columns}

# Test seam: the default fixture still constructs the production host.
func _create_host() -> WorldRuntimeHost:
	return WorldRuntimeHost.new()
