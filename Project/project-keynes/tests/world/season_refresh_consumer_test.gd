extends SceneTree

const Coordinator = preload("res://scripts/simulation/climate/season_refresh_coordinator.gd")
const Capture = preload("res://scripts/simulation/climate/runtime_climate_capture.gd")
var checks := 0
var failures := 0

# Only the expensive seasonal math is replaced. Date publication and the
# stage-B consumer are the actual production collaborators, with WorldClock.
class Generator extends MapGenerator:
	var profile := ClimateProfile.new()
	var remaining := 0
	var starts := 0
	func _c() -> ClimateProfile: return profile
	func season_refresh_defers_to_capture() -> bool: return true
	func begin_periodic_season_refresh() -> int:
		starts += 1
		return 0
	func season_round_b_plus_available() -> bool: return false
	func run_season_refresh_stage_micro(_m, _w, _s, _stage, cursor) -> Dictionary:
		if remaining > 0:
			remaining -= 1
			return {"handled": true, "done": false, "cursor": cursor + 1}
		return {"handled": true, "done": true}
	func finish_season_refresh(_m, _w, season) -> void:
		var coordinator := Coordinator.new()
		coordinator._generator = self
		coordinator.finish_season_refresh(null, null, season)

func _init() -> void:
	_test_published_season_history_lookup()
	var map := MapData.new(1, 1)
	map.set_cell(HexCell.new())
	var generator := Generator.new()
	var clock := WorldClock.new()
	generator._world_clock_ref = clock
	generator.profile.weather_vegetation_dynamics_stride = 1
	generator.profile.weather_albedo_stride = 1
	generator.profile.fast_slow_layering_enabled = false
	generator.profile.sim_stagger_enabled = false
	var capture := Capture.new()
	capture._generator = generator
	var system := SeasonRefreshSystem.new(generator, map, WorldData.new())
	clock.current_day = 32
	# The real day_changed caller captures clock day - 1.
	system.run_due_round_for_capture(clock.day_index() - 1)
	_expect("coordinator and capture use the same clock-date convention",
		generator._last_season_refresh_day == clock.day_index())
	var builder = generator._get_native_daily_bundle_builder()
	var synchronous: Dictionary = builder._build_native_daily_stage_b_knobs(map, generator.profile, 0)
	_expect("same-day synchronous vegetation is suppressed", not synchronous.get("run_veg_dyn", true))
	# Prefetch may prepare an input while the visible clock has another date.
	for visible_day in [31, 32, 33]:
		clock.current_day = visible_day
		generator._runtime_climate_worker_weather_embed_day = -1000000
		var knobs: Dictionary = capture._build_runtime_climate_stage_knobs(map, 31, true)
		_expect("input day 31 never repeats vegetation at visible day %d" % visible_day,
			not knobs.get("stage_b", {}).get("run_veg_dyn", true))
	generator._runtime_climate_worker_weather_embed_day = -1000000
	var following: Dictionary = capture._build_runtime_climate_stage_knobs(map, 32, true)
	_expect("next input day may run vegetation", following.get("stage_b", {}).get("run_veg_dyn", false))
	# A finite round spanning the existing 4096-slice guard continues the SAME
	# input day, retaining its completion date despite a different visible clock.
	clock.current_day = 60
	generator.remaining = 4100
	system.run_due_round_for_capture(61)
	_expect("unfinished round stays active", system._round_active)
	_expect("unfinished round does not publish a completion date", generator._last_season_refresh_day == 32)
	system.run_due_round_for_capture(61)
	_expect("next attempt completes the same round", not system._round_active)
	_expect("continued round records its input date", generator._last_season_refresh_day == 62)
	var starts := generator.starts
	system.run_due_round_for_capture(61)
	_expect("completed continuation is not restarted", generator.starts == starts)
	clock.free()
	print("season refresh consumer: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_published_season_history_lookup() -> void:
	var map := MapData.new(1, 1)
	var cell := HexCell.new()
	cell.index = 1
	cell.biome_history = PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	cell.vegetation_history = PackedByteArray([11, 12, 13, 14, 15, 16, 17, 18])
	map.set_cell(cell)
	map.published_biome_history = PackedByteArray([21, 22, 23, 24, 25, 26, 27, 28])
	map.published_vegetation_history = PackedByteArray([31, 32, 33, 34, 35, 36, 37, 38])
	_expect("missing published biome history does not read cell mirror",
		map.season_history_for(cell, false).is_empty())
	_expect("missing published vegetation history does not read cell mirror",
		map.season_history_for(cell, true).is_empty())
	map.published_biome_history.append_array(PackedByteArray([41, 42, 43, 44, 45, 46, 47, 48]))
	map.published_vegetation_history.append_array(PackedByteArray([51, 52, 53, 54, 55, 56, 57, 58]))
	_expect("published biome history returns the requested cell slice",
		map.season_history_for(cell, false) == PackedByteArray([41, 42, 43, 44, 45, 46, 47, 48]))
	_expect("published vegetation history returns the requested cell slice",
		map.season_history_for(cell, true) == PackedByteArray([51, 52, 53, 54, 55, 56, 57, 58]))

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", label)
