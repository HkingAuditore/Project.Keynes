extends Node
class_name WorldRuntimeHost

signal world_generation_started()
signal world_generation_failed(reason: String)
signal world_ready(map: MapData, world_data: WorldData, generator: MapGenerator, view_adapter: DCViewAdapter)
signal daily_tick_completed(report: Dictionary)
signal generation_progress(stage: String, fraction: float)
signal gm_toggle_changed(toggle_id: String, enabled: bool)
signal gm_action_completed(action_id: String, result: Dictionary)

const WORLD_SETUP_META := &"world_setup_config"
const DEFAULT_CLIMATE_PROFILE_PATH := "res://data/world/earth_like.tres"
const MOBILE_NATIVE_DAILY_STRIDE_DAYS: int = 20
const MOBILE_NATIVE_DAILY_COMMIT_BUDGET_DAYS: int = 20
const MOBILE_NATURAL_RESOURCE_STRIDE_DAYS: int = 10
const MOBILE_DYNAMIC_VISUAL_ATLAS_STRIDE: int = 8
const MOBILE_WEATHER_FIELD_ADVECT_STEPS: int = 2
const MAP_OVERLAY_REFRESH_INTERVAL_MSEC: int = 100

@export var map_width: int = 60
@export var map_height: int = 40
@export var num_continents: int = 2
@export var continent_size: float = 0.9
@export var sea_level: float = 0.42
@export var river_count: int = 8
@export var hex_size: float = 22.0
@export var initial_seed: int = 0
@export var generate_test_economy_data: bool = false
@export_enum("资源分层混合:0", "产能基线:1", "百人级:10", "千人级:100", "万人级:1000") \
var test_economy_population_scale: int = 0

## 视野迷雾总开关。实际生效还要求本局有 gameplay start context（正式对局），
## 调试 / 沙盒路径始终全图可见。
@export var fog_of_war_enabled: bool = true
## 主地形「完全未探索像素早退」。是可测量的性能实验，不是玩法开关：
## 净收益取决于迷雾层厚云是否真的比被跳过的地形管线便宜，须靠 headless perf
## A/B 决定。默认关。
@export var fog_early_out_enabled: bool = false

@export var cell_indirection_enabled: bool = true
@export var ocean_current_visual_enabled: bool = false
@export var sea_ice_atlas_enabled: bool = false
@export var mobile_terrain_horizon_enabled: bool = false

var _renderer: HexRenderer = null
var _camera: MapCamera = null
var _world_clock: WorldClock = null
var _map_overlay_layer: DataOverlayLayer = null
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
var _map_overlay_request: Dictionary = {}
var _map_overlay_tex: ImageTexture = null
var _map_overlay_image: Image = null
var _map_overlay_buf: PackedByteArray = PackedByteArray()
var _map_overlay_dirty: bool = false
var _map_overlay_last_refresh_msec: int = 0
var _map_overlay_refresh_count: int = 0
var _map_overlay_merged_dirty_count: int = 0
var _map_overlay_last_result: Dictionary = {}
var _fog_of_war_enabled: bool = false
var _player_country_slot: int = -1
var _player_country_handle: int = 0
var _session_request: Dictionary = {}
var _new_game_config: Dictionary = {}
var _load_slot_id: String = ""
var _pending_load_bundle: Dictionary = {}
var _gm_sequence: int = 1
var _gm_click_claim_territory_enabled: bool = false
var _gm_click_claim_pending_days: Dictionary = {}

const GM_SPEED_PRESETS: Array[float] = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0]
const GM_CASH_SCALE: int = 10000
const GM_GOODS_SCALE: int = 1000


func configure(
	renderer: HexRenderer,
	camera: MapCamera,
	world_clock: WorldClock,
	map_overlay_layer: DataOverlayLayer = null
) -> void:
	if _camera != null and _camera.zoom_changed.is_connected(_on_camera_zoom_changed):
		_camera.zoom_changed.disconnect(_on_camera_zoom_changed)
	_renderer = renderer
	_camera = camera
	_world_clock = world_clock
	_map_overlay_layer = map_overlay_layer
	if _camera != null:
		_camera.zoom_changed.connect(_on_camera_zoom_changed)
		_on_camera_zoom_changed(_camera.zoom.x)
	set_process(false)
	_init_tod_profile()


func _on_camera_zoom_changed(value: float) -> void:
	if _renderer != null:
		_renderer.set_camera_zoom(value)


func configure_session(request: Dictionary) -> Dictionary:
	_session_request = request.duplicate(true)
	_new_game_config.clear()
	_load_slot_id = ""
	_pending_load_bundle.clear()
	var kind := String(request.get("kind", ""))
	if kind == "new_game":
		var parsed := NewGameConfig.from_dictionary(request.get("config", {}))
		if not bool(parsed.get("ok", false)):
			return parsed
		_new_game_config = (parsed.config as NewGameConfig).to_dictionary()
		return {"ok": true, "code": "ok", "message": ""}
	if kind == "load_game":
		_load_slot_id = String(request.get("slot_id", ""))
		var save_service := _game_save_service()
		if save_service == null:
			return {"ok": false, "code": "game_save_unavailable", "message": "存档服务不可用。"}
		var prepared: Dictionary = save_service.prepare_load(_load_slot_id)
		if not bool(prepared.get("ok", false)):
			return prepared
		var parsed := NewGameConfig.from_dictionary(prepared.get("config", {}))
		if not bool(parsed.get("ok", false)):
			return parsed
		_new_game_config = (parsed.config as NewGameConfig).to_dictionary()
		_pending_load_bundle = prepared.get("bundle", {})
		return {"ok": true, "code": "ok", "message": ""}
	return {"ok": false, "code": "session_request_invalid", "message": "游戏会话请求无效。"}


## 用节点路径解析而非全局标识符，因为 `--script` 无头工具链不注册 autoload。
func _game_save_service() -> Node:
	return get_node_or_null(^"/root/GameSave")


func current_map() -> MapData:
	return _current_map


func set_selected_cell(cell: HexCell) -> void:
	_selected_cell = cell
	if cell != null and _gm_click_claim_territory_enabled:
		_gm_claim_selected_cell(cell)


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


func session_config() -> Dictionary:
	return _new_game_config.duplicate(true)


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
	if _renderer.has_method("apply_tod"):
		_renderer.apply_tod(_tod_profile)


func is_day_night_enabled() -> bool:
	return day_night_enabled


func generate_world(seed_override: int = -1, safe_area: Rect2 = Rect2()) -> void:
	_selected_cell = null
	clear_map_overlay()
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
	_generator.set_test_economy_population_scale(test_economy_population_scale)
	_generator.set_save_restore_preparation_enabled(not _pending_load_bundle.is_empty())
	if not _new_game_config.is_empty():
		_generator.set_gameplay_start_config(_new_game_config)
	_apply_runtime_climate_profile(_generator)
	if _world_clock != null:
		_generator.set_world_clock_ref(_world_clock)
	if _generator.has_signal("bake_progress") and not _generator.bake_progress.is_connected(_on_baker_stage_progress):
		_generator.bake_progress.connect(_on_baker_stage_progress)

	var result: Dictionary = await _generator.generate(cfg, hex_size)
	if result.is_empty() or not result.has("map") or not result.has("world_data"):
		_current_map = null
		_world_data = null
		_view_adapter = null
		world_generation_failed.emit("map_generator_failed")
		return
	if not _new_game_config.is_empty():
		var start_report: Dictionary = _generator.gameplay_start_report()
		if not bool(start_report.get("ok", false)):
			_current_map = null
			_world_data = null
			_view_adapter = null
			world_generation_failed.emit(String(start_report.get("message", "开局初始化失败。")))
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
	if not _pending_load_bundle.is_empty():
		var save_service := _game_save_service()
		var restore_result: Dictionary = save_service.restore_prepared_game(self) if save_service != null \
			else {"ok": false, "message": "存档服务不可用。"}
		if not bool(restore_result.get("ok", false)):
			push_error("[save/restore] load failed code=%s message=%s" % [
				String(restore_result.get("code", "unknown")),
				String(restore_result.get("message", "存档恢复失败。")),
			])
			world_generation_failed.emit(String(restore_result.get("message", "存档恢复失败。")))
			return
		_pending_load_bundle.clear()
	world_ready.emit(_current_map, _world_data, _generator, _view_adapter)


func is_loading_session() -> bool:
	return not _load_slot_id.is_empty()


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
	mark_map_overlay_dirty(&"authoritative_daily_flush")
	return _last_tick_report


func set_map_overlay(request: Dictionary) -> void:
	var mode := int(request.get("mode", OverlayMode.MODE.NONE))
	if mode == OverlayMode.MODE.NONE:
		clear_map_overlay()
		return
	_map_overlay_request = {
		"mode": mode,
		"resource_id": StringName(request.get("resource_id", &"")),
	}
	_map_overlay_dirty = true
	set_process(true)
	_refresh_map_overlay(true)


func clear_map_overlay() -> void:
	_map_overlay_request.clear()
	_map_overlay_dirty = false
	set_process(false)
	if _map_overlay_layer != null:
		_map_overlay_layer.hide_animated()


func mark_map_overlay_dirty(_reason: StringName = &"runtime") -> void:
	if _map_overlay_request.is_empty():
		return
	if _map_overlay_dirty:
		_map_overlay_merged_dirty_count += 1
	_map_overlay_dirty = true
	set_process(true)


func map_overlay_diagnostics() -> Dictionary:
	return {
		"active": not _map_overlay_request.is_empty(),
		"request": _map_overlay_request.duplicate(),
		"refresh_count": _map_overlay_refresh_count,
		"merged_dirty_count": _map_overlay_merged_dirty_count,
		"last_result": _map_overlay_last_result.duplicate(),
	}


func _process(_delta: float) -> void:
	if not _map_overlay_dirty or _map_overlay_request.is_empty():
		return
	_refresh_map_overlay(false)


func _refresh_map_overlay(force: bool) -> void:
	if _map_overlay_layer == null or _current_map == null or _world_data == null \
			or _view_adapter == null or _map_overlay_request.is_empty():
		return
	var now := Time.get_ticks_msec()
	if not force and now - _map_overlay_last_refresh_msec < MAP_OVERLAY_REFRESH_INTERVAL_MSEC:
		return
	var mode := int(_map_overlay_request.get("mode", OverlayMode.MODE.NONE))
	var resource_profile: ResourceProfile = null
	if mode == OverlayMode.MODE.RESOURCE_RESERVE:
		var wanted := StringName(_map_overlay_request.get("resource_id", &""))
		for profile in ResourceProfileRegistry.ordered():
			if profile != null and profile.id == wanted:
				resource_profile = profile
				break
		if resource_profile == null:
			clear_map_overlay()
			return
	var climate = _generator._c() if _generator != null and _generator.has_method("_c") else null
	var phase := _world_clock.season_phase() if _world_clock != null else 0.0
	var started := Time.get_ticks_usec()
	var result := DataOverlayBaker.bake_cell_lut(
		_current_map, _world_data, mode, climate, phase, _view_adapter,
		resource_profile, _map_overlay_tex, _map_overlay_buf, _map_overlay_image
	)
	_map_overlay_tex = result.get("texture") as ImageTexture
	_map_overlay_image = result.get("image") as Image
	_map_overlay_buf = result.get("buf", PackedByteArray())
	_map_overlay_layer.set_cell_lut_texture(_map_overlay_tex)
	_map_overlay_layer.show_mode_animated(mode)
	_map_overlay_dirty = false
	set_process(false)
	_map_overlay_last_refresh_msec = now
	_map_overlay_refresh_count += 1
	_map_overlay_last_result = {
		"path": result.get("path", ""),
		"upload_bytes": int(result.get("upload_bytes", 0)),
		"encode_upload_ms": (Time.get_ticks_usec() - started) / 1000.0,
		"stats": result.get("stats", {}),
	}


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


func get_gm_capabilities() -> Dictionary:
	var technologies := PackedStringArray()
	var goods := PackedStringArray()
	var buildings := PackedStringArray()
	if _generator != null:
		var country = _generator.get_country_facade() if _generator.has_method("get_country_facade") else null
		if country != null and country.has_method("native_catalog"):
			technologies = country.native_catalog().get("technology_ids", PackedStringArray())
		var economy = _generator.get_economy_facade() if _generator.has_method("get_economy_facade") else null
		if economy != null:
			if economy.has_method("good_ids"):
				goods = economy.good_ids()
			if economy.has_method("building_type_ids"):
				buildings = economy.building_type_ids()
	return {
		"sections": PackedStringArray(["overview", "selected"]),
		"commands": _gm_command_specs(technologies, goods, buildings),
		"toggles": [
			{"id": "simulation.paused", "label": "暂停模拟", "group": "模拟"},
			{"id": "simulation.click_claim_territory", "label": "点击地块接管领土", "group": "模拟"},
			{"id": "visual.day_night", "label": "昼夜循环", "group": "视觉"},
			{"id": "visual.fog_of_war", "label": "战争迷雾", "group": "视觉"},
			{"id": "visual.water_effect", "label": "水面效果", "group": "视觉"},
			{"id": "visual.ocean_current", "label": "洋流显示", "group": "视觉"},
			{"id": "visual.extreme_weather", "label": "极端天气地表效果", "group": "视觉"},
			{"id": "diagnostics.perf_sampler", "label": "渲染性能采样", "group": "诊断"},
			{"id": "diagnostics.pk_log", "label": "PKLog 诊断日志", "group": "诊断"},
		],
	}


func get_gm_snapshot(section: String, _context: Dictionary = {}) -> Dictionary:
	match section:
		"overview":
			return {"ok": true, "revision": _fast_tick_count, "data": _gm_overview_snapshot()}
		"selected":
			if _selected_cell == null or _current_map == null:
				return {"ok": false, "code": "no_selection", "message": "尚未选中地块。", "data": {}}
			return {"ok": true, "revision": _fast_tick_count,
				"data": _gm_selected_snapshot(int(_selected_cell.index))}
	return {"ok": false, "code": "unknown_section", "message": "未知 GM 数据页。", "data": {}}


func execute_gm_command(command_id: String, raw_args: Dictionary) -> Dictionary:
	var spec := _gm_find_command_spec(command_id)
	if spec.is_empty():
		return _gm_error("unknown_command", "未知指令：%s" % command_id)
	var validated := _gm_validate_args(spec, raw_args)
	if not bool(validated.get("ok", false)):
		return validated
	var args: Dictionary = validated.get("args", {})
	if _world_clock == null and command_id.begins_with("time."):
		return _gm_error("clock_unavailable", "时钟尚未就绪。")
	if command_id == "time.pause":
		var state := String(args.get("state", "toggle"))
		var paused := not _world_clock.paused if state == "toggle" else state == "on"
		_world_clock.pause(paused)
		on_clock_running_changed(not paused)
		gm_toggle_changed.emit("simulation.paused", paused)
		return _gm_ok("模拟已%s。" % ("暂停" if paused else "继续"), false, -1)
	if command_id == "time.speed":
		var speed := float(args.get("value", 1.0))
		_world_clock.set_speed(speed)
		on_clock_running_changed(true)
		return _gm_ok("速度已设为 %d 倍。" % int(speed), false, -1)

	if _generator == null or _world_clock == null:
		return _gm_error("world_not_ready", "世界尚未生成，无法提交该指令。")
	var effective_day := int(args.get("day", _world_clock.day_index() + 1))
	if effective_day <= _world_clock.day_index():
		return _gm_error("effective_day_invalid", "生效日必须晚于当前游戏日。")
	var sequence := _gm_sequence
	_gm_sequence += 1
	var result: Dictionary
	if command_id.begins_with("country."):
		result = _gm_execute_country_command(command_id, args, effective_day, sequence)
	else:
		result = _gm_execute_economy_command(command_id, args, effective_day, sequence)
	if not bool(result.get("ok", false)):
		return _gm_error(String(result.get("reason", "command_rejected")),
			"指令被运行时拒绝：%s" % String(result.get("reason", "unknown")), result)
	var response := _gm_ok("指令已排入第 %d 日的权威命令队列。" % effective_day, true, effective_day)
	response["data"] = result
	return response


func get_gm_toggle_state(toggle_id: String) -> Dictionary:
	if _world_clock == null and toggle_id == "simulation.paused":
		return _gm_error("clock_unavailable", "时钟尚未就绪。")
	match toggle_id:
		"simulation.paused":
			return {"ok": true, "enabled": _world_clock.paused}
		"simulation.click_claim_territory":
			return {"ok": true, "enabled": _gm_click_claim_territory_enabled}
		"visual.day_night":
			return {"ok": true, "enabled": day_night_enabled}
		"visual.fog_of_war":
			return {"ok": true, "enabled": is_fog_of_war_enabled()}
		"visual.water_effect":
			return _gm_renderer_toggle_state("water_effect_enabled")
		"visual.ocean_current":
			return _gm_renderer_toggle_state("ocean_current_enabled")
		"visual.extreme_weather":
			return _gm_renderer_toggle_state("extreme_weather_ground_effect_enabled")
		"diagnostics.perf_sampler":
			return _gm_renderer_toggle_state("perf_sampler_enabled")
		"diagnostics.pk_log":
			return {"ok": true, "enabled": PKLog.enabled}
	return _gm_error("unknown_toggle", "未知 GM 开关。")


func set_gm_toggle(toggle_id: String, enabled: bool) -> Dictionary:
	match toggle_id:
		"simulation.paused":
			if _world_clock == null:
				return _gm_error("clock_unavailable", "时钟尚未就绪。")
			_world_clock.pause(enabled)
			on_clock_running_changed(not enabled)
		"simulation.click_claim_territory":
			return _gm_set_click_claim_territory_enabled(enabled)
		"visual.day_night":
			set_day_night_enabled(enabled)
		"visual.fog_of_war":
			set_fog_of_war_enabled(enabled)
		"visual.water_effect":
			if not _gm_call_renderer_toggle("set_water_effect_enabled", enabled):
				return _gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"visual.ocean_current":
			if not _gm_call_renderer_toggle("set_ocean_current_enabled", enabled):
				return _gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"visual.extreme_weather":
			if not _gm_call_renderer_toggle("set_extreme_weather_ground_effect_enabled", enabled):
				return _gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"diagnostics.perf_sampler":
			if not _gm_call_renderer_toggle("set_perf_sampler_enabled", enabled):
				return _gm_error("renderer_unavailable", "渲染器尚未就绪。")
		"diagnostics.pk_log":
			PKLog.enabled = enabled
		_:
			return _gm_error("unknown_toggle", "未知 GM 开关。")
	var actual_enabled := bool(get_gm_toggle_state(toggle_id).get("enabled", enabled))
	gm_toggle_changed.emit(toggle_id, actual_enabled)
	return {"ok": true, "enabled": actual_enabled}


func _gm_command_specs(technologies: PackedStringArray = PackedStringArray(),
		goods: PackedStringArray = PackedStringArray(),
		buildings: PackedStringArray = PackedStringArray()) -> Array:
	return [
		{"id": "time.pause", "label": "暂停/继续模拟", "category": "时间", "destructive": false,
			"args": [{"name": "state", "type": "enum", "required": false,
				"default": "toggle", "choices": PackedStringArray(["toggle", "on", "off"])}]},
		{"id": "time.speed", "label": "设置模拟速度", "category": "时间", "destructive": false,
			"args": [{"name": "value", "type": "float", "required": true,
				"choices": PackedFloat32Array(GM_SPEED_PRESETS)}]},
		{"id": "country.rename", "label": "重命名国家", "category": "国家", "destructive": true,
			"args": [_gm_arg("country_handle", "int", false), _gm_arg("name", "string", true), _gm_day_arg()]},
		{"id": "country.grant_technology", "label": "授予科技", "category": "国家", "destructive": true,
			"args": [_gm_arg("country_handle", "int", false), _gm_choice_arg("technology_id", technologies), _gm_day_arg()]},
		{"id": "country.reveal_all_technologies", "label": "揭示全部未来科技", "category": "国家", "destructive": true,
			"args": [_gm_arg("country_handle", "int", false), _gm_day_arg()]},
		{"id": "country.transfer_territory", "label": "转移领土", "category": "国家", "destructive": true,
			"args": [_gm_arg("cell", "int", false), _gm_arg("country_handle", "int", true), _gm_day_arg()]},
		{"id": "economy.add_stock", "label": "增加本地库存", "category": "经济", "destructive": true,
			"args": [_gm_arg("cell", "int", false), _gm_choice_arg("good_id", goods), _gm_positive_arg("quantity"), _gm_day_arg()]},
		{"id": "economy.mint_to_cohort", "label": "向阶层铸币", "category": "经济", "destructive": true,
			"args": [_gm_arg("cohort_handle", "int", true), _gm_positive_arg("amount"), _gm_day_arg()]},
		{"id": "economy.burn_from_cohort", "label": "从阶层销毁货币", "category": "经济", "destructive": true,
			"args": [_gm_arg("cohort_handle", "int", true), _gm_positive_arg("amount"), _gm_day_arg()]},
		{"id": "economy.add_population", "label": "增加阶层人口", "category": "经济", "destructive": true,
			"args": [_gm_arg("cohort_handle", "int", true), _gm_positive_arg("amount", "int"), _gm_day_arg()]},
		{"id": "economy.build", "label": "建造建筑", "category": "经济", "destructive": true,
			"args": [_gm_arg("cell", "int", false), _gm_choice_arg("building_id", buildings),
				_gm_positive_arg("count", "int"), _gm_arg("owner_handle", "int", true), _gm_day_arg()]},
		{"id": "economy.demolish", "label": "拆除建筑", "category": "经济", "destructive": true,
			"args": [_gm_arg("cell", "int", false), _gm_choice_arg("building_id", buildings),
				_gm_positive_arg("count", "int"), _gm_arg("owner_handle", "int", true), _gm_day_arg()]},
	]


func _gm_overview_snapshot() -> Dictionary:
	var calendar := _world_clock.calendar_date() if _world_clock != null else {}
	var country_report := _generator.get_country_report() if _generator != null and _generator.has_method("get_country_report") else {}
	var economy_report := _generator.get_economy_report() if _generator != null and _generator.has_method("get_economy_report") else {}
	return {
		"world": {"ready": _current_map != null, "seed": _last_seed,
			"width": _current_map.width if _current_map != null else 0,
			"height": _current_map.height if _current_map != null else 0,
			"cells": _current_map.cell_count() if _current_map != null else 0},
		"clock": {"day_index": _world_clock.day_index() if _world_clock != null else -1,
			"year": int(calendar.get("year", 0)), "month": int(calendar.get("month", 0)),
			"day": int(calendar.get("day", 0)), "paused": _world_clock.paused if _world_clock != null else true,
			"speed": _world_clock.speed_multiplier if _world_clock != null else 0.0},
		"runtime": {"fast_tick": _fast_tick_count, "last_tick_ms": _last_fast_tick_ms,
			"sus": get_sus_last_tick_summary(), "timing": _last_tick_timing.duplicate(false)},
		"country": country_report,
		"economy": economy_report,
		"recorders": _gm_recorder_snapshot(),
	}


func _gm_selected_snapshot(cell_idx: int) -> Dictionary:
	var cell := _current_map.cell_at(cell_idx)
	if cell == null:
		return {}
	var country_summary := {}
	var country_snapshot := {}
	var treasury := {}
	var population := {}
	var market := {}
	var buildings := {}
	if _generator != null:
		var country = _generator.get_country_facade() if _generator.has_method("get_country_facade") else null
		if country != null:
			country_summary = country.cell_summary(cell_idx)
			var handle := int(country_summary.get("country_handle", 0))
			if handle != 0:
				country_snapshot = country.snapshot(handle)
				treasury = country.treasury_snapshot(handle)
		var economy = _generator.get_economy_facade() if _generator.has_method("get_economy_facade") else null
		if economy != null:
			population = economy.population_cell_snapshot(cell_idx)
			market = economy.market_cell_snapshot(cell_idx)
			buildings = economy.building_cell_snapshot(cell_idx)
	return {
		"cell": {"index": cell_idx, "q": int(cell.q), "r": int(cell.r),
			"terrain": _view_adapter.get_terrain(cell_idx) if _view_adapter != null else int(cell.terrain),
			"landform": _view_adapter.get_landform(cell_idx) if _view_adapter != null else int(cell.landform),
			"temperature": _view_adapter.get_temp(cell_idx) if _view_adapter != null else float(cell.temperature),
			"moisture": _view_adapter.get_moisture(cell_idx) if _view_adapter != null else float(cell.moisture),
			"elevation": _view_adapter.get_elevation(cell_idx) if _view_adapter != null else float(cell.elevation)},
		"country_summary": country_summary,
		"country": country_snapshot,
		"treasury": treasury,
		"population": population,
		"market": market,
		"buildings": buildings,
		"resources": _gm_resource_snapshot(cell_idx),
	}


func _gm_resource_snapshot(cell_idx: int) -> Array:
	var out: Array = []
	if _current_map == null:
		return out
	for profile in ResourceProfileRegistry.ordered():
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field == "":
			continue
		var values = _current_map.get(field)
		if values is PackedFloat32Array and cell_idx < values.size():
			var reserve := float(values[cell_idx])
			if reserve > 0.000001:
				out.append({"id": String(profile.id), "name": profile.display_name, "reserve": reserve})
	return out


func _gm_recorder_snapshot() -> Dictionary:
	return {
		"performance": _gm_one_recorder_state(_perf_recorder),
		"tiles": _gm_one_recorder_state(_tile_data_recorder),
		"economy": _gm_one_recorder_state(_economy_data_recorder),
	}


func _gm_one_recorder_state(recorder: RefCounted) -> Dictionary:
	if recorder == null:
		return {"available": false, "recording": false, "rows": 0}
	return {"available": true,
		"recording": bool(recorder.call("is_recording")) if recorder.has_method("is_recording") else false,
		"rows": int(recorder.call("row_count")) if recorder.has_method("row_count") else 0}


func _gm_execute_country_command(command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var facade = _generator.get_country_facade() if _generator.has_method("get_country_facade") else null
	if facade == null:
		return {"ok": false, "reason": "country_facade_unavailable"}
	var handle := int(args.get("country_handle", _gm_selected_country_handle()))
	match command_id:
		"country.rename":
			return facade.rename_country(handle, String(args.name), effective_day, sequence)
		"country.grant_technology":
			return facade.grant_technology(handle, StringName(args.technology_id), effective_day, sequence)
		"country.reveal_all_technologies":
			return facade.reveal_all_technologies(handle, effective_day, sequence)
		"country.transfer_territory":
			return facade.transfer_territory(_gm_resolve_cell(args), handle, effective_day, sequence)
	return {"ok": false, "reason": "unsupported_country_command"}


func _gm_execute_economy_command(command_id: String, args: Dictionary,
		effective_day: int, sequence: int) -> Dictionary:
	var facade = _generator.get_economy_facade() if _generator.has_method("get_economy_facade") else null
	if facade == null:
		return {"ok": false, "reason": "economy_facade_unavailable"}
	match command_id:
		"economy.add_stock":
			var quantity := _gm_scaled_positive(args.quantity, GM_GOODS_SCALE)
			if quantity <= 0:
				return {"ok": false, "reason": "scaled_quantity_zero"}
			return facade.add_stock(_gm_resolve_cell(args), StringName(args.good_id),
				quantity, effective_day, sequence)
		"economy.mint_to_cohort":
			var minted := _gm_scaled_positive(args.amount, GM_CASH_SCALE)
			if minted <= 0:
				return {"ok": false, "reason": "scaled_amount_zero"}
			return facade.mint_to_cohort(int(args.cohort_handle),
				minted, effective_day, sequence)
		"economy.burn_from_cohort":
			var burned := _gm_scaled_positive(args.amount, GM_CASH_SCALE)
			if burned <= 0:
				return {"ok": false, "reason": "scaled_amount_zero"}
			return facade.burn_from_cohort(int(args.cohort_handle),
				burned, effective_day, sequence)
		"economy.add_population":
			return facade.add_population(int(args.cohort_handle), int(args.amount), effective_day, sequence)
		"economy.build":
			return facade.build(_gm_resolve_cell(args), StringName(args.building_id), int(args.count),
				int(args.owner_handle), effective_day, sequence)
		"economy.demolish":
			return facade.demolish(_gm_resolve_cell(args), StringName(args.building_id), int(args.count),
				int(args.owner_handle), effective_day, sequence)
	return {"ok": false, "reason": "unsupported_economy_command"}


func _gm_validate_args(spec: Dictionary, raw_args: Dictionary) -> Dictionary:
	var parsed := {}
	for raw_spec in spec.get("args", []):
		var arg: Dictionary = raw_spec
		var name := String(arg.get("name", ""))
		var has_value := raw_args.has(name)
		if not has_value and arg.has("default"):
			parsed[name] = arg.default
			continue
		if not has_value:
			if bool(arg.get("required", false)):
				return _gm_error("missing_argument", "缺少参数：%s" % name)
			continue
		var converted := _gm_convert_arg(raw_args[name], arg)
		if not bool(converted.get("ok", false)):
			return _gm_error("invalid_argument", "参数 %s：%s" % [name, converted.get("message", "格式错误")])
		parsed[name] = converted.value
	for key in raw_args.keys():
		var known := false
		for raw_spec in spec.get("args", []):
			if String((raw_spec as Dictionary).get("name", "")) == String(key):
				known = true
				break
		if not known:
			return _gm_error("unknown_argument", "未知参数：%s" % String(key))
	return {"ok": true, "args": parsed}


func _gm_convert_arg(value, spec: Dictionary) -> Dictionary:
	var type := String(spec.get("type", "string"))
	var converted = value
	if type == "int":
		var text := str(value)
		if not text.is_valid_int():
			return {"ok": false, "message": "必须是整数"}
		converted = text.to_int()
	elif type == "float":
		var text := str(value)
		if not text.is_valid_float():
			return {"ok": false, "message": "必须是数字"}
		converted = text.to_float()
	else:
		converted = String(value)
	if spec.has("min") and float(converted) < float(spec.min):
		return {"ok": false, "message": "不能小于 %s" % str(spec.min)}
	var choices: Array = Array(spec.get("choices", []))
	if not choices.is_empty():
		var found := false
		for choice in choices:
			if str(choice) == str(converted):
				converted = choice
				found = true
				break
		if not found:
			var labels := PackedStringArray()
			for choice in choices:
				labels.append(str(choice))
			return {"ok": false, "message": "可选值：%s" % ", ".join(labels)}
	return {"ok": true, "value": converted}


func _gm_find_command_spec(command_id: String) -> Dictionary:
	for raw in get_gm_capabilities().get("commands", []):
		var spec: Dictionary = raw
		if String(spec.get("id", "")) == command_id:
			return spec
	return {}


func _gm_resolve_cell(args: Dictionary) -> int:
	return int(args.get("cell", int(_selected_cell.index) if _selected_cell != null else -1))


func _gm_selected_country_handle() -> int:
	if _selected_cell == null or _generator == null or not _generator.has_method("get_country_facade"):
		return 0
	var facade = _generator.get_country_facade()
	return int(facade.cell_summary(int(_selected_cell.index)).get("country_handle", 0)) if facade != null else 0


func _gm_set_click_claim_territory_enabled(enabled: bool) -> Dictionary:
	if enabled:
		if _generator == null or _world_clock == null or _current_map == null:
			return _gm_error("world_not_ready", "世界尚未生成，无法启用点击接管。")
		if _player_country_handle == 0:
			_player_country_handle = _resolve_player_country_handle()
		if _player_country_handle == 0:
			return _gm_error("player_country_unavailable", "无法解析玩家国家，点击接管未启用。")
	_gm_click_claim_territory_enabled = enabled
	if not enabled:
		_gm_click_claim_pending_days.clear()
	gm_toggle_changed.emit("simulation.click_claim_territory", enabled)
	return {"ok": true, "code": "ok", "enabled": enabled,
		"message": "点击地块接管领土已%s。" % ("启用" if enabled else "关闭")}


func _gm_claim_selected_cell(cell: HexCell) -> void:
	var cell_idx := int(cell.index)
	if _current_map == null or cell_idx < 0 or cell_idx >= _current_map.cell_count():
		_gm_emit_claim_result(_gm_error("invalid_cell", "所选地块无效。"), cell_idx)
		return
	if cell_idx < _current_map.is_water_arr.size() and _current_map.is_water_arr[cell_idx] != 0:
		_gm_emit_claim_result(_gm_error("water_territory", "水域不能成为国家领土。"), cell_idx)
		return
	if _player_country_handle == 0:
		_player_country_handle = _resolve_player_country_handle()
	if _player_country_handle == 0:
		_gm_emit_claim_result(_gm_error("player_country_unavailable", "无法解析玩家国家。"), cell_idx)
		return
	var facade = _generator.get_country_facade() if _generator != null \
		and _generator.has_method("get_country_facade") else null
	if facade == null:
		_gm_emit_claim_result(_gm_error("country_facade_unavailable", "国家运行时尚未就绪。"), cell_idx)
		return
	var current_handle := int(facade.cell_summary(cell_idx).get("country_handle", 0))
	if current_handle == _player_country_handle:
		_gm_emit_claim_result({"ok": true, "code": "already_owned", "queued": false,
			"effective_day": -1, "message": "地块 #%d 已属于玩家国家。" % cell_idx,
			"data": {}}, cell_idx)
		return
	var current_day := _world_clock.day_index() if _world_clock != null else -1
	var pending_day := int(_gm_click_claim_pending_days.get(cell_idx, -1))
	if pending_day >= current_day:
		_gm_emit_claim_result({"ok": true, "code": "already_queued", "queued": true,
			"effective_day": pending_day, "message": "地块 #%d 已排队等待接管。" % cell_idx,
			"data": {}}, cell_idx)
		return
	var result := execute_gm_command("country.transfer_territory", {
		"cell": cell_idx, "country_handle": _player_country_handle})
	if bool(result.get("ok", false)) and bool(result.get("queued", false)):
		_gm_click_claim_pending_days[cell_idx] = int(result.get("effective_day", current_day + 1))
	_gm_emit_claim_result(result, cell_idx)


func _gm_emit_claim_result(raw_result: Dictionary, cell_idx: int) -> void:
	var result := raw_result.duplicate(true)
	var data: Dictionary = result.get("data", {}).duplicate(true)
	data["cell"] = cell_idx
	result["data"] = data
	gm_action_completed.emit("country.click_claim_territory", result)


func _gm_scaled_positive(value, scale: int) -> int:
	var scaled := float(value) * float(scale)
	if not is_finite(scaled) or scaled > 9.22e18:
		return -1
	return int(round(scaled))


func _gm_renderer_toggle_state(property_name: String) -> Dictionary:
	if _renderer == null:
		return _gm_error("renderer_unavailable", "渲染器尚未就绪。")
	return {"ok": true, "enabled": bool(_renderer.get(property_name))}


func _gm_call_renderer_toggle(method: String, enabled: bool) -> bool:
	if _renderer == null or not _renderer.has_method(method):
		return false
	_renderer.call(method, enabled)
	return true


func _gm_arg(name: String, type: String, required: bool) -> Dictionary:
	return {"name": name, "type": type, "required": required}


func _gm_choice_arg(name: String, choices) -> Dictionary:
	return {"name": name, "type": "string", "required": true, "choices": choices}


func _gm_positive_arg(name: String, type: String = "float") -> Dictionary:
	return {"name": name, "type": type, "required": true, "min": 0.000001 if type == "float" else 1}


func _gm_day_arg() -> Dictionary:
	return {"name": "day", "type": "int", "required": false, "min": 0}


func _gm_ok(message: String, queued: bool, effective_day: int) -> Dictionary:
	return {"ok": true, "code": "ok", "message": message,
		"queued": queued, "effective_day": effective_day, "data": {}}


func _gm_error(code: String, message: String, data: Dictionary = {}) -> Dictionary:
	return {"ok": false, "code": code, "message": message,
		"queued": false, "effective_day": -1, "data": data}


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
	var continuation: Dictionary = {}
	if _generator != null and _generator.has_method("consume_continuation_perf_summary"):
		continuation = _generator.consume_continuation_perf_summary()
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
		"speed_multiplier": float(_world_clock.speed_multiplier) if _world_clock != null else 0.0,
		"fast_ms": fast_ms,
		"t_sus_ms": t_sus_ms,
		"t_render_ms": t_render_ms,
		"t_ui_ms": t_ui_ms,
		"continuation_frames": int(continuation.get("frames", 0)),
		"continuation_slices": int(continuation.get("slices", 0)),
		"continuation_country_slices": int(continuation.get("country_slices", 0)),
		"continuation_economy_slices": int(continuation.get("economy_slices", 0)),
		"continuation_wall_ms": float(continuation.get("wall_ms", 0.0)),
		"continuation_max_frame_wall_ms": float(continuation.get("max_frame_wall_ms", 0.0)),
		"continuation_max_slice_ms": float(continuation.get("max_slice_ms", 0.0)),
		"continuation_last_slice_ms": float(continuation.get("last_slice_ms", 0.0)),
		"continuation_budget_ms": float(continuation.get("budget_ms", 0.0)),
		"continuation_last_stage": str(continuation.get("last_stage", "")),
		"continuation_last_next_stage": str(continuation.get("last_next_stage", "")),
		"continuation_last_substage": str(continuation.get("last_substage", "")),
		"continuation_last_path": str(continuation.get("last_path", "")),
		"continuation_done": bool(continuation.get("done", false)),
		"continuation_stage_counts": JSON.stringify(continuation.get("stage_counts", {})),
		"continuation_stage_wall_ms": JSON.stringify(continuation.get("stage_wall_ms", {})),
		"continuation_stage_max_slice_ms": JSON.stringify(
			continuation.get("stage_max_slice_ms", {})),
		"continuation_substage_counts": JSON.stringify(
			continuation.get("substage_counts", {})),
		"continuation_substage_wall_ms": JSON.stringify(
			continuation.get("substage_wall_ms", {})),
		"continuation_substage_max_slice_ms": JSON.stringify(
			continuation.get("substage_max_slice_ms", {})),
		"continuation_substage_work": JSON.stringify(
			continuation.get("substage_work", {})),
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
		var fog_layer := _renderer.get_node_or_null("FogOfWarLayer")
		if fog_layer != null and fog_layer.has_method("set_clock_speed_multiplier"):
			fog_layer.set_clock_speed_multiplier(new_speed)
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


func on_clock_running_changed(running: bool) -> void:
	if _renderer == null:
		return
	var weather_layer := _renderer.get_node_or_null("WeatherLayer")
	if weather_layer != null and weather_layer.has_method("set_clock_running"):
		weather_layer.set_clock_running(running)
	var fog_layer := _renderer.get_node_or_null("FogOfWarLayer")
	if fog_layer != null and fog_layer.has_method("set_clock_running"):
		fog_layer.set_clock_running(running)


func on_visual_day_phase_changed(visual_day_phase: float) -> void:
	if _renderer == null:
		return
	_renderer.set_day_phase(visual_day_phase)
	if _tod_profile != null and _renderer.has_method("apply_tod"):
		_tod_profile.recompute(visual_day_phase, day_night_enabled)
		_renderer.apply_tod(_tod_profile)


func on_season_changed(season_idx: int) -> void:
	if _generator == null or _current_map == null or _world_data == null:
		return
	if _renderer != null and _renderer.has_method("begin_season_transition") and _world_clock != null:
		_renderer.begin_season_transition(_world_clock.season_phase())
	var cp = _generator._c() if _generator.has_method("_c") else null
	mark_map_overlay_dirty(&"season_changed")
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
		mark_map_overlay_dirty(&"year_changed")


func fit_camera(safe_area: Rect2 = Rect2()) -> void:
	if _camera != null:
		_camera.fit_to_viewport(1.0, safe_area, true)


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
	if _map_overlay_layer != null:
		_map_overlay_layer.set_bounds(_renderer.get_world_bounds())
		_map_overlay_layer.set_horizontal_wrap(map_wrap_period_x())
		_map_overlay_layer.configure_cell_lut(
			_world_data.enum_atlas_tex,
			_world_data.lut_dims
		)
	if _renderer.has_method("set_map_baker") and _generator != null and "_baker" in _generator:
		_renderer.set_map_baker(_generator._baker)
	_bind_country_visuals()
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
		_camera.fit_to_viewport(1.0, safe_area, true)
		_renderer.set_camera_zoom(_camera.zoom.x)


# ─── 国界线与视野迷雾 ─────────────────────────────────────────────────
# 两者共用同一个触发源：领土是国界的定义，也是视野的源头。CountryFacade 的
# country_committed 极少触发（领土变更），所以全量重算即可，不做增量。

## 世界就绪后一次性绑定。此刻 country bootstrap 已完成，country_slot_arr 已由
## NativeCountryRuntime 发布到 MapData，可以直接首解算。
func _bind_country_visuals() -> void:
	_fog_of_war_enabled = _resolve_fog_of_war_enabled()
	_player_country_slot = _resolve_player_country_slot()
	_player_country_handle = _resolve_player_country_handle()
	if _renderer != null and _renderer.has_method("set_fog_of_war_enabled"):
		_renderer.set_fog_of_war_enabled(_fog_of_war_enabled, fog_early_out_enabled)
	_connect_country_committed()
	var report := refresh_country_visuals("world_ready")
	var vision: Dictionary = report.get("vision", {})
	var border: Dictionary = report.get("border", {})
	print("[vision] fog=%s player_slot=%d early_out=%s visible=%d explored=%d/%d solve_ms=%.3f border_edges=%d" % [
		"ON" if _fog_of_war_enabled else "OFF", _player_country_slot,
		"ON" if fog_early_out_enabled else "OFF",
		int(vision.get("visible", 0)), int(vision.get("explored", 0)),
		int(vision.get("cells", 0)), float(vision.get("elapsed_ms", 0.0)),
		int(border.get("edges", 0))])


func _connect_country_committed() -> void:
	var facade = _generator.get_country_facade() if _generator != null \
		and _generator.has_method("get_country_facade") else null
	if facade == null or not facade.has_signal("country_committed"):
		return
	var callback := Callable(self, "_on_country_committed")
	if not facade.country_committed.is_connected(callback):
		facade.country_committed.connect(callback)


func _on_country_committed(_report: Dictionary) -> void:
	if _player_country_slot < 0:
		_player_country_slot = _resolve_player_country_slot()
	refresh_country_visuals("country_committed")


## 重算视野 → 把知识度推进 enum_lut.a → 重建国界 mesh。
## 返回诊断信息（GM 面板 / 测试用）。
func refresh_country_visuals(reason: String) -> Dictionary:
	var out := {"reason": reason, "vision": {}, "border": {}, "lut": {}}
	if _current_map == null or _world_data == null:
		return out
	if _player_country_slot < 0:
		_player_country_slot = _resolve_player_country_slot()
	out["vision"] = _refresh_vision()
	out["lut"] = _republish_cell_luts()
	out["border"] = _refresh_country_borders()
	return out


func player_country_slot() -> int:
	return _player_country_slot


func is_fog_of_war_enabled() -> bool:
	return _fog_of_war_enabled


## GM 与场景配置共用这一入口；开启请求仍受正式对局上下文门控。
func set_fog_of_war_enabled(enabled: bool) -> void:
	fog_of_war_enabled = enabled
	_fog_of_war_enabled = _resolve_fog_of_war_enabled()
	if _renderer != null and _renderer.has_method("set_fog_of_war_enabled"):
		_renderer.set_fog_of_war_enabled(_fog_of_war_enabled, fog_early_out_enabled)
	if _current_map != null and _world_data != null:
		refresh_country_visuals("gm_fog_toggle")


## 迷雾只在正式对局里生效。调试 / 沙盒路径（没有 gameplay start context，
## country.default 铺满全部陆地）保持全图可见，否则整张地图会被云盖死。
func _resolve_fog_of_war_enabled() -> bool:
	if not fog_of_war_enabled:
		return false
	if _generator == null or not _generator.has_method("gameplay_start_report"):
		return false
	return bool(_generator.gameplay_start_report().get("ok", false))


func _resolve_player_country_slot() -> int:
	if _current_map == null or _generator == null \
			or not _generator.has_method("gameplay_start_report"):
		return -1
	var start_cell := int(_generator.gameplay_start_report().get("cell", -1))
	if start_cell < 0 or start_cell >= _current_map.country_slot_arr.size():
		return -1
	return int(_current_map.country_slot_arr[start_cell])


func _resolve_player_country_handle() -> int:
	if _generator == null or not _generator.has_method("gameplay_start_report") \
			or not _generator.has_method("get_country_facade"):
		return 0
	var start_cell := int(_generator.gameplay_start_report().get("cell", -1))
	var facade = _generator.get_country_facade()
	if facade == null or start_cell < 0:
		return 0
	return int(facade.cell_summary(start_cell).get("country_handle", 0))


func _refresh_vision() -> Dictionary:
	if not _fog_of_war_enabled:
		# 迷雾关：全图视作已探索且可见。UI 门控与 enum_lut.a 因此自动放行，
		# 不需要在每个消费点再判一次 flag。
		return VisionSolver.mark_all_visible(_current_map)
	return VisionSolver.solve(_current_map, _world_data, _player_country_slot)


## 迷雾值住在 enum_lut 的 A 通道，所以视野一变就必须重烘一次 LUT。
## 不能等 DynamicVisualAtlasUploadSystem 的日刷——它在 dirty_count==0 时会
## early-return，视野变化不体现在 climate/weather dirty mask 上。
func _republish_cell_luts() -> Dictionary:
	if _generator == null or not ("_baker" in _generator):
		return {"ok": false, "reason": "no_baker"}
	var baker = _generator._baker
	if baker == null or not baker.has_method("refresh_cell_luts_daily"):
		return {"ok": false, "reason": "baker_missing_refresh"}
	return baker.refresh_cell_luts_daily(_current_map, _world_data)


func _refresh_country_borders() -> Dictionary:
	if _renderer == null or not _renderer.has_method("country_border_layer"):
		return {"ok": false, "reason": "no_renderer"}
	var layer = _renderer.country_border_layer()
	if layer == null:
		return {"ok": false, "reason": "no_border_layer"}
	layer.set_hex_size(hex_size)
	layer.set_horizontal_wrap(map_wrap_period_x())
	layer.set_player_slot(_player_country_slot)
	var stats: Dictionary = layer.rebuild(_current_map)
	stats["ok"] = true
	return stats


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
	if not _new_game_config.is_empty():
		return _new_game_config
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
		var requested_population_scale := int((base as Dictionary).get(
			"test_economy_population_scale", test_economy_population_scale))
		test_economy_population_scale = requested_population_scale \
			if requested_population_scale in [0, 1, 10, 100, 1000] else 0
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
