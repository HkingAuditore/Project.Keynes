extends "res://scripts/game/world_runtime_adapters.gd"
class_name WorldRuntimeHost

func synchronize_environment_display_for_save() -> bool:
	if not _native_environment_active:
		return true
	var committed: Dictionary = _runtime_control_state()
	_consume_runtime_commit_if_ready(committed)
	_apply_climate_writeback_if_authoritative(committed)
	if _runtime_climate_writeback_last_day < int(committed.get("simulation_committed_day", -1)):
		return false
	_generator._write_runtime_enum_axes_dense(_current_map)
	return true
func _prepare_world_data() -> Dictionary:
	return await _generation_adapter._prepare_world_data(self)
func _prepare_world_presentation() -> Dictionary:
	return await _generation_adapter._prepare_world_presentation(self)
func _prepare_world_restore() -> Dictionary:
	return _generation_adapter._prepare_world_restore(self)
func _restore_prepared_world() -> Dictionary:
	return _generation_adapter._restore_prepared_world(self)
func _prepare_world_simulation() -> Dictionary:
	return await _generation_adapter._prepare_world_simulation(self)
func _session_preparation_active() -> bool:
	return _generation_adapter._session_preparation_active(self)
func _session_preparation_failure() -> Dictionary:
	return _generation_adapter._session_preparation_failure(self)
func _start_runtime_executor() -> void:
	_generation_adapter._start_runtime_executor(self)
func _stop_previous_runtime_worker() -> Dictionary:
	return await _generation_adapter._stop_previous_runtime_worker(self)
func configure(
	renderer: HexRenderer,
	camera: MapCamera,
	world_clock: WorldClock,
	map_overlay_layer: DataOverlayLayer = null
) -> void:
	_clock_binding.detach()
	if _camera != null and _camera.zoom_changed.is_connected(_on_camera_zoom_changed):
		_camera.zoom_changed.disconnect(_on_camera_zoom_changed)
	if _camera != null and _camera.view_changed.is_connected(_on_camera_view_changed):
		_camera.view_changed.disconnect(_on_camera_view_changed)
	_renderer = renderer
	_camera = camera
	_world_clock = world_clock
	if _renderer != null and _world_clock != null:
		_renderer.configure_shader_clock(_world_clock.set_visual_shader_days_per_year)
	_map_overlay_layer = map_overlay_layer
	if _camera != null:
		_camera.zoom_changed.connect(_on_camera_zoom_changed)
		_camera.view_changed.connect(_on_camera_view_changed)
		_on_camera_zoom_changed(_camera.zoom.x)
		_on_camera_view_changed(_camera.current_world_view_rect(), _camera.position, _camera.zoom.x)
	set_process(false)
	_init_tod_profile()


func _admit_runtime_calendar(date: int) -> int:
	if not _runtime_ready_for_ticks or not _native_environment_active \
			or _runtime_worker_fault_paused:
		return _calendar_admitted_through
	var ext = _generator.get_data_core_world_ext()
	_calendar_admitted_through = int(ext.request_runtime_calendar_day(date))
	return _calendar_admitted_through


func _forward_runtime_clock(paused: bool, speed: float) -> void:
	if paused or speed <= 0.0:
		_calendar_admitted_through = -1
	_generator.set_runtime_clock_threaded(paused, speed)


func _on_camera_zoom_changed(value: float) -> void:
	if _renderer != null:
		_renderer.set_camera_zoom(value)


func _on_camera_view_changed(world_rect: Rect2, center: Vector2, zoom_value: float) -> void:
	if _renderer != null and _renderer.has_method("set_camera_view"):
		_renderer.set_camera_view(world_rect, center, zoom_value)


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


func _game_flow_service() -> Node:
	return get_node_or_null(^"/root/GameFlow")


func current_map() -> MapData:
	return _current_map


func building_visual_intel_cache() -> BuildingVisualIntelCache:
	return _building_visual_intel


func building_visual_type_count() -> int:
	return _building_visual_type_count


## Rebinds the renderer to the authored economy catalog. Save restore calls this
## immediately after PKEC so PKFG validation sees the real type upper bound.
## During pre-restore world generation the economy facade can legitimately be
## unconfigured; that state is deferred without emitting a false stale-DLL warning.
## Web 专用：把 building visual catalog 的构建推到进世界之后。
## 这一步（economy facade 目录 + renderer.configure_building_visuals）在浏览器里
## 实测 42s，放在加载路径里会把"进世界"卡死；延后执行只影响建筑外观的可用时间。
func _defer_building_visual_catalog_after_ready() -> void:
	await _generation_adapter._defer_building_visual_catalog_after_ready(self)
func _bind_presentation_resources() -> void:
	_presentation.bind_resources(_current_map, _generator, _renderer, _camera,
		_fog_of_war_enabled, hex_size, map_wrap_period_x())


func refresh_building_visual_catalog() -> Dictionary:
	_bind_presentation_resources()
	return _presentation.refresh_building_visual_catalog()


func set_selected_cell(cell: HexCell) -> void:
	_selected_cell = cell
	if cell != null and _gm_click_claim_territory_enabled:
		_gm_claim_selected_cell(cell)


func get_selected_cell() -> HexCell:
	return _selected_cell


func last_seed() -> int:
	return _last_seed


## 把本次生成真正使用的 seed 写回会话 config（`base.initial_seed`）。
## 0 表示「随机」（map_generator.gd generate(): `cfg.seed != 0 else randi()`），
## 所以任何生成路径都可能产出一个配置文件里没有的 seed；不写回的话，之后存档
## 记录的是旧 seed，读档重建出的是另一张世界，起始格/领土/地形互相矛盾。
func _adopt_generated_seed(generated_seed: int) -> void:
	_generation_adapter._adopt_generated_seed(self, generated_seed)
func last_world_generation_error_text() -> String:
	return _generation_adapter.last_world_generation_error_text(self)
func _report_world_generation_failure(preflight_override: Dictionary = {}) -> void:
	_generation_adapter._report_world_generation_failure(self, preflight_override)
func _emit_world_generation_failure(stage: String, reason: String, summary: String, hint: String) -> void:
	_generation_adapter._emit_world_generation_failure(self, stage, reason, summary, hint)
func _format_world_generation_detail(stage: String, reason: String, summary: String, hint: String) -> String:
	return _generation_adapter._format_world_generation_detail(self, stage, reason, summary, hint)
func _world_generation_failure_summary(err: Dictionary) -> String:
	return _generation_adapter._world_generation_failure_summary(self, err)
func _maybe_run_mapgen_selfcheck_cli() -> void:
	_generation_adapter._maybe_run_mapgen_selfcheck_cli(self)
func _ready() -> void:
	_maybe_run_mapgen_selfcheck_cli()


func session_config() -> Dictionary:
	return _new_game_config.duplicate(true)


func last_tick_report() -> Dictionary:
	return _last_tick_report.duplicate()


func is_runtime_ready_for_ticks() -> bool:
	return _runtime_ready_for_ticks


func uses_worker_day_commits() -> bool:
	if not _runtime_ready_for_ticks or _native_daily_inline_active:
		return false
	var state := _runtime_control_state()
	return state.get("simulation_thread_mode", "OFF") == "ACTIVE" and bool(state.get("authority_ready", false))

func reset_presentation() -> void:
	publication_reader.reset()
	_presentation.reset_worker_views()
	if _generator != null:
		_generator._get_map_runtime_bridge().clear_runtime_map_lut_frame()
	presentation_reset.emit()

func ui_worker_day() -> int:
	if _presentation.ui_presented_day >= 0:
		return _presentation.ui_presented_day
	# A new game's UI starts at day zero even when its first delivery is held.
	return 0 if _runtime_commit_day >= 0 else -1

func received_worker_day() -> int:
	return _runtime_commit_day

func presented_worker_day() -> int:
	return _presentation.presented_worker_day()


func set_day_night_enabled(enabled: bool) -> void:
	day_night_enabled = enabled
	if _renderer != null:
		_renderer.set_day_night_enabled(enabled)
	if _gm_tod_preview_enabled:
		_gm_tod_sun_uv = _gm_tod_cycle_uv if enabled else _current_eternal_uv()
		if enabled and _world_clock != null:
			_world_clock.hold_visual_day_phase(_gm_tod_cycle_uv.x)
		_apply_gm_tod_sun_preview()
		gm_tod_preview_changed.emit(true)
		return
	if _tod_profile == null or _renderer == null:
		return
	var phase := _world_clock.visual_day_phase if _world_clock != null else 0.25
	_tod_profile.recompute(phase, enabled)
	if _renderer.has_method("apply_tod"):
		_renderer.apply_tod(_tod_profile)


func is_day_night_enabled() -> bool:
	return day_night_enabled


func register_session_module(module) -> Dictionary:
	if _generator != null or _runtime_session.report().state != "CONFIGURING":
		return {"ok": false, "code": "session_composition_locked"}
	if module == null or not module.has_method("descriptor"):
		return {"ok": false, "code": "session_module_contract_invalid"}
	var candidate := _session_extensions.duplicate()
	candidate.append(module)
	var result: Dictionary = _runtime_session.configure(WorldSessionModules.entries(self, candidate))
	if bool(result.get("ok", false)):
		_session_extensions = candidate
	return result


func session_report() -> Dictionary:
	return _runtime_session.report()


func is_session_closing() -> bool:
	return _runtime_session.is_closing()


func begin_state_capture() -> Dictionary:
	return _runtime_session.begin_capture()


func end_state_capture() -> void:
	_runtime_session.end_capture()


func generate_world(seed_override: int = -1, safe_area: Rect2 = Rect2()) -> void:
	await _generation_adapter.generate_world(self, seed_override, safe_area)
func close_world() -> Dictionary:
	return await _lifecycle.close_world(self)


func _cancel_world_preparation() -> void:
	_lifecycle.cancel_world_preparation(self)


func _cancel_session_simulation() -> void:
	_lifecycle.cancel_session_simulation(self)


func _release_session_simulation() -> Dictionary:
	return await _lifecycle.release_session_simulation(self)


func _cancel_session_presentation() -> void:
	_lifecycle.cancel_session_presentation(self)


func _release_session_presentation() -> Dictionary:
	return _lifecycle.release_session_presentation(self)


func _release_world_data() -> Dictionary:
	return await _lifecycle.release_world_data(self)


func _session_noop() -> void:
	_generation_adapter._session_noop(self)
func _session_ok() -> Dictionary:
	return _generation_adapter._session_ok(self)
func _preparation_process_frame() -> void:
	await get_tree().process_frame


func is_loading_session() -> bool:
	return not _load_slot_id.is_empty()


# Daily and worker methods delegate to the passive adapter.
func player_confirmation_view() -> Dictionary:
	return _player_confirmation_view

func _publish_player_confirmation(report: Dictionary) -> void:
	if int(report.get("player_block_day", -1)) > maxi(0, _runtime_commit_day):
		return
	var view := {
		"reason": String(report.get("player_block_reason", "")),
		"hide_popups": bool(report.get("player_popups_suppressed", false)),
		"suppress_event_popups": bool(report.get("suppress_event_popups", false)),
		"family_offer": report.get("family_founding_offer", {}),
		"ideology_generation": int(report.get("ideology_offer_generation", 0)),
	}
	if view == _player_confirmation_view:
		return
	var old_view := _player_confirmation_view
	_player_confirmation_view = view
	player_confirmation_updated.emit(view)
	if bool(view.hide_popups) != bool(old_view.get("hide_popups", false)):
		gm_toggle_changed.emit("ui.hide_all_except_gm", bool(view.hide_popups))
	if bool(view.suppress_event_popups) != bool(old_view.get("suppress_event_popups", false)):
		gm_toggle_changed.emit("ui.suppress_popups", bool(view.suppress_event_popups))

func submit_player_confirmation(action: String, value: int) -> Dictionary:
	if _generator == null or not _runtime_ready_for_ticks:
		return {"ok": false, "code": "player_confirmation_unavailable"}
	return _generator.get_data_core_world_ext().submit_player_confirmation(action, value, 0)
func restart_runtime_executor() -> Dictionary:
	return _lifecycle.restart_runtime_executor(self)

func climate_authority_diagnostics() -> Dictionary:
	return _climate_runtime.climate_authority_diagnostics(self)
func _map_overlay_refresh_interval_msec() -> int:
	_bind_overlay_resources()
	return _overlay._map_overlay_refresh_interval_msec()


func _refresh_map_overlay(force: bool) -> void:
	_bind_overlay_resources()
	_overlay._refresh_map_overlay(force)


func get_current_map() -> MapData:
	return _current_map


func get_world_clock_ref() -> WorldClock:
	return _world_clock


func get_generator() -> MapGenerator:
	return _generator


func _gm_map_baker():
	if _generator != null and "_baker" in _generator:
		return _generator._baker
	return null


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


static func eternal_uv_from_angles(azimuth_deg: float, elevation_deg: float) -> Vector2:
	var elevation := clampf(elevation_deg, 8.0, 85.0)
	var dist := (85.0 - elevation) / 77.0
	var azimuth := deg_to_rad(azimuth_deg)
	# 标记离地图中心越远，太阳越低；标记所在方向就是光线方向（+x 东，+y 北）。
	var offset := Vector2(cos(azimuth), sin(azimuth)) * (dist * 0.5)
	return Vector2(clampf(0.5 + offset.x, 0.0, 1.0), clampf(0.5 + offset.y, 0.0, 1.0))


static func eternal_angles_from_uv(uv: Vector2) -> Vector2:
	var offset := Vector2(clampf(uv.x, 0.0, 1.0) - 0.5, clampf(uv.y, 0.0, 1.0) - 0.5)
	var dist := clampf(offset.length() * 2.0, 0.0, 1.0)
	var elevation := lerpf(85.0, 8.0, dist)
	if offset.length_squared() <= 0.000001:
		return Vector2(0.0, elevation)
	return Vector2(rad_to_deg(atan2(offset.y, offset.x)), elevation)


static func eternal_sun_dir(azimuth_deg: float, elevation_deg: float) -> Vector3:
	var azimuth := deg_to_rad(azimuth_deg)
	var elevation := deg_to_rad(clampf(elevation_deg, 8.0, 85.0))
	var horiz := cos(elevation)
	return Vector3(cos(azimuth) * horiz, sin(azimuth) * horiz, sin(elevation)).normalized()


static func map_screen_to_sun_uv(screen_pos: Vector2, camera_position: Vector2,
		zoom: float, viewport_size: Vector2, bounds: Rect2) -> Vector2:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or zoom <= 0.0:
		return Vector2(0.25, 0.5)
	var world := camera_position + (screen_pos - viewport_size * 0.5) / zoom
	return Vector2(
		fposmod((world.x - bounds.position.x) / bounds.size.x, 1.0),
		clampf((world.y - bounds.position.y) / bounds.size.y, 0.0, 1.0))


static func map_sun_uv_to_screen(uv: Vector2, camera_position: Vector2,
		zoom: float, viewport_size: Vector2, bounds: Rect2) -> Vector2:
	var world := bounds.position + Vector2(
		fposmod(uv.x, 1.0) * bounds.size.x,
		clampf(uv.y, 0.0, 1.0) * bounds.size.y)
	return viewport_size * 0.5 + (world - camera_position) * zoom


func on_season_changed(season_idx: int) -> void:
	_presentation.on_season_changed(self, season_idx)
func on_year_changed(_year_idx: int) -> void:
	_presentation.on_year_changed(self, _year_idx)
func fit_camera(safe_area: Rect2 = Rect2()) -> void:
	_presentation.fit_camera(self, safe_area)
func map_wrap_period_x() -> float:
	if _current_map == null:
		return 0.0
	return HexUtils.wrap_period_x(_current_map.width, hex_size)


## Map cell indices to the world position the player actually sees.
##
## `ref_x` is the camera's x, which picks the copy on the correct side of a
## wrapped map — the same role it plays in PlayerController._cell_display_world.
## Out-of-range indices are dropped rather than clamped: a stale index must
## paint nothing, not paint the closest valid hex.
func cell_display_centers(cells: PackedInt32Array, ref_x: float) -> PackedVector2Array:
	return _presentation.cell_display_centers(self, cells, ref_x)
func synchronize_vision_display_for_save() -> Dictionary:
	var vision := apply_runtime_vision_display()
	if bool(vision.get("ok", false)) and not _vision_dirty_indices.is_empty():
		_service_worker_map_presentation(Time.get_ticks_usec())
	return vision

func _apply_feature_flags() -> void:
	_generation_adapter._apply_feature_flags(self)
func _world_setup_config() -> Dictionary:
	return _generation_adapter._world_setup_config(self)
func _apply_world_setup_base_config() -> void:
	_generation_adapter._apply_world_setup_base_config(self)
func _cmdline_pkmap_path() -> String:
	return _generation_adapter._cmdline_pkmap_path(self)
func _apply_pkmap_override(cfg: MapConfig) -> void:
	_generation_adapter._apply_pkmap_override(self, cfg)
func _load_runtime_climate_profile() -> ClimateProfile:
	return _generation_adapter._load_runtime_climate_profile(self)
func _apply_runtime_climate_profile(generator_ref: MapGenerator) -> void:
	_generation_adapter._apply_runtime_climate_profile(self, generator_ref)
func _apply_mobile_profile_defaults(profile: ClimateProfile, climate_overrides: Dictionary) -> void:
	_generation_adapter._apply_mobile_profile_defaults(self, profile, climate_overrides)
func _init_tod_profile() -> void:
	_generation_adapter._init_tod_profile(self)
func _on_baker_stage_progress(stage: String, fraction: float) -> void:
	_generation_adapter._on_baker_stage_progress(self, stage, fraction)
func _enter_tree() -> void:
	_generation_adapter._enter_tree(self)
	if DisplayServer.get_name() != "headless":
		_connect_presentation_frames()

func _connect_presentation_frames() -> void:
	get_tree().process_frame.connect(_on_presentation_frame_started)
	RenderingServer.frame_post_draw.connect(_on_presentation_frame_drawn)

func _on_presentation_frame_started() -> void:
	_presentation.begin_frame()

func _on_presentation_frame_drawn() -> void:
	_presentation.observe_draw()

func _exit_tree() -> void:
	if get_tree().process_frame.is_connected(_on_presentation_frame_started):
		get_tree().process_frame.disconnect(_on_presentation_frame_started)
	if RenderingServer.frame_post_draw.is_connected(_on_presentation_frame_drawn):
		RenderingServer.frame_post_draw.disconnect(_on_presentation_frame_drawn)
	_generation_adapter._exit_tree(self)
func _loading_visual_step(label: String) -> void:
	_generation_adapter._loading_visual_step(self, label)
func _advance_visual_progress(stage: String, begin: bool = false) -> void:
	_generation_adapter._advance_visual_progress(self, stage, begin)
func _on_renderer_loading_layer_progress(_layer_index: int, _layer_count: int,
		_layer_name: String) -> void:
	_generation_adapter._on_renderer_loading_layer_progress(self, _layer_index, _layer_count, _layer_name)
func _on_annual_report_ready(report_id: int) -> void:
	annual_report_ready.emit(report_id)


func annual_report_status() -> Dictionary:
	return _generation_adapter.annual_report_status(self)
func annual_report_snapshot(report_id: int) -> Dictionary:
	return _generation_adapter.annual_report_snapshot(self, report_id)
func annual_report_history(offset: int = 0, limit: int = 64) -> Dictionary:
	return _generation_adapter.annual_report_history(self, offset, limit)
func mark_annual_report_presented(report_id: int) -> Dictionary:
	return _generation_adapter.mark_annual_report_presented(self, report_id)
func annual_reports_waiting_for_year(year: int) -> bool:
	return _generation_adapter.annual_reports_waiting_for_year(self, year)
func annual_report_catalogs() -> Dictionary:
	return _generation_adapter.annual_report_catalogs(self)
func _player_completed_technology_ids() -> Dictionary:
	return _generation_adapter._player_completed_technology_ids(self)
