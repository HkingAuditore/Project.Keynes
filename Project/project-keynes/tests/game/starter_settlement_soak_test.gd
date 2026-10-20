extends SceneTree

const CHECKPOINT_DAYS := [60, 730, 3650]
const DEFAULT_SOAK_DAYS := 3650
const MAX_SLICES_PER_DAY := 2048

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
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
	var map_config := MapConfig.make(int(config.base.map_width), int(config.base.map_height))
	map_config.seed = int(config.base.initial_seed)
	map_config.num_continents = int(config.base.num_continents)
	map_config.continent_size = float(config.base.continent_size)
	map_config.sea_level = float(config.base.sea_level)
	map_config.river_count = int(config.base.river_count)
	map_config.climate_profile = profile
	var clock := WorldClock.new()
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.set_world_clock_ref(clock)
	generator.set_gameplay_start_config(config.to_dictionary())
	var generated: Dictionary = await generator.generate(map_config, 10.0)
	var map: MapData = generated.get("map", null)
	_expect("formal starter world generates", map != null)
	if map == null:
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
		_finish()
		return
	_expect("starter population begins at exactly 20",
		int(economy.population_cell_snapshot(start_cell).get("population", 0)) == 20)
	var opening_buildings: Dictionary = economy.building_cell_snapshot(start_cell)
	_expect("opening food lots operate without leftover construction techs",
		_food_lots_operable(opening_buildings,
			player_start.get("starter_building_ids", PackedStringArray())))
	var opening_families: Dictionary = economy.family_cell_snapshot(start_cell, 0, 64)
	var opening_family_handles: PackedInt64Array = opening_families.get(
		"family_handles", PackedInt64Array())
	_expect("starter capital begins with one founder family",
		opening_family_handles.size() == 1)
	if opening_family_handles.size() == 1:
		var opening_people: Dictionary = economy.family_notable_people(
			int(opening_family_handles[0]), 0, 64)
		_expect("starter capital begins with one notable founder",
			int(opening_people.get("total", 0)) == 1)

	var soak_days := _configured_soak_days()
	var all_commits_conserved := true
	var all_values_finite := true
	var completed_days := 0
	for day in range(soak_days):
		var report := await _run_day(generator, economy, clock, day)
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
		completed_days = day + 1
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
			_expect("%d-day checkpoint starter population does not decline" % completed_days,
				int(population_snapshot.get("population", 0)) >= 20)
	_expect("every completed starter settlement day conserves all ledgers",
		completed_days == soak_days and all_commits_conserved)
	_expect("every completed starter settlement day contains only finite values",
		completed_days == soak_days and all_values_finite)
	_finish()


func _configured_soak_days() -> int:
	var value := OS.get_environment("PK_STARTER_SETTLEMENT_SOAK_DAYS").strip_edges()
	return maxi(1, int(value)) if value.is_valid_int() else DEFAULT_SOAK_DAYS


func _configured_int(name: String, fallback: int) -> int:
	var value := OS.get_environment(name).strip_edges()
	return int(value) if value.is_valid_int() else fallback


func _run_day(generator: MapGenerator, economy, clock: WorldClock, day: int) -> Dictionary:
	var ext: Object = economy.world_ext()
	var phase := float(day % 365) / 365.0
	generator.sus_tick_daily(clock, day, phase)
	var bootstrap = generator.get_sus_bootstrap()
	var scheduler = bootstrap.get_scheduler() if bootstrap != null else null
	if scheduler == null:
		return {"fatal": true, "fatal_reason": "starter_soak_scheduler_unavailable"}
	var ctx := SusTickContext.make(
		day, day, phase, 1.0, &"country_economy_continuation")
	for _slice in range(MAX_SLICES_PER_DAY):
		# Research completions emit Effect recipes. Dispatch those first, then
		# let Country consume the resulting effect commands in the same slice
		# before ACK. Country-before-drain left native_country_ack_pending=1.
		var drained := int(generator.call("_drain_native_effect_ack_chain", ctx))
		var country_busy := bool(ext.country_should_run(day))
		if country_busy:
			scheduler.continue_system(&"country_daily", ctx)
		generator.call("_ack_native_effect_domain_bindings")
		var ack_passes := 1
		while ack_passes < 8 and bool(generator.call("_hard_effect_ack_chain_due", day)):
			drained += int(generator.call("_drain_native_effect_ack_chain", ctx))
			if bool(ext.country_should_run(day)):
				scheduler.continue_system(&"country_daily", ctx)
			generator.call("_ack_native_effect_domain_bindings")
			ack_passes += 1
		if bool(ext.economy_should_run(day)):
			var continued: Dictionary = scheduler.continue_system(&"economy_daily", ctx)
			if bool(continued.get("fatal", false)):
				return ext.get_economy_report()
			await process_frame
			continue
		if country_busy or bool(ext.country_should_run(day)) \
				or bool(generator.call("_hard_effect_ack_chain_due", day)):
			await process_frame
			continue
		var report: Dictionary = ext.get_economy_report()
		report["done"] = true
		return report
	print("starter soak drain stuck day=%d country=%s economy=%s ack=%s" % [
		day,
		ext.country_should_run(day) if ext.has_method("country_should_run") else "n/a",
		ext.economy_should_run(day) if ext.has_method("economy_should_run") else "n/a",
		generator.call("_hard_effect_ack_chain_due", day)])
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
	quit(0 if _failures == 0 else 1)
