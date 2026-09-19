extends SceneTree

# Headless perf breakdown for native_daily ACTIVE.
#   godot --headless --script tests/tmp_native_perf_breakdown.gd --quit
#
# Purpose (Phase 2 grounding): localize where the ~8.9ms/tick goes in native
# ACTIVE so we can decide which graph nodes to cadence-gate. Uses the REAL
# earth_like.tres knobs (runtime_hydrology_enabled=true, perf_target=3.0) and a
# realistic ~2400-cell map. Prints per-day node attribution + aggregates.

const MAP_W: int = 56
const MAP_H: int = 44
const DAYS: int = 32


func _init() -> void:
	_run()
	quit(0)


func _run() -> void:
	print("=== native daily ACTIVE perf breakdown (%dx%d=%d cells, %d days) ===" % [MAP_W, MAP_H, MAP_W * MAP_H, DAYS])
	if not ClassDB.class_exists("DCWorldExt"):
		print("  [SKIP] DCWorldExt class not found")
		return

	var profile: ClimateProfile = _make_profile()
	var cfg: MapConfig = MapConfig.make(MAP_W, MAP_H)
	cfg.seed = 717171
	cfg.num_continents = 3
	cfg.sea_level = 0.58
	cfg.continent_size = 0.72
	cfg.climate_profile = profile

	var generator := MapGenerator.new()
	generator.climate_profile = profile
	var gen_t0: int = Time.get_ticks_usec()
	var generated: Dictionary = await generator.generate(cfg, 10.0)
	var gen_ms: float = float(Time.get_ticks_usec() - gen_t0) / 1000.0
	var map: MapData = generated.get("map", null) as MapData
	var world: WorldData = generated.get("world_data", null) as WorldData
	if map == null or world == null:
		print("  [FAIL] map/world generation failed")
		return
	print("  generated in %.1f ms; soa_size=%d" % [gen_ms, map.soa_size()])

	# Aggregates
	var tick_wall: Array[float] = []
	var node_sum: Dictionary = {}   # node_ms field -> total
	var node_days: Dictionary = {}  # node_ms field -> count of completed-round days it was > 0
	var completed_days: int = 0
	var pass_key_days: Dictionary = {}  # pass_key -> count of days embedded

	var node_fields: Array[String] = [
		"climate_ms", "ocean_ms", "wind_ms", "sea_ice_ms", "transp_ms",
		"weather_ms", "hydrology_ms", "stage_b_ms",
		"native_context_ms", "round_native_ms",
		"round_bundle_ms", "round_native_call_ms", "round_apply_ms", "round_slice_count",
		"finalizer_total_ms", "finalizer_temp_ms", "finalizer_tta_ms", "finalizer_thermal_ms",
		"finalizer_sort_ms", "finalizer_sea_ice_ms", "finalizer_precip_ms", "finalizer_write_dense_ms",
	]
	for f in node_fields:
		node_sum[f] = 0.0
		node_days[f] = 0

	print("")
	print("day | wall_ms | bundle | native_call | round_nat | refresh | climate | ocean | wind | seaice | weather | hydro | stageB | keys")
	for day in range(1, DAYS + 1):
		var t0: int = Time.get_ticks_usec()
		generator.sus_tick_daily(null, day, float(day % 365) / 365.0)
		var wall_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
		tick_wall.append(wall_ms)

		var res: Dictionary = generator.native_daily_last_result()
		var bd: Dictionary = res.get("breakdown", {})
		var done: bool = bool(res.get("done", false))
		var rc: int = int(res.get("rc", -1))
		var keys: Array = res.get("bundle_pass_keys", [])
		var key_tags: PackedStringArray = PackedStringArray()
		for k in keys:
			var ks: String = str(k)
			if ks == "weather_knobs":
				key_tags.append("W")
			elif ks == "sea_ice_knobs":
				key_tags.append("I")
			elif ks == "climate_pass_a_struct":
				key_tags.append("Ca")
			elif ks == "climate_pass_b_knobs":
				key_tags.append("Cb")
			elif ks == "stage_b_knobs" or ks == "stage_b_after_hydrology_knobs":
				key_tags.append("Sb")
			elif ks == "runtime_hydrology_knobs":
				key_tags.append("H")
			elif ks == "ocean_water_knobs":
				key_tags.append("O")
			pass_key_days[ks] = int(pass_key_days.get(ks, 0)) + 1

		if done and rc == 0:
			completed_days += 1
			for f in node_fields:
				var v: float = float(bd.get(f, 0.0))
				node_sum[f] = float(node_sum[f]) + v
				if v > 0.0001:
					node_days[f] = int(node_days[f]) + 1

		print("%3d | %7.2f | %6.2f | %11.2f | %9.2f | %7.2f | %7.2f | %5.2f | %4.2f | %6.2f | %7.2f | %5.2f | %6.2f | %s" % [
			day, wall_ms,
			float(bd.get("bundle_ms", 0.0)),
			float(bd.get("native_call_ms", 0.0)),
			float(bd.get("round_native_ms", 0.0)),
			float(bd.get("native_context_ms", 0.0)),
			float(bd.get("climate_ms", 0.0)),
			float(bd.get("ocean_ms", 0.0)),
			float(bd.get("wind_ms", 0.0)),
			float(bd.get("sea_ice_ms", 0.0)),
			float(bd.get("weather_ms", 0.0)),
			float(bd.get("hydrology_ms", 0.0)),
			float(bd.get("stage_b_ms", 0.0)),
			"+".join(key_tags),
		])

	# Aggregate stats
	tick_wall.sort()
	var n: int = tick_wall.size()
	var sum_wall: float = 0.0
	for v in tick_wall:
		sum_wall += v
	var mean_wall: float = sum_wall / float(maxi(1, n))
	var p95: float = tick_wall[clampi(int(floor(0.95 * float(n))), 0, n - 1)]
	var max_wall: float = tick_wall[n - 1]
	print("")
	print("=== aggregate over %d days (completed rounds=%d) ===" % [DAYS, completed_days])
	print("  tick wall: mean=%.2fms p95=%.2fms max=%.2fms min=%.2fms" % [mean_wall, p95, max_wall, tick_wall[0]])
	print("  per-completed-round node averages (sum/completed_days), and #days each node ran:")
	var cdays: int = maxi(1, completed_days)
	for f in node_fields:
		print("    %-18s avg=%6.3fms  ran_on_days=%d" % [f, float(node_sum[f]) / float(cdays), int(node_days[f])])
	print("  pass_key embed frequency over %d days:" % DAYS)
	for k in pass_key_days.keys():
		print("    %-32s %d/%d days" % [str(k), int(pass_key_days[k]), DAYS])

	# --- Isolate GDScript bundle-build cost (prime suspect for the ~5ms gap) ---
	print("")
	print("=== isolated _build_native_daily_bundle timing (20 reps) ===")
	var ctx := SusTickContext.make(40, 40, 0.25, 1.0, &"perf_probe")
	# Warm once.
	generator._build_native_daily_bundle(ctx, map, world, false, 30.0, true, true)
	var reps: int = 20
	var full_t0: int = Time.get_ticks_usec()
	for i in range(reps):
		generator._build_native_daily_bundle(ctx, map, world, false, 30.0, true, true)
	var full_ms: float = float(Time.get_ticks_usec() - full_t0) / 1000.0 / float(reps)
	print("  FULL bundle (force_weather=true): %.3f ms/build" % full_ms)
	var noweather_t0: int = Time.get_ticks_usec()
	for i in range(reps):
		generator._build_native_daily_bundle(ctx, map, world, false, 30.0, true, false)
	var noweather_ms: float = float(Time.get_ticks_usec() - noweather_t0) / 1000.0 / float(reps)
	print("  bundle WITHOUT forced weather: %.3f ms/build (delta=%.3f = weather knob build)" % [noweather_ms, full_ms - noweather_ms])

	# Isolate individual knob builders if reachable.
	var cp_now = generator.climate_profile
	_time_builder("climate_pass_a_struct", generator, "_build_native_daily_climate_pass_a_struct", [map, cp_now, ctx.season_phase])
	_time_builder("climate_pass_b_knobs", generator, "_build_native_daily_climate_pass_b_knobs", [map, cp_now, ctx.season_phase])
	_time_builder("ocean_knobs", generator, "_build_native_daily_ocean_knobs", [map, cp_now, ctx.season_phase])
	_time_builder("wind_knobs", generator, "_build_native_daily_wind_knobs", [map, cp_now])
	_time_builder("transpiration_knobs", generator, "_build_native_daily_transpiration_knobs", [map, cp_now])
	_time_builder("runtime_hydrology_knobs", generator, "_build_native_daily_runtime_hydrology_knobs", [map, cp_now])
	print("=== done ===")


func _time_builder(label: String, gen, method: String, args: Array) -> void:
	if not gen.has_method(method):
		print("    %-26s [no method]" % label)
		return
	gen.callv(method, args)
	var reps: int = 30
	var t0: int = Time.get_ticks_usec()
	for i in range(reps):
		gen.callv(method, args)
	var ms: float = float(Time.get_ticks_usec() - t0) / 1000.0 / float(reps)
	print("    %-26s %.3f ms/build" % [label, ms])


func _make_profile() -> ClimateProfile:
	var loaded := ResourceLoader.load("res://data/world/earth_like.tres", "Resource") as ClimateProfile
	var profile: ClimateProfile = loaded.duplicate(true) if loaded != null else ClimateProfile.new()
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_shadow_diff_enabled = false
	profile.native_climate_round_active_owner_enabled = true
	profile.native_weather_transaction_active_owner_enabled = true
	profile.native_ocean_physical_active_owner_enabled = true
	profile.weather_field_enabled = true
	# Keep runtime_hydrology_enabled / native_daily_perf_target_ms / stagger
	# settings exactly as earth_like.tres ships them.
	profile.dynamic_visual_atlas_upload_stride = 8
	profile.enum_atlas_upload_stride = 8
	# Force atomic one-tick round so per-day sus_tick_daily completes the round and the
	# round_* cumulative breakdown fields are clean (earth_like.tres now ships spread on).
	profile.native_daily_spread_across_ticks = false
	return profile
