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
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var map_config := MapConfig.make(40, 28)
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
	_expect("formal starter bootstrap succeeds",
		bool(start.get("ok", false)) and start_cell >= 0)
	var economy = generator.get_economy_facade()
	_expect("starter economy is configured", economy != null and economy.is_configured())
	if economy == null or not economy.is_configured() or start_cell < 0:
		_finish()
		return
	_expect("starter population begins at exactly 20",
		int(economy.population_cell_snapshot(start_cell).get("population", 0)) == 20)

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
	_expect("every completed starter settlement day conserves all ledgers",
		completed_days == soak_days and all_commits_conserved)
	_expect("every completed starter settlement day contains only finite values",
		completed_days == soak_days and all_values_finite)
	_finish()


func _configured_soak_days() -> int:
	var value := OS.get_environment("PK_STARTER_SETTLEMENT_SOAK_DAYS").strip_edges()
	return maxi(1, int(value)) if value.is_valid_int() else DEFAULT_SOAK_DAYS


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
		if bool(ext.country_should_run(day)):
			scheduler.continue_system(&"country_daily", ctx)
			await process_frame
			continue
		if bool(ext.economy_should_run(day)):
			var continued: Dictionary = scheduler.continue_system(&"economy_daily", ctx)
			if bool(continued.get("fatal", false)):
				return ext.get_economy_report()
			await process_frame
			continue
		var report: Dictionary = ext.get_economy_report()
		report["done"] = true
		return report
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


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _finish() -> void:
	print("starter settlement soak: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
