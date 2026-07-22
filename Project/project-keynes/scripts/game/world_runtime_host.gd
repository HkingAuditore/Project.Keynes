extends Node
class_name WorldRuntimeHost

signal world_generation_started()
signal world_generation_failed(reason: String)
signal world_ready(map: MapData, world_data: WorldData, generator: MapGenerator, view_adapter: DCViewAdapter)
signal daily_tick_completed(report: Dictionary)
signal generation_progress(stage: String, fraction: float)

const WORLD_SETUP_META := &"world_setup_config"
const DEFAULT_CLIMATE_PROFILE_PATH := "res://data/world/earth_like.tres"
const MOBILE_NATIVE_DAILY_STRIDE_DAYS: int = 20
const MOBILE_NATIVE_DAILY_COMMIT_BUDGET_DAYS: int = 20
const MOBILE_NATURAL_RESOURCE_STRIDE_DAYS: int = 10
const MOBILE_DYNAMIC_VISUAL_ATLAS_STRIDE: int = 8
const MOBILE_WEATHER_FIELD_ADVECT_STEPS: int = 2

@export var map_width: int = 60
@export var map_height: int = 40
@export var num_continents: int = 2
@export var continent_size: float = 0.9
@export var sea_level: float = 0.42
@export var river_count: int = 8
@export var hex_size: float = 22.0
@export var initial_seed: int = 0
@export var generate_test_economy_data: bool = false

@export var cell_indirection_enabled: bool = true
@export var ocean_current_visual_enabled: bool = false
@export var sea_ice_atlas_enabled: bool = false
@export var mobile_terrain_horizon_enabled: bool = false

# 动态永昼：直射点经度驱动方位，直射点纬度驱动光线高度。
@export_range(-180.0, 180.0, 1.0) var eternal_day_azimuth_offset_deg: float = -90.0
@export_range(8.0, 85.0, 1.0) var eternal_day_base_elevation_deg: float = 30.0
@export_range(0.0, 30.0, 1.0) var eternal_day_seasonal_drop_deg: float = 10.0

var _renderer: HexRenderer = null
var _camera: MapCamera = null
var _world_clock: WorldClock = null
var _current_map: MapData = null
var _world_data: WorldData = null
var _generator: MapGenerator = null
var _view_adapter: DCViewAdapter = null
var _selected_cell: HexCell = null
var _tod_profile: TODProfile = null
var day_night_enabled: bool = true
var _last_seed: int = 0
var _last_tick_report: Dictionary = {}
var _fast_tick_count: int = 0
var _last_fast_tick_ms: int = 0
var _last_tick_timing: Dictionary = {}
var _last_recorder_perf_summary: Dictionary = {}
var _last_ui_perf_summary: Dictionary = {}
var _perf_recorder: RefCounted = null
var _tile_data_recorder: RefCounted = null
var _economy_data_recorder: RefCounted = null
var _pending_tick_start_usec: int = 0
var _pending_tick_sus_ms: float = 0.0
var _pending_tick_render_ms: float = 0.0
var _pending_tick_skipped_day: bool = false


func configure(renderer: HexRenderer, camera: MapCamera, world_clock: WorldClock) -> void:
	_renderer = renderer
	_camera = camera
	_world_clock = world_clock
	_init_tod_profile()


func current_map() -> MapData:
	return _current_map


func set_selected_cell(cell: HexCell) -> void:
	_selected_cell = cell


func get_selected_cell() -> HexCell:
	return _selected_cell


func world_data() -> WorldData:
	return _world_data


func generator() -> MapGenerator:
	return _generator


func view_adapter() -> DCViewAdapter:
	return _view_adapter


func last_seed() -> int:
	return _last_seed


func last_tick_report() -> Dictionary:
	return _last_tick_report.duplicate()


func set_day_night_enabled(enabled: bool) -> void:
	day_night_enabled = enabled
	if _renderer != null:
		_renderer.set_day_night_enabled(enabled)
	if _tod_profile == null or _renderer == null:
		return
	var phase := _world_clock.visual_day_phase if _world_clock != null else 0.25
	_tod_profile.recompute(phase, enabled)
	if not enabled:
		_tod_profile.sun_dir = _dynamic_eternal_day_direction(phase)
	if _renderer.has_method("apply_tod"):
		_renderer.apply_tod(_tod_profile)


func is_day_night_enabled() -> bool:
	return day_night_enabled


func generate_world(seed_override: int = -1, safe_area: Rect2 = Rect2()) -> void:
	_selected_cell = null
	world_generation_started.emit()
	if _generator != null and _generator.has_method("sus_reset_all"):
		_generator.sus_reset_all()

	_apply_world_setup_base_config()
	_apply_feature_flags()

	var cfg := MapConfig.make(map_width, map_height)
	cfg.num_continents = num_continents
	cfg.continent_size = continent_size
	cfg.sea_level = sea_level
	cfg.river_count = river_count
	cfg.seed = seed_override if seed_override >= 0 else initial_seed

	_generator = MapGenerator.new()
	_generator.set_test_economy_bootstrap_enabled(generate_test_economy_data)
	_apply_runtime_climate_profile(_generator)
	if _world_clock != null:
		_generator.set_world_clock_ref(_world_clock)
	if _generator.has_signal("bake_progress") and not _generator.bake_progress.is_connected(_on_baker_stage_progress):
		_generator.bake_progress.connect(_on_baker_stage_progress)

	var result := _generator.generate(cfg, hex_size)
	if result.is_empty() or not result.has("map") or not result.has("world_data"):
		_current_map = null
		_world_data = null
		_view_adapter = null
		world_generation_failed.emit("map_generator_failed")
		return

	_current_map = result["map"] as MapData
	_world_data = result["world_data"] as WorldData
	_last_seed = int(result.get("seed", cfg.seed))
	_fast_tick_count = 0
	_last_fast_tick_ms = 0
	_last_tick_timing.clear()
	_last_recorder_perf_summary.clear()
	_last_ui_perf_summary.clear()
	_pending_tick_start_usec = 0
	if _world_clock != null:
		_generator.set_world_clock_ref(_world_clock)
	_rebuild_view_adapter()
	_bind_renderer_and_camera(safe_area)
	world_ready.emit(_current_map, _world_data, _generator, _view_adapter)


func run_daily_tick(day_idx: int, season_phase: float) -> Dictionary:
	if _generator == null or _world_clock == null:
		return {}
	_pending_tick_start_usec = Time.get_ticks_usec()
	if _renderer != null:
		_renderer.set_season_phase(season_phase)
		_renderer.set_climate_anomaly(_world_clock.climate_anomaly)
	if _generator.has_method("set_current_fast_tick_idx"):
		_generator.set_current_fast_tick_idx(_fast_tick_count + 1)

	var t_sus_usec := Time.get_ticks_usec()
	var report: Dictionary = _generator.sus_tick_daily(_world_clock, day_idx, season_phase)
	_pending_tick_sus_ms = (Time.get_ticks_usec() - t_sus_usec) / 1000.0
	_fast_tick_count += 1
	if _renderer != null and _generator.has_method("has_pending_detail_scatter_refresh") \
			and bool(_generator.has_pending_detail_scatter_refresh()) \
			and _renderer.has_method("queue_detail_scatter_refresh"):
		_renderer.queue_detail_scatter_refresh(_generator.consume_pending_detail_scatter_refresh_indices())
	var t_render_usec := Time.get_ticks_usec()
	if _renderer != null:
		if _renderer.has_method("set_weather_field_texture") and _world_data != null:
			_renderer.set_weather_field_texture(null)
		if _renderer.has_method("refresh_terrain_weather_field_tex"):
			_renderer.refresh_terrain_weather_field_tex()
		if bool(report.get("fronts_changed", false)) and _renderer.has_method("set_weather_fronts"):
			_renderer.set_weather_fronts(report.get("fronts", []))
	_pending_tick_render_ms = (Time.get_ticks_usec() - t_render_usec) / 1000.0
	# 玩家场景每次 day_changed 都真实执行一次 SUS；weather 自身的 stride/policy
	# 不能把同日 climate/economy job 误标成“整日未刷新”。
	_pending_tick_skipped_day = false
	_last_tick_report = report.duplicate()
	daily_tick_completed.emit(_last_tick_report)
	return _last_tick_report


func finish_daily_tick(ui_ms: float, ui_breakdown: Dictionary = {}) -> void:
	if _pending_tick_start_usec <= 0:
		return
	_last_ui_perf_summary = ui_breakdown.duplicate(false)
	_last_ui_perf_summary["_tick_idx"] = _fast_tick_count
	var fast_ms_before_recorders := (
		Time.get_ticks_usec() - _pending_tick_start_usec) / 1000.0
	var recorder_diag := _publish_fast_tick_perf_sample(
		_pending_tick_sus_ms,
		_pending_tick_render_ms,
		maxf(ui_ms, 0.0),
		fast_ms_before_recorders,
		_pending_tick_skipped_day
	)
	var fast_ms_after_recorders := (
		Time.get_ticks_usec() - _pending_tick_start_usec) / 1000.0
	_last_fast_tick_ms = int(round(fast_ms_after_recorders))
	_last_tick_timing = {
		"tick_idx": _fast_tick_count,
		"fast_ms": fast_ms_after_recorders,
		"fast_ms_before_recorders": fast_ms_before_recorders,
		"t_sus_ms": _pending_tick_sus_ms,
		"t_render_ms": _pending_tick_render_ms,
		"t_ui_ms": maxf(ui_ms, 0.0),
		"was_skipped_day": _pending_tick_skipped_day,
	}
	if recorder_diag.is_empty():
		_last_recorder_perf_summary.clear()
	else:
		recorder_diag["fast_ms_before_recorders"] = fast_ms_before_recorders
		recorder_diag["fast_ms_after_recorders"] = fast_ms_after_recorders
		_last_recorder_perf_summary = recorder_diag
	_pending_tick_start_usec = 0


func get_current_map() -> MapData:
	return _current_map


func get_world_clock_ref() -> WorldClock:
	return _world_clock


func get_generator() -> MapGenerator:
	return _generator


func get_renderer() -> HexRenderer:
	return _renderer


func get_fast_tick_count() -> int:
	return _fast_tick_count


func get_last_fast_tick_ms() -> int:
	return _last_fast_tick_ms


func get_last_tick_timing() -> Dictionary:
	return _last_tick_timing.duplicate(false)


func get_sus_last_tick_report() -> Dictionary:
	if _generator == null or not _generator.has_method("sus_report_last_tick"):
		return {}
	var report: Dictionary = _generator.sus_report_last_tick()
	return report.duplicate(false)


func get_sus_last_tick_summary() -> Dictionary:
	if _generator == null or not _generator.has_method("sus_report_last_tick_summary"):
		return {}
	var summary: Dictionary = _generator.sus_report_last_tick_summary()
	return summary.duplicate(false)


func get_sim_breakdowns() -> Dictionary:
	var out: Dictionary = {}
	if _generator == null:
		return out
	if not _last_ui_perf_summary.is_empty():
		out["ui"] = _last_ui_perf_summary.duplicate(false)
	if _generator.has_method("sus_climate_breakdown"):
		out["climate"] = _generator.sus_climate_breakdown()
	if _generator.has_method("sus_weather_breakdown"):
		out["weather"] = _generator.sus_weather_breakdown()
	if _generator.has_method("sus_enum_atlas_breakdown"):
		out["enum_atlas"] = _generator.sus_enum_atlas_breakdown()
	if _generator.has_method("sus_sea_ice_atlas_breakdown"):
		out["sea_ice_atlas"] = _generator.sus_sea_ice_atlas_breakdown()
	if _generator.has_method("sus_dynamic_visual_atlas_breakdown"):
		out["dynamic_visual_atlas"] = _generator.sus_dynamic_visual_atlas_breakdown()
	var tick_report := get_sus_last_tick_report()
	var economy_job = tick_report.get("economy_daily", {})
	if economy_job is Dictionary \
			and str((economy_job as Dictionary).get("skipped_reason", "")) == "" \
			and _generator.has_method("get_economy_report"):
		var economy: Dictionary = _generator.get_economy_report()
		if not economy.is_empty():
			economy["_tick_idx"] = _fast_tick_count
			out["economy"] = economy
	return out.duplicate(false)


func get_environment_perf_summary() -> Dictionary:
	var summary := get_sus_last_tick_summary()
	var out: Dictionary = {
		"tick_idx": _fast_tick_count,
		"fast_ms": _last_fast_tick_ms,
		"map_cells": _current_map.cell_count() if _current_map != null else 0,
		"last_tick": summary,
		"timing": _last_tick_timing.duplicate(false),
		"window": {},
		"recorders": _last_recorder_perf_summary.duplicate(false),
	}
	if _generator != null and _generator.has_method("sus_report_sim_budget_window"):
		out["window"] = _generator.sus_report_sim_budget_window()
	return out


func get_recorder_perf_summary() -> Dictionary:
	return _last_recorder_perf_summary.duplicate(false)


func set_perf_recorder(recorder: RefCounted) -> void:
	_perf_recorder = recorder


func get_perf_recorder() -> RefCounted:
	return _perf_recorder


func set_tile_data_recorder(recorder: RefCounted) -> void:
	_tile_data_recorder = recorder


func get_tile_data_recorder() -> RefCounted:
	return _tile_data_recorder


func set_economy_data_recorder(recorder: RefCounted) -> void:
	_economy_data_recorder = recorder


func get_economy_data_recorder() -> RefCounted:
	return _economy_data_recorder


func _publish_fast_tick_perf_sample(
		t_sus_ms: float,
		t_render_ms: float,
		t_ui_ms: float,
		fast_ms: float,
		was_skipped_day: bool
) -> Dictionary:
	var perf_ready := _recorder_ready(_perf_recorder)
	var tile_ready := _recorder_ready(_tile_data_recorder)
	var economy_ready := _recorder_ready(_economy_data_recorder)
	if not perf_ready and not tile_ready and not economy_ready:
		return {}
	var started_usec := Time.get_ticks_usec()
	var out: Dictionary = {
		"total_ms": 0.0,
		"perf_ms": 0.0,
		"tile_ms": 0.0,
		"economy_ms": 0.0,
		"perf_recording": perf_ready,
		"tile_recording": tile_ready,
		"economy_recording": economy_ready,
		"tile_recorded": false,
		"tile_rows": 0,
		"tile_reason": "",
		"economy_recorded": false,
		"economy_rows": 0,
		"economy_reason": "",
	}
	var sample: Dictionary = {
		"tick_idx": _fast_tick_count,
		"timestamp_ms": Time.get_ticks_msec(),
		"was_skipped_day": was_skipped_day,
		"fps": Engine.get_frames_per_second(),
		"fast_ms": fast_ms,
		"t_sus_ms": t_sus_ms,
		"t_render_ms": t_render_ms,
		"t_ui_ms": t_ui_ms,
	}
	if _generator != null and _generator.has_method("sus_climate_breakdown"):
		var climate_diag: Dictionary = _generator.sus_climate_breakdown()
		if not climate_diag.is_empty():
			sample["climate"] = climate_diag
	if _generator != null and _generator.has_method("sus_weather_breakdown"):
		var weather_diag: Dictionary = _generator.sus_weather_breakdown()
		if not weather_diag.is_empty():
			sample["weather"] = weather_diag
	if _generator != null and _generator.has_method("sus_ocean_currents_breakdown"):
		var ocean_diag: Dictionary = _generator.sus_ocean_currents_breakdown()
		if not ocean_diag.is_empty():
			sample["ocean_currents"] = ocean_diag
	if perf_ready:
		var perf_started_usec := Time.get_ticks_usec()
		_perf_recorder.call("on_fast_tick", sample)
		out["perf_ms"] = (Time.get_ticks_usec() - perf_started_usec) / 1000.0
	if tile_ready:
		var tile_started_usec := Time.get_ticks_usec()
		var tile_result = _tile_data_recorder.call("on_fast_tick", sample)
		out["tile_ms"] = (Time.get_ticks_usec() - tile_started_usec) / 1000.0
		if tile_result is Dictionary:
			var tile_dict := tile_result as Dictionary
			out["tile_recorded"] = bool(tile_dict.get("recorded", false))
			out["tile_rows"] = int(tile_dict.get("rows", 0))
			out["tile_reason"] = str(tile_dict.get("reason", ""))
			for key in [
				"collect_ms", "stats_ms", "format_ms", "flush_ms", "encoder_path",
				"tick_stride", "cell_stride",
			]:
				if tile_dict.has(key):
					out["tile_%s" % str(key)] = tile_dict[key]
	if economy_ready:
		var economy_started_usec := Time.get_ticks_usec()
		var economy_result = _economy_data_recorder.call("on_fast_tick", sample)
		out["economy_ms"] = (Time.get_ticks_usec() - economy_started_usec) / 1000.0
		if economy_result is Dictionary:
			var economy_dict := economy_result as Dictionary
			out["economy_recorded"] = bool(economy_dict.get("recorded", false))
			out["economy_rows"] = int(economy_dict.get("rows", 0))
			out["economy_reason"] = str(economy_dict.get("reason", ""))
			out["economy_epoch_id"] = int(economy_dict.get("epoch_id", -1))
	out["total_ms"] = (Time.get_ticks_usec() - started_usec) / 1000.0
	return out


func _recorder_ready(recorder: RefCounted) -> bool:
	if recorder == null or not recorder.has_method("on_fast_tick"):
		return false
	if recorder.has_method("is_recording") and not bool(recorder.call("is_recording")):
		return false
	return true


func on_speed_changed(new_speed: float) -> void:
	if _renderer != null:
		var weather_layer := _renderer.get_node_or_null("WeatherLayer")
		if weather_layer != null and weather_layer.has_method("set_clock_speed_multiplier"):
			weather_layer.set_clock_speed_multiplier(new_speed)
		if weather_layer != null and weather_layer.has_method("reset_snapshot_pacing"):
			weather_layer.reset_snapshot_pacing()
	if _generator == null:
		return
	var cp = _generator._c() if _generator.has_method("_c") else null
	var auto_weather_stride := true
	if cp != null and cp.get("weather_refresh_auto_stride_by_speed") != null:
		auto_weather_stride = bool(cp.weather_refresh_auto_stride_by_speed)
	if not auto_weather_stride:
		return
	var stride := 1
	if new_speed >= 15.0:
		stride = 8
	elif new_speed >= 3.0:
		stride = 4
	_generator.set_weather_refresh_stride(stride)


func on_visual_day_phase_changed(visual_day_phase: float) -> void:
	if _renderer == null:
		return
	_renderer.set_day_phase(visual_day_phase)
	if _tod_profile != null and _renderer.has_method("apply_tod"):
		_tod_profile.recompute(visual_day_phase, day_night_enabled)
		if not day_night_enabled:
			_tod_profile.sun_dir = _dynamic_eternal_day_direction(visual_day_phase)
		_renderer.apply_tod(_tod_profile)


func _dynamic_eternal_day_direction(visual_day_phase: float) -> Vector3:
	var tilt_rad := deg_to_rad(_renderer.axial_tilt_deg) if _renderer != null else 0.4101523
	var season_phase := _world_clock.season_phase() if _world_clock != null else 1.0
	var subsolar_uv := Vector2(fposmod(visual_day_phase, 1.0), 0.5)
	if _renderer != null:
		subsolar_uv = _renderer.effective_tod_subsolar_uv(visual_day_phase, season_phase)
	else:
		var year_progress := fposmod(season_phase, 4.0) * 0.25
		var fallback_declination := tilt_rad * cos(TAU * year_progress)
		subsolar_uv.y = clampf(0.5 + fallback_declination / PI, 0.0, 1.0)
	var declination := (subsolar_uv.y - 0.5) * PI
	var latitude_ratio := clampf(absf(declination) / maxf(tilt_rad, 0.0001), 0.0, 1.0)
	var elevation_deg := eternal_day_base_elevation_deg \
		- eternal_day_seasonal_drop_deg * latitude_ratio
	var elevation := deg_to_rad(clampf(elevation_deg, 8.0, 85.0))
	var azimuth := TAU * subsolar_uv.x \
		+ deg_to_rad(eternal_day_azimuth_offset_deg)
	var horizontal := cos(elevation)
	return Vector3(
		cos(azimuth) * horizontal,
		sin(azimuth) * horizontal,
		sin(elevation)
	).normalized()


func on_season_changed(season_idx: int) -> void:
	if _generator == null or _current_map == null or _world_data == null:
		return
	if _renderer != null and _renderer.has_method("begin_season_transition") and _world_clock != null:
		_renderer.begin_season_transition(_world_clock.season_phase())
	var cp = _generator._c() if _generator.has_method("_c") else null
	var use_legacy := false
	if cp != null and "season_refresh_legacy_signal" in cp:
		use_legacy = bool(cp.season_refresh_legacy_signal)
	if not use_legacy:
		return
	if _generator.has_method("queue_season_refresh"):
		_generator.queue_season_refresh(season_idx)
	else:
		_generator.refresh_seasonal(_current_map, _world_data, season_idx)


func on_year_changed(_year_idx: int) -> void:
	if _generator != null and _current_map != null and _world_data != null:
		_generator.refresh_yearly(_current_map, _world_data)


func fit_camera(safe_area: Rect2 = Rect2()) -> void:
	if _camera != null:
		_camera.fit_to_viewport(1.05, safe_area)


func map_wrap_period_x() -> float:
	if _current_map == null:
		return 0.0
	return HexUtils.wrap_period_x(_current_map.width, hex_size)


func _bind_renderer_and_camera(safe_area: Rect2) -> void:
	if _renderer == null or _current_map == null or _world_data == null:
		return
	_renderer.hex_size = hex_size
	var ext = _generator.get_data_core_world_ext() if _generator != null and _generator.has_method("get_data_core_world_ext") else null
	if ext != null and _renderer.has_method("set_world_ext"):
		_renderer.set_world_ext(ext)
	_renderer.set_map(_current_map, _world_data)
	if _renderer.has_method("set_map_baker") and _generator != null and "_baker" in _generator:
		_renderer.set_map_baker(_generator._baker)
	if _world_clock != null:
		_renderer.set_season_phase(_world_clock.season_phase())
		_renderer.set_climate_anomaly(_world_clock.climate_anomaly)
		on_visual_day_phase_changed(_world_clock.visual_day_phase)
		var cp = _generator._c() if _generator != null and _generator.has_method("_c") else null
		if cp != null and cp.daily_climate_interpolation:
			_generator.refresh_climate_daily(_current_map, _world_clock.season_phase())
	if _camera != null:
		_camera.set_world_bounds(_renderer.get_world_bounds())
		if _camera.has_method("set_horizontal_wrap"):
			_camera.set_horizontal_wrap(map_wrap_period_x(), true)
		_camera.fit_to_viewport(1.05, safe_area)


func _rebuild_view_adapter() -> void:
	if _current_map == null:
		_view_adapter = null
		return
	var cp = _generator._c() if _generator != null and _generator.has_method("_c") else null
	if cp != null and DCFeatureFlags.is_on(&"use_world_view_adapter", cp):
		var dc_world = _generator.get_data_core_world() if _generator != null and _generator.has_method("get_data_core_world") else null
		if dc_world != null and dc_world.has_method("is_bound") and dc_world.is_bound():
			_view_adapter = DCViewAdapter.World.new(dc_world, _current_map)
			return
	_view_adapter = DCViewAdapter.Cell.new(_current_map.iter_cells())


func _apply_feature_flags() -> void:
	DCFeatureFlags.set_cell_indirection(cell_indirection_enabled)
	DCFeatureFlags.set_ocean_current_visual(ocean_current_visual_enabled)
	DCFeatureFlags.set_sea_ice_atlas(sea_ice_atlas_enabled)
	DCFeatureFlags.set_terrain_horizon_gpu_bake(
		mobile_terrain_horizon_enabled if OS.has_feature("mobile") else true
	)


func _world_setup_config() -> Dictionary:
	if not Engine.has_meta(WORLD_SETUP_META):
		return {}
	var raw = Engine.get_meta(WORLD_SETUP_META)
	if raw is Dictionary and String((raw as Dictionary).get("source", "")) == "world_setup":
		return raw as Dictionary
	return {}


func _apply_world_setup_base_config() -> void:
	var config := _world_setup_config()
	if config.is_empty():
		return
	var base = config.get("base", {})
	if base is Dictionary:
		map_width = clampi(int((base as Dictionary).get("map_width", map_width)), 10, 500)
		map_height = clampi(int((base as Dictionary).get("map_height", map_height)), 8, 400)
		initial_seed = max(0, int((base as Dictionary).get("initial_seed", initial_seed)))
		sea_level = clampf(float((base as Dictionary).get("sea_level", sea_level)), 0.1, 0.8)
		num_continents = clampi(int((base as Dictionary).get("num_continents", num_continents)), 1, 8)
		continent_size = clampf(float((base as Dictionary).get("continent_size", continent_size)), 0.2, 0.9)
		river_count = clampi(int((base as Dictionary).get("river_count", river_count)), 0, 30)
		generate_test_economy_data = bool((base as Dictionary).get(
			"generate_test_economy_data", generate_test_economy_data))
	var render = config.get("render", {})
	if render is Dictionary:
		mobile_terrain_horizon_enabled = bool((render as Dictionary).get(
			"mobile_terrain_horizon_enabled", mobile_terrain_horizon_enabled
		))


func _load_runtime_climate_profile() -> ClimateProfile:
	var profile := ResourceLoader.load(DEFAULT_CLIMATE_PROFILE_PATH, "Resource") as ClimateProfile
	if profile != null:
		profile = profile.duplicate(true) as ClimateProfile
	else:
		push_warning("[PlayerGame] default ClimateProfile missing; using in-memory defaults.")
		profile = ClimateProfile.new()
	profile.set_meta(&"source_path", DEFAULT_CLIMATE_PROFILE_PATH)
	return profile


func _apply_runtime_climate_profile(generator_ref: MapGenerator) -> void:
	if generator_ref == null:
		return
	var profile := _load_runtime_climate_profile()
	var config := _world_setup_config()
	var climate_overrides: Dictionary = {}
	if not config.is_empty():
		var climate = config.get("climate", {})
		if climate is Dictionary:
			var profile_props := {}
			for prop in profile.get_property_list():
				profile_props[String(prop.get("name", ""))] = true
			for name in (climate as Dictionary).keys():
				var key := String(name)
				if not profile_props.has(key):
					continue
				profile.set(key, (climate as Dictionary)[name])
				climate_overrides[key] = true
	if OS.has_feature("mobile"):
		_apply_mobile_profile_defaults(profile, climate_overrides)
	generator_ref.climate_profile = profile


func _apply_mobile_profile_defaults(profile: ClimateProfile, climate_overrides: Dictionary) -> void:
	if profile.get("native_daily_sim_stride") != null and not climate_overrides.has("native_daily_sim_stride"):
		profile.native_daily_sim_stride = MOBILE_NATIVE_DAILY_STRIDE_DAYS
	if profile.get("native_daily_commit_lag_budget_days") != null and not climate_overrides.has("native_daily_commit_lag_budget_days"):
		profile.native_daily_commit_lag_budget_days = MOBILE_NATIVE_DAILY_COMMIT_BUDGET_DAYS
	if profile.get("native_daily_sea_ice_spread_dt_cap_days") != null and not climate_overrides.has("native_daily_sea_ice_spread_dt_cap_days"):
		profile.native_daily_sea_ice_spread_dt_cap_days = float(MOBILE_NATIVE_DAILY_STRIDE_DAYS)
	if profile.get("natural_resource_daily_stride") != null and not climate_overrides.has("natural_resource_daily_stride"):
		profile.natural_resource_daily_stride = maxi(int(profile.natural_resource_daily_stride), MOBILE_NATURAL_RESOURCE_STRIDE_DAYS)
	if profile.get("dynamic_visual_atlas_upload_stride") != null and not climate_overrides.has("dynamic_visual_atlas_upload_stride"):
		profile.dynamic_visual_atlas_upload_stride = maxi(int(profile.dynamic_visual_atlas_upload_stride), MOBILE_DYNAMIC_VISUAL_ATLAS_STRIDE)
	if profile.get("weather_field_advect_steps") != null and not climate_overrides.has("weather_field_advect_steps"):
		profile.weather_field_advect_steps = mini(int(profile.weather_field_advect_steps), MOBILE_WEATHER_FIELD_ADVECT_STEPS)


func _init_tod_profile() -> void:
	if _tod_profile != null:
		return
	_tod_profile = TODProfile.new()
	_tod_profile.configure(0.65, 0.55, 0.72, 1.0)


func _on_baker_stage_progress(stage: String, fraction: float) -> void:
	generation_progress.emit(stage, fraction)
