extends SceneTree

const CHECKPOINT_DAYS := [60, 730, 3650]
const DEFAULT_SOAK_DAYS := 3650
const MAX_SLICES_PER_DAY := 2048


class OpeningSnapshotHost extends WorldRuntimeHost:
	var opening: Dictionary = {}

	func _start_production_shadow_worker() -> void:
		if opening.is_empty() and _generator != null:
			var start: Dictionary = _generator.gameplay_start_report()
			var cell := int(start.get("cell", -1))
			var economy = _generator.get_economy_facade()
			if cell >= 0 and economy != null and economy.is_configured():
				# World ready can arrive while the first settlement owns the read
				# boundary. Capture the actual opening state before starting it.
				var families: Dictionary = economy.family_cell_snapshot(cell, 0, 64)
				var handles: PackedInt64Array = families.get("family_handles", PackedInt64Array())
				opening = {"cell": cell, "committed_day": economy.report().get("last_committed_day", -2),
					"population": economy.population_cell_snapshot(cell),
					"buildings": economy.building_cell_snapshot(cell), "families": families,
					"people": economy.family_notable_people(int(handles[0]), 0, 64) if handles.size() == 1 else {}}
		super._start_production_shadow_worker()


var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var config := NewGameConfig.create_default()
	config.country.name = "Starter Soak Nation"
	config.country.foreign_count = _configured_int("PK_STARTER_SETTLEMENT_FOREIGN_COUNT", 3)
	config.base.map_width = _configured_int("PK_STARTER_SETTLEMENT_MAP_WIDTH", 40)
	config.base.map_height = _configured_int("PK_STARTER_SETTLEMENT_MAP_HEIGHT", 28)
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var clock := WorldClock.new()
	clock.auto_start = false
	root.add_child(clock)
	clock.set_process(false)
	var host := OpeningSnapshotHost.new()
	host.runtime_economy_auto_pod_active = true
	root.add_child(host)
	host.configure(null, null, clock)
	# Match PlayerGame: AUTO is a diagnostic size policy, not the formal path.
	host.set_climate_authority_override("force_on")
	var configured := host.configure_session({"kind": "new_game", "config": config.to_dictionary()})
	_expect("formal starter session configures", bool(configured.get("ok", false)))
	await host.generate_world()
	var generator := host.get_generator()
	var map: MapData = host.current_map()
	_expect("formal starter world generates", map != null)
	if map == null:
		await host.close_world()
		host.free()
		clock.free()
		_finish()
		return
	var start: Dictionary = generator.gameplay_start_report()
	var start_cell := int(start.get("cell", -1))
	if not bool(start.get("ok", false)):
		print("starter bootstrap failure: ", start)
	_expect("formal starter bootstrap succeeds",
		bool(start.get("ok", false)) and start_cell >= 0)
	var player_start: Dictionary = {}
	if (start.get("country_starts", []) as Array).size() > 0:
		player_start = (start.get("country_starts", []) as Array)[0]
	_expect("soak grants gathering and hunting",
		(player_start.get("starter_technology_ids", PackedStringArray()) as PackedStringArray).has(
			"tech.gathering")
		and (player_start.get("starter_technology_ids", PackedStringArray()) as PackedStringArray).has(
			"tech.hunting"))
	if String(player_start.get("regional_route", "")) == "cold_highland":
		_expect("cold soak grants hide scraping",
			(player_start.get("starter_technology_ids", PackedStringArray()) as PackedStringArray).has(
				"tech.hide_scraping")
			and (player_start.get("starter_building_ids", PackedStringArray()) as PackedStringArray).has(
				"hide_scraping_shelter"))
	var economy = generator.get_economy_facade()
	_expect("starter economy is configured", economy != null and economy.is_configured())
	if economy == null or not economy.is_configured() or start_cell < 0:
		await host.close_world()
		host.free()
		clock.free()
		_finish()
		return
	var opening := host.opening
	_expect("opening snapshots belong to the capital before the first settlement",
		opening.get("cell", -1) == start_cell and opening.get("committed_day", -2) == -1)
	var opening_population: Dictionary = opening.get("population", {})
	_expect("starter population begins at exactly 40",
		int(opening_population.get("population", 0)) == 40)
	var opening_buildings: Dictionary = opening.get("buildings", {})
	_expect("opening food lots operate without leftover construction techs",
		_food_lots_operable(opening_buildings,
			player_start.get("starter_building_ids", PackedStringArray())))
	var opening_families: Dictionary = opening.get("families", {})
	var opening_family_handles: PackedInt64Array = opening_families.get(
		"family_handles", PackedInt64Array())
	_expect("starter capital begins with one founder family",
		opening_family_handles.size() == 1)
	if opening_family_handles.size() == 1:
		var opening_people: Dictionary = opening.get("people", {})
		_expect("starter capital begins with one notable founder",
			int(opening_people.get("total", 0)) == 1)

	# Drive one semantic day at a time through the formal session. The ordinary
	# host performs input capture, peer service and commit consumption; the test
	# only controls when the next day is submitted so no ledger sample is missed.
	clock.pause(false)
	var soak_days := _configured_soak_days()
	var all_commits_conserved := true
	var all_values_finite := true
	var completed_days := 0
	for day in range(1, soak_days + 1):
		var report := await _run_day(host, economy, clock, day)
		var committed := bool(report.get("done", false)) \
			and not bool(report.get("fatal", false)) \
			and int(report.get("last_completed_sample_day", -1)) == day
		var conserved := int(report.get("population_error", 1)) == 0 \
			and int(report.get("money_error", 1)) == 0 \
			and int(report.get("goods_error", 1)) == 0
		var finite := _variant_is_finite(report)
		all_commits_conserved = all_commits_conserved and committed and conserved
		all_values_finite = all_values_finite and finite
		if not committed or not conserved or not finite:
			push_error("starter soak failed on day %d: fatal=%s reason=%s errors=%s/%s/%s" % [
				day, str(report.get("fatal", false)), str(report.get("fatal_reason", "")),
				str(report.get("population_error", "missing")),
				str(report.get("money_error", "missing")),
				str(report.get("goods_error", "missing"))])
			break
		completed_days = day
		if completed_days in CHECKPOINT_DAYS:
			var population_snapshot: Dictionary = economy.population_cell_snapshot(start_cell)
			var market_snapshot: Dictionary = economy.market_cell_snapshot(start_cell)
			var building_snapshot: Dictionary = economy.building_cell_snapshot(start_cell)
			_expect("%d-day checkpoint reaches an exact committed boundary" % completed_days,
				int(report.get("last_completed_sample_day", -1)) == day)
			_expect("%d-day checkpoint snapshots contain only finite values" % completed_days,
				_variant_is_finite(population_snapshot) \
				and _variant_is_finite(market_snapshot) \
				and _variant_is_finite(building_snapshot))
			_expect("%d-day checkpoint starter population stays above the survival floor" % completed_days,
				int(population_snapshot.get("population", 0)) >= 20)
	_expect("every completed starter settlement day conserves all ledgers",
		completed_days == soak_days and all_commits_conserved)
	_expect("every completed starter settlement day contains only finite values",
		completed_days == soak_days and all_values_finite)
	_expect("starter session closes and releases its executor", bool((await host.close_world()).get("ok", false)))
	host.free()
	clock.free()
	_finish()


func _configured_soak_days() -> int:
	var value := OS.get_environment("PK_STARTER_SETTLEMENT_SOAK_DAYS").strip_edges()
	return maxi(1, int(value)) if value.is_valid_int() else DEFAULT_SOAK_DAYS


func _configured_int(name: String, fallback: int) -> int:
	var value := OS.get_environment(name).strip_edges()
	return int(value) if value.is_valid_int() else fallback


func _run_day(host: WorldRuntimeHost, economy, clock: WorldClock, day: int) -> Dictionary:
	var generator := host.get_generator()
	clock.current_day = float(day + 1)
	# Same headless driver as headless_perf_record: exercise the daily runtime
	# without opening annual-report UI, whose year-end catchup can submit extra
	# days before the test reads this day's ledger.
	host.run_daily_tick(day + 1, clock.season_phase())
	host.finish_daily_tick(0.0, {})
	for _slice in range(MAX_SLICES_PER_DAY):
		host._process(0.0)
		var runtime: Dictionary = generator.get_runtime_thread_report()
		if String(runtime.get("simulation_host_state", "")) == "FAULTED":
			return {"fatal": true, "fatal_reason": runtime.get("fault_code", "worker_fault")}
		if int(runtime.get("simulation_committed_day", -1)) >= day:
			var report: Dictionary = economy.world_ext().get_economy_report()
			if bool(report.get("fatal", false)):
				return report
			if not bool(report.get("report_boundary_pending", false)) \
					and int(report.get("last_completed_sample_day", -1)) == day:
				# A state snapshot has no `done` flag. Supply it only after the
				# executor and this ledger both publish the requested exact day.
				report["done"] = true
				return report
		await process_frame
	print("starter soak drain stuck day=%d runtime=%s economy=%s" % [
		day, generator.get_runtime_thread_report(), economy.world_ext().get_economy_report()])
	return {"fatal": true, "fatal_reason": "starter_soak_slice_limit"}


func _variant_is_finite(value) -> bool:
	match typeof(value):
		TYPE_FLOAT:
			return is_finite(float(value))
		TYPE_DICTIONARY:
			for entry in (value as Dictionary).values():
				if not _variant_is_finite(entry):
					return false
		TYPE_ARRAY:
			for entry in value as Array:
				if not _variant_is_finite(entry):
					return false
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			for entry in value:
				if not is_finite(float(entry)):
					return false
	return true


func _food_lots_operable(snapshot: Dictionary, route_buildings: PackedStringArray) -> bool:
	if not route_buildings.has("gathering_ground"):
		return false
	for building_id in ["gathering_ground", "stone_age_hunting_camp"]:
		if not route_buildings.has(building_id):
			continue
		var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
		var available = snapshot.get("building_technology_available", PackedByteArray())
		var type_index := ids.find(building_id)
		if type_index < 0 or type_index >= available.size() or int(available[type_index]) == 0:
			return false
		var group_types: PackedInt32Array = snapshot.get("group_type_ids", PackedInt32Array())
		var filled: PackedInt64Array = snapshot.get("filled_owner", PackedInt64Array())
		var fill := 0
		for group in range(mini(group_types.size(), filled.size())):
			if int(group_types[group]) == type_index:
				fill += int(filled[group])
		if fill <= 0:
			return false
	return true


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _finish() -> void:
	print("starter settlement soak: %d checks, %d failures" % [_checks, _failures])
	# Release the fixture's local facades and completed coroutine frames before
	# SceneTree tears down ObjectDB. Real leaked owners still fail the outer gate.
	call_deferred("quit", 0 if _failures == 0 else 1)
