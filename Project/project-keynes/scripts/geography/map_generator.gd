class_name MapGenerator
extends "res://scripts/geography/map_generator_simulation_bindings.gd"
func _c() -> ClimateProfile:
	return _get_native_generation_bridge()._c()
func _ocean_daily_wind_period_ticks_for(cp: ClimateProfile) -> int:
	if cp != null and cp.get("ocean_daily_wind_period_ticks") != null:
		return clampi(int(cp.ocean_daily_wind_period_ticks), 1, 60)
	return _OCEAN_DAILY_WIND_PERIOD_TICKS_DEFAULT
func _calendar_days_per_year() -> int:
	return _get_native_generation_bridge()._calendar_days_per_year()
func _season_phase_to_day_of_year(season_phase: float, days_per_year: int = 0) -> int:
	var dpy: int = clampi(days_per_year if days_per_year > 0 else _calendar_days_per_year(), 1, 3660)
	var p: float = fposmod(season_phase, 4.0)
	return clampi(int(floor((p / 4.0) * float(dpy))), 0, dpy - 1)
func _is_annual_log_tick(counter: int) -> bool:
	var dpy: int = _calendar_days_per_year()
	return counter == 1 or (counter > 0 and (counter % dpy) == 0)
func get_weather_system() -> Object:
	return _weather_system
func get_data_core_world():
	return _data_core_world
func get_data_core_world_ext():
	return _data_core_world_ext
func get_gameplay_event_bus() -> Object:
	return _gameplay_event_bus
func _sync_data_core_runtime_terrain_mirror(map: MapData, reason: String) -> Dictionary:
	return _get_native_generation_bridge()._sync_data_core_runtime_terrain_mirror(map, reason)
func mark_runtime_terrain_mirror_dirty() -> void:
	_dc_terrain_mirror_dirty = true
func _climate_views_from_world(cp: ClimateProfile) -> Dictionary:
	return _get_native_generation_bridge()._climate_views_from_world(cp)
func _validate_gdext_method_signature(method_name: String, expected_arg_count: int) -> bool:
	return _get_native_generation_bridge()._validate_gdext_method_signature(method_name, expected_arg_count)
func _capture_trace(message: String) -> void:
	_get_native_generation_bridge()._capture_trace(message)
func _ensure_row_tables(cfg: MapConfig, season: int) -> void:
	_get_native_generation_bridge()._ensure_row_tables(cfg, season)
func generate(cfg: MapConfig, hex_size: float) -> Dictionary:
	return await _get_native_generation_bridge().generate(cfg, hex_size)
func _runtime_register_system(system) -> void:
	if _sus == null or system == null:
		return
	_sus.register_system(system)
func _runtime_build_topology(context: String) -> bool:
	return _get_native_generation_bridge()._runtime_build_topology(context)
func get_economy_facade():
	return _economy_facade
func get_military_facade():
	return _military_facade
func get_military_daily_job():
	return _military_daily_job
func get_military_report() -> Dictionary:
	return _military_facade.report() if _military_facade != null else {"configured": false}
func refresh_military_terrain(day: int = -1) -> Dictionary:
	return _get_map_country_initializer().refresh_military_terrain(day)
func get_country_facade():
	return _country_facade
func get_country_ai_facade():
	return _country_ai_facade
func get_country_report() -> Dictionary:
	return _country_facade.report() if _country_facade != null else {"configured": false}
func get_modifier_facade():
	return _get_map_rules_initializer().get_modifier_facade()
func get_trigger_facade():
	return _get_map_rules_initializer().get_trigger_facade()
func get_effect_facade():
	return _get_map_rules_initializer().get_effect_facade()
func get_ideology_facade():
	return _get_map_rules_initializer().get_ideology_facade()
func get_trigger_report() -> Dictionary:
	return _get_map_rules_initializer().get_trigger_report()
func get_effect_report() -> Dictionary:
	return _get_map_rules_initializer().get_effect_report()
func get_ideology_report() -> Dictionary:
	return _get_map_rules_initializer().get_ideology_report()
func get_modifier_report() -> Dictionary:
	return _get_map_rules_initializer().get_modifier_report()
func apply_runtime_modifier_snapshot(after_generation: int) -> Dictionary:
	return _get_map_rules_initializer().apply_runtime_modifier_snapshot(after_generation)
func get_economy_report() -> Dictionary:
	return _economy_facade.report() if _economy_facade != null else {"configured": false}
func get_economy_perf_report() -> Dictionary:
	return _get_native_generation_bridge().get_economy_perf_report()
func get_runtime_perf_snapshot(detail_level: int = 0) -> Dictionary:
	return _get_native_generation_bridge().get_runtime_perf_snapshot(detail_level)
func runtime_graph_active() -> bool:
	return _runtime_graph_active
func set_runtime_interactive(interactive: bool) -> void:
	_get_map_runtime_bridge().set_runtime_interactive(interactive)
func set_runtime_qos_threaded(interactive: bool) -> Dictionary:
	return _get_map_runtime_bridge().set_runtime_qos_threaded(interactive)
func get_runtime_thread_report() -> Dictionary:
	return _get_map_runtime_bridge().get_runtime_thread_report()
func record_runtime_main_step(day: int, step: StringName) -> void:
	_get_map_runtime_bridge().record_runtime_main_step(day, step)
func get_runtime_control_state() -> Dictionary:
	return _get_map_runtime_bridge().get_runtime_control_state()
func record_runtime_visual_timings(ui_input_to_feedback_ms: float,
		visual_apply_ms: float, gpu_upload_ms: float) -> Dictionary:
	return _get_map_runtime_bridge().record_runtime_visual_timings(
		ui_input_to_feedback_ms, visual_apply_ms, gpu_upload_ms)
func start_runtime_worker(config: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().start_runtime_worker(config)
func poll_runtime_events_snapshot(after_generation: int = 0) -> Dictionary:
	return _get_map_runtime_bridge().poll_runtime_events_snapshot(after_generation)
func set_runtime_clock_threaded(paused: bool, speed_days_per_second: float) -> Dictionary:
	return _get_map_runtime_bridge().set_runtime_clock_threaded(paused, speed_days_per_second)
func capture_runtime_inputs(inputs: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().capture_runtime_inputs(inputs)
func capture_country_worker_inputs() -> Dictionary:
	return _get_map_runtime_bridge().capture_country_worker_inputs()
func get_country_worker_read_view(after_generation: int = 0) -> Dictionary:
	return _get_map_runtime_bridge().get_country_worker_read_view(after_generation)
func service_country_worker_peer_adapter(max_intents: int = 64,
		shadow_replay: bool = true) -> Dictionary:
	return _get_map_runtime_bridge().service_country_worker_peer_adapter(max_intents, shadow_replay)
func get_country_economy_asset_protocol_status() -> Dictionary:
	return _get_map_runtime_bridge().get_country_economy_asset_protocol_status()
func poll_country_economy_asset_request() -> Dictionary:
	return _get_map_runtime_bridge().poll_country_economy_asset_request()
func submit_country_economy_asset_result(result: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().submit_country_economy_asset_result(result)
func submit_runtime_command(command: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().submit_runtime_command(command)
func poll_runtime_commit(after_generation: int = 0, take_days: bool = false) -> Dictionary:
	return _get_map_runtime_bridge().poll_runtime_commit(after_generation, take_days)
func request_runtime_save(request_id: int) -> Dictionary:
	return _get_map_runtime_bridge().request_runtime_save(request_id)
func poll_runtime_save(request_id: int) -> Dictionary:
	return _get_map_runtime_bridge().poll_runtime_save(request_id)
func restore_runtime_bundle(bytes: PackedByteArray,
		external_ecp2: PackedByteArray = PackedByteArray()) -> Dictionary:
	return _get_map_runtime_bridge().restore_runtime_bundle(bytes, external_ecp2)
func request_runtime_stop(preserve_day_boundary: bool = false) -> Dictionary:
	return _get_map_runtime_bridge().request_runtime_stop(preserve_day_boundary)
func set_economy_diagnostics_enabled(enabled: bool) -> void:
	_get_map_runtime_bridge().set_economy_diagnostics_enabled(enabled)
func set_test_economy_bootstrap_enabled(enabled: bool) -> void:
	_get_map_runtime_bridge().set_test_economy_bootstrap_enabled(enabled)
func set_test_economy_population_scale(scale: int) -> void:
	_get_map_runtime_bridge().set_test_economy_population_scale(scale)
func set_save_restore_preparation_enabled(enabled: bool) -> void:
	_get_map_runtime_bridge().set_save_restore_preparation_enabled(enabled)
func prepare_economy_save_restore_runtime() -> Dictionary:
	return _get_map_runtime_bridge().prepare_economy_save_restore_runtime()
func finalize_save_restore_runtime() -> Dictionary:
	return _get_map_runtime_bridge().finalize_save_restore_runtime()
func native_daily_climate_suppressed() -> bool:
	return _data_core_world_ext != null and _data_core_world_ext.climate_main_thread_suppressed()
func set_gameplay_start_config(config: Dictionary) -> void:
	_gameplay_start_context = {"config": config.duplicate(true)} if not config.is_empty() else {}
	_gameplay_start_report.clear()
func gameplay_start_report() -> Dictionary:
	return _gameplay_start_report.duplicate(true)
func consume_continuation_perf_summary() -> Dictionary:
	var out: Dictionary = _continuation_perf_pending.duplicate(true)
	_continuation_perf_pending.clear()
	return out
func _ensure_continuation_perf_pending() -> void:
	_get_map_runtime_bridge()._ensure_continuation_perf_pending()
func _record_continuation_slice(source: String, result: Dictionary, wall_ms: float) -> float:
	return _get_map_runtime_bridge()._record_continuation_slice(source, result, wall_ms)
func _finish_continuation_perf_frame(started_us: int, frame_slices: int,
		frame_max_slice_ms: float, budget_ms: float) -> void:
	_get_map_runtime_bridge()._finish_continuation_perf_frame(started_us, frame_slices, frame_max_slice_ms, budget_ms)
func _continue_economy_inflight(day_index: int) -> void:
	_get_map_runtime_bridge()._continue_economy_inflight(day_index)
func _continue_economy_inflight_impl(day_index: int) -> void:
	_get_map_runtime_bridge()._continue_economy_inflight_impl(day_index)
func _advance_runtime_graph_pulse(day_index: int) -> Dictionary:
	return _get_map_runtime_bridge()._advance_runtime_graph_pulse(day_index)
func _halt_on_economy_fatal(day_index: int, economy_result: Dictionary) -> void:
	_get_map_runtime_bridge()._halt_on_economy_fatal(day_index, economy_result)
func _dispatch_runtime_graph_country_committed() -> void:
	_get_map_runtime_bridge()._dispatch_runtime_graph_country_committed()
func _track_runtime_graph_stall(day_index: int, token_status: int) -> bool:
	return _get_map_runtime_bridge()._track_runtime_graph_stall(day_index, token_status)
func _log_stalled_runtime_graph(day: int) -> void:
	_get_map_runtime_bridge()._log_stalled_runtime_graph(day)
func _day_stall_reason_name(mask: int) -> String:
	return _get_map_runtime_bridge()._day_stall_reason_name(mask)
func _domain_mask_names(mask: int) -> String:
	return _get_map_runtime_bridge()._domain_mask_names(mask)
func _log_stalled_runtime_graph_authority(day: int) -> void:
	_get_map_runtime_bridge()._log_stalled_runtime_graph_authority(day)
func _native_daily_slice_available() -> bool:
	return _data_core_world_ext != null
func _native_daily_missing_slice_report() -> Dictionary:
	return _get_map_runtime_bridge()._native_daily_missing_slice_report()
func _disabled_sea_ice_atlas_report(reason: String) -> Dictionary:
	return _get_map_runtime_bridge()._disabled_sea_ice_atlas_report(reason)
func _cell_facade_cids_of(cell: Object, field: StringName) -> PackedInt32Array:
	return _get_map_runtime_bridge()._cell_facade_cids_of(cell, field)
func _bind_cell_facade_with_cids(cell: Object, facade_on: bool,
		cid_gd: PackedInt32Array, cid_ext: PackedInt32Array) -> bool:
	return _get_map_runtime_bridge()._bind_cell_facade_with_cids(cell, facade_on, cid_gd, cid_ext)
func _setup_sus(map: MapData, world: WorldData, cfg: MapConfig, hex_size: float) -> void:
	await _get_map_runtime_bridge()._setup_sus(map, world, cfg, hex_size)
func get_sus_bootstrap() -> RefCounted:
	return _sus_bootstrap
func get_environment_runtime() -> RefCounted:
	return _get_map_runtime_bridge().get_environment_runtime()
func ensure_environment_runtime(map: MapData, pixel_size: Vector2i = Vector2i.ZERO) -> RefCounted:
	return _get_map_runtime_bridge().ensure_environment_runtime(map, pixel_size)
func environment_runtime_status() -> Dictionary:
	return _get_map_runtime_bridge().environment_runtime_status()
func export_environment_runtime_state() -> Dictionary:
	return _get_map_runtime_bridge().export_environment_runtime_state()
func restore_environment_runtime_state(state: Dictionary) -> Dictionary:
	return _get_map_runtime_bridge().restore_environment_runtime_state(state)
func _hard_effect_ack_chain_due(day: int) -> bool:
	return _get_map_runtime_bridge()._hard_effect_ack_chain_due(day)
func _ack_native_effect_domain_bindings() -> void:
	_get_map_runtime_bridge()._ack_native_effect_domain_bindings()
func _log_stuck_day_barrier(day: int, economy_inflight: bool) -> void:
	_get_map_runtime_bridge()._log_stuck_day_barrier(day, economy_inflight)
func _drain_native_effect_ack_chain(ctx: SusTickContext) -> int:
	return _get_map_runtime_bridge()._drain_native_effect_ack_chain(ctx)
func environment_runtime_step_budgeted(budget_ms: float, max_cells: int = 0, max_pixels: int = 0, max_indices: int = 0, pipeline: StringName = &"ocean") -> Dictionary:
	return _get_map_runtime_bridge().environment_runtime_step_budgeted(budget_ms, max_cells, max_pixels, max_indices, pipeline)
func set_dyn_atlas_upload_stride(p_stride: int) -> void:
	_get_map_runtime_bridge().set_dyn_atlas_upload_stride(p_stride)
func set_enum_atlas_upload_stride(p_stride: int) -> void:
	_get_map_runtime_bridge().set_enum_atlas_upload_stride(p_stride)
func set_world_clock_ref(world_clock_node) -> void:
	_get_map_runtime_bridge().set_world_clock_ref(world_clock_node)
func _native_mode_is_active(cp, field_name: String) -> bool:
	if cp == null or cp.get(field_name) == null:
		return false
	return int(cp.get(field_name)) == 2
func _native_mode_is_shadow(cp, field_name: String) -> bool:
	if cp == null or cp.get(field_name) == null:
		return false
	return int(cp.get(field_name)) == 1
func _apply_temperature_transport_anomaly_knobs(target: Dictionary, tta: Dictionary) -> void:
	for key in tta.keys():
		target[key] = tta[key]
func _valid_runtime_temp_or_baseline(temp_value: float, baseline: float) -> float:
	return baseline if is_nan(temp_value) or is_inf(temp_value) else temp_value
func _consume_native_daily_canal_visual_dirty_cells() -> PackedInt32Array:
	if _data_core_world_ext == null:
		return PackedInt32Array()
	return _data_core_world_ext.consume_canal_visual_dirty_cells()
func _record_native_daily_job_shell_diag(diag: Dictionary) -> void:
	if _diagnostics_bus.get_climate_breakdown().is_empty() or diag.is_empty():
		return
	_diagnostics_bus.merge_climate_breakdown(diag)
func _native_daily_contract_age_days_for(ctx: SusTickContext) -> int:
	if _native_daily_contract_sample_day < 0 or ctx == null:
		return 0
	return maxi(0, int(ctx.day_index) - _native_daily_contract_sample_day)
func _native_daily_reset_contract_round() -> void:
	_native_daily_contract_sample_day = -1
	_native_daily_contract_sample_tick = -1
	_native_daily_contract_warned_over_budget = false
func native_daily_last_result() -> Dictionary:
	return _native_daily_last_result.duplicate()
func native_daily_round_active() -> bool:
	return _native_daily_day_pending or (_native_daily_sim_job != null \
			and bool(_native_daily_sim_job.get("_native_round_active")))
func bio_occupancy_round_active() -> bool:
	return _bio_occupancy_slice_inflight or _bio_occupancy_day_pending
func sus_report_last_tick() -> Dictionary:
	if _sus == null:
		return {}
	return _sus.report_last_tick()
func sus_climate_breakdown() -> Dictionary:
	return _diagnostics_bus.get_climate_breakdown()
func increment_climate_diagnostic_call_count() -> int:
	return _diagnostics_bus.increment_climate_call_count()
func climate_diagnostic_call_count() -> int:
	return _diagnostics_bus.get_climate_call_count()
func did_refresh_climate_run_this_tick() -> bool:
	return _refresh_climate_daily_job != null and _refresh_climate_daily_job.did_run_last_tick()
func last_refresh_climate_slice_ms() -> float:
	if _refresh_climate_daily_job == null:
		return 0.0
	return _refresh_climate_daily_job.last_slice_elapsed_ms()
func sus_weather_breakdown() -> Dictionary:
	return _normalized_weather_breakdown(_diagnostics_bus.get_weather_breakdown())
func merge_weather_job_breakdown(extra: Dictionary) -> void:
	_diagnostics_bus.merge_weather_breakdown(extra)
func has_pending_enum_atlas_upload() -> bool:
	return _enum_atlas_biome_dirty or _enum_atlas_cover_dirty or _enum_atlas_vegetation_dirty
func queue_detail_scatter_changes(changes) -> void:
	if changes == null or not changes.has_method("is_empty") or bool(changes.is_empty()):
		return
	_pending_detail_scatter_change_sets.append(changes.duplicate_set())
func sus_enum_atlas_breakdown() -> Dictionary:
	return _last_enum_atlas_upload_breakdown.duplicate()
func sus_sea_ice_atlas_breakdown() -> Dictionary:
	return _last_sea_ice_atlas_upload_breakdown.duplicate()
func _mark_enum_atlas_dirty(cover_dirty: bool, vegetation_dirty: bool, biome_dirty: bool = false) -> void:
	_enum_atlas_biome_dirty = _enum_atlas_biome_dirty or biome_dirty
	_enum_atlas_cover_dirty = _enum_atlas_cover_dirty or cover_dirty
	_enum_atlas_vegetation_dirty = _enum_atlas_vegetation_dirty or vegetation_dirty
func _season_refresh_edge_pending() -> bool:
	return _last_season_refresh_day != _last_capture_season_refresh_day
func season_refresh_defers_to_capture() -> bool:
	if _data_core_world_ext == null:
		return false
	return bool(get_runtime_thread_report().get("climate_worker_authoritative", false))
func sus_season_refresh_breakdown() -> Dictionary:
	return _last_season_refresh_breakdown.duplicate()
func _mark_climate_daily_round_slots_stale() -> void:
	_climate_daily_round_slots_fresh = false
func _on_modifier_events_available(batch: Dictionary) -> void:
	_get_map_resource_initializer()._on_modifier_events_available(batch)
func _prime_natural_resource_regen_factors(n_cells: int) -> Dictionary:
	return _get_map_resource_initializer()._prime_natural_resource_regen_factors(n_cells)
func _remember_natural_resource_report(report: Dictionary) -> Dictionary:
	_last_natural_resource_report = report.duplicate(true)
	_last_natural_resource_report["_tick_idx"] = _current_fast_tick_idx
	return report
func natural_resource_last_result() -> Dictionary:
	return _last_natural_resource_report.duplicate(true)
func _try_bootstrap_natural_resources_native(map_ref, cfg,
		habitat_arr: PackedByteArray, estuary_strength_arr: PackedFloat32Array) -> bool:
	return _get_map_resource_initializer()._try_bootstrap_natural_resources_native(map_ref, cfg, habitat_arr, estuary_strength_arr)
func _bio_log_food_bits() -> PackedInt32Array:
	return _get_map_resource_initializer()._bio_log_food_bits()
func _bio_carrier_reserve_fields(knobs: Dictionary) -> PackedStringArray:
	return _get_map_resource_initializer()._bio_carrier_reserve_fields(knobs)
func _bio_reserve_field_for(resource_id: String) -> String:
	return _get_map_resource_initializer()._bio_reserve_field_for(resource_id)
func _boot_facade_disabled_for_ab() -> bool:
	return OS.get_environment("PK_BOOT_FACADE_DISABLE").strip_edges() == "1"
func _bootstrap_world_facades(map_ref, cfg) -> bool:
	return _get_map_resource_initializer()._bootstrap_world_facades(map_ref, cfg)
func _knob_signature(knobs: Dictionary) -> int:
	return _get_map_resource_initializer()._knob_signature(knobs)
func run_natural_resource_pass_native(
		map_ref,
		dt_days: int = 1,
		cell_indices: PackedInt32Array = PackedInt32Array(),
		cell_dt_days: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return _get_map_resource_initializer().run_natural_resource_pass_native(map_ref, dt_days, cell_indices, cell_dt_days)
func economy_live_cells() -> PackedInt32Array:
	if _data_core_world_ext != null:
		return _data_core_world_ext.get_economy_live_cells()
	return PackedInt32Array()
func run_natural_resource_pass_scheduled(map_ref, day: int, live_cells: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	return _get_map_resource_initializer().run_natural_resource_pass_scheduled(map_ref, day, live_cells)
func catchup_natural_resources_for_live_cells(day: int) -> Dictionary:
	return _get_map_resource_initializer().catchup_natural_resources_for_live_cells(day)
func dump_climate_daily_round_slots_stats() -> Dictionary:
	return _get_map_resource_initializer().dump_climate_daily_round_slots_stats()
func _run_season_refresh_stage8_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return _get_map_resource_initializer()._run_season_refresh_stage8_gdext(map, _world, season)
func _run_season_refresh_stage11_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage11_gdext(map, _world, _season)
func _build_row_indices_for_gdext(map: MapData, cfg: MapConfig) -> PackedInt32Array:
	return _get_season_refresh_coordinator()._build_row_indices_for_gdext(map, cfg)
func _set_cell_runtime_terrain(map: MapData, cell: HexCell, terrain_id: int,
		sync_axes: bool = false, temperature_for_vegetation: float = -1.0,
		snow_cover: float = -1.0) -> void:
	_get_season_refresh_coordinator()._set_cell_runtime_terrain(map, cell, terrain_id, sync_axes, temperature_for_vegetation, snow_cover)
func _sync_runtime_axes_after_terrain(map: MapData, cell: HexCell, idx: int,
		temperature_for_vegetation: float = -1.0, snow_cover: float = -1.0) -> void:
	_get_season_refresh_coordinator()._sync_runtime_axes_after_terrain(map, cell, idx, temperature_for_vegetation, snow_cover)
func _clear_cell_vegetation_state(map: MapData, cell: HexCell, idx: int = -1) -> void:
	_get_season_refresh_coordinator()._clear_cell_vegetation_state(map, cell, idx)
func _write_runtime_enum_axes_dense(map: MapData) -> int:
	return _get_season_refresh_coordinator()._write_runtime_enum_axes_dense(map)
func _world_ext_u8_component_id(gd_name: StringName) -> int:
	return _get_season_refresh_coordinator()._world_ext_u8_component_id(gd_name)
func _apply_sea_ice_terrain_flips_indexed(map: MapData, indices: PackedInt32Array,
		terrain_values: PackedByteArray, sync_cells: bool = true) -> Dictionary:
	return _get_season_refresh_coordinator()._apply_sea_ice_terrain_flips_indexed(map, indices, terrain_values, sync_cells)
func _build_sea_ice_flip_batch(flip_to_ice_list: PackedInt32Array,
		flip_to_base_list: PackedInt32Array, flip_to_base_terrain: PackedByteArray,
		start: int = 0, end: int = -1) -> Dictionary:
	return _get_season_refresh_coordinator()._build_sea_ice_flip_batch(flip_to_ice_list, flip_to_base_list, flip_to_base_terrain, start, end)
func _build_vegetation_donor_table_for_gdext() -> PackedFloat32Array:
	return _get_season_refresh_coordinator()._build_vegetation_donor_table_for_gdext()
func _build_rain_shadow_jitter_for_gdext(map: MapData) -> PackedFloat32Array:
	return _get_season_refresh_coordinator()._build_rain_shadow_jitter_for_gdext(map)
func _run_season_refresh_stage1_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage1_gdext(map, _world, season)
func _run_season_refresh_stage2_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage2_gdext(map, _world, season)
func _run_season_refresh_stage3_gdext(map: MapData, _world: WorldData, _season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage3_gdext(map, _world, _season)
func _run_season_refresh_stage4_gdext(map: MapData, _world: WorldData, season: int) -> bool:
	return _get_season_refresh_coordinator()._run_season_refresh_stage4_gdext(map, _world, season)
func _ensure_season_knob_geometry_cache(map: MapData, n_cells: int) -> bool:
	return _get_season_refresh_coordinator()._ensure_season_knob_geometry_cache(map, n_cells)
func _build_season_round_knobs(map: MapData, season: int) -> Dictionary:
	return _get_season_refresh_coordinator()._build_season_round_knobs(map, season)
func continue_finish_season_round_b_plus(map: MapData, max_cells: int = 128) -> Dictionary:
	return _get_season_refresh_coordinator().continue_finish_season_round_b_plus(map, max_cells)
func pop_b_plus_round_samples() -> Dictionary:
	return _get_season_refresh_coordinator().pop_b_plus_round_samples()
func soil_arr_size_mismatch(map: MapData) -> bool:
	return _get_season_refresh_coordinator().soil_arr_size_mismatch(map)
func _sync_stage8_facade_fields_from_soa(map: MapData) -> void:
	_get_season_refresh_coordinator()._sync_stage8_facade_fields_from_soa(map)
func sus_report_last_tick_summary() -> Dictionary:
	if _sus == null:
		return {}
	return _sus.report_last_tick_summary()
func sus_report_sim_budget_window() -> Dictionary:
	if _sus == null or not _sus.has_method("report_sim_budget_window"):
		return {}
	return _sus.report_sim_budget_window()
func sus_report_job_stats() -> Dictionary:
	return _get_season_refresh_coordinator().sus_report_job_stats()
func sus_report_skipped_summary() -> Dictionary:
	if _sus == null or not _sus.has_method("report_skipped_summary"):
		return {}
	return _sus.report_skipped_summary()
func _biome_temperature(map: MapData, cell: HexCell, fallback: float) -> float:
	return _get_season_refresh_coordinator()._biome_temperature(map, cell, fallback)
func _biome_moisture(map: MapData, cell: HexCell) -> float:
	return _get_season_refresh_coordinator()._biome_moisture(map, cell)
func _ensure_generation_world_ext() -> RefCounted:
	return _get_native_generation_bridge().ensure_world_ext()
func _native_generation_cfg_dict(cfg: MapConfig) -> Dictionary:
	return _get_native_generation_bridge().native_generation_cfg_dict(cfg)
func _native_generation_profile_dict() -> Dictionary:
	return _get_native_generation_bridge().native_generation_profile_dict()
func queue_season_refresh(season_idx: int) -> void:
	_get_season_refresh_coordinator().queue_season_refresh(season_idx)
func has_pending_season_refresh() -> bool:
	return _get_season_refresh_coordinator().has_pending_season_refresh()
func begin_pending_season_refresh() -> int:
	return _get_season_refresh_coordinator().begin_pending_season_refresh()
func begin_periodic_season_refresh() -> int:
	return _get_season_refresh_coordinator().begin_periodic_season_refresh()
func run_season_refresh_stage(map: MapData, world: WorldData, season_idx: int, stage: int) -> void:
	_get_season_refresh_coordinator().run_season_refresh_stage(map, world, season_idx, stage)
func run_season_refresh_stage_micro(map: MapData, _world: WorldData, season_idx: int, stage: int, cursor: int) -> Dictionary:
	return _get_season_refresh_coordinator().run_season_refresh_stage_micro(map, _world, season_idx, stage, cursor)
func finish_season_refresh(_map: MapData, _world: WorldData, _season_idx: int) -> void:
	_get_season_refresh_coordinator().finish_season_refresh(_map, _world, _season_idx)
func season_round_b_plus_available() -> bool:
	return _get_season_refresh_coordinator().season_round_b_plus_available()
func start_season_round_b_plus(map: MapData, _world: WorldData, season: int) -> int:
	return _get_season_refresh_coordinator().start_season_round_b_plus(map, _world, season)
func run_season_round_slice_b_plus(map: MapData, _world: WorldData, max_usec: int = 0) -> Dictionary:
	return _get_season_refresh_coordinator().run_season_round_slice_b_plus(map, _world, max_usec)
func begin_finish_season_round_b_plus(map: MapData, _world: WorldData, _season: int) -> void:
	_get_season_refresh_coordinator().begin_finish_season_round_b_plus(map, _world, _season)
func _abort_season_round_b_plus_safe() -> void:
	_get_season_refresh_coordinator()._abort_season_round_b_plus_safe()
func refresh_seasonal(map: MapData, world: WorldData, season_idx: int) -> void:
	_get_season_refresh_coordinator().refresh_seasonal(map, world, season_idx)
func _bootstrap_natural_resource_deposits(map_ref, cfg, cooperative: bool = false) -> void:
	await _get_map_resource_initializer()._bootstrap_natural_resource_deposits(map_ref, cfg, cooperative)
func _mapgen_env() -> Dictionary:
	return _get_terrain_generator()._mapgen_env()
func _mapgen_sanitize_report(src: Dictionary, depth: int = 2) -> Dictionary:
	return _get_terrain_generator()._mapgen_sanitize_report(src, depth)
func generation_preflight() -> Dictionary:
	return _get_native_generation_bridge().generation_preflight()
func _fail_generation(stage: String, reason: String, summary: String, hint: String = "") -> Dictionary:
	return _get_terrain_generator()._fail_generation(stage, reason, summary, hint)
func _generation_superseded(stage: String) -> Dictionary:
	return _get_terrain_generator()._generation_superseded(stage)
func last_generation_error_text() -> String:
	return _get_terrain_generator().last_generation_error_text()
func native_generation_base_report() -> Dictionary:
	return _native_generation_base_report
func _mapgen_native_smoke(w: int = 16, h: int = 12) -> Dictionary:
	return _get_native_generation_bridge().native_smoke(w, h)
static func mapgen_selfcheck_requested() -> bool:
	if OS.get_environment("PK_MAPGEN_SELFCHECK") == "1":
		return true
	for arg in OS.get_cmdline_user_args():
		if String(arg) == "--mapgen-selfcheck":
			return true
	for arg in OS.get_cmdline_args():
		if String(arg) == "--mapgen-selfcheck":
			return true
	return false
func run_mapgen_selfcheck(include_native_smoke: bool = true) -> Dictionary:
	return _get_terrain_generator().run_mapgen_selfcheck(include_native_smoke)
func _generate_cells_native_base(cfg: MapConfig, seed: int) -> MapData:
	return await _get_native_generation_bridge().generate_cells_native_base(cfg, seed)
func _init_noise(seed_val: int) -> void:
	_get_terrain_generator()._init_noise(seed_val)
func _alt_penalty_height(height_norm: float) -> float:
	return _get_terrain_generator()._alt_penalty_height(height_norm)
func _land_height_for_temperature(elevation: float, sea_level: float) -> float:
	return clampf((elevation - sea_level) / maxf(1.0 - sea_level, 0.001), 0.0, 1.0)
func _temperature_height_for_penalty(elevation: float, sea_level: float) -> float:
	var land_h: float = _land_height_for_temperature(elevation, sea_level)
	return lerpf(land_h, clampf(elevation, 0.0, 1.0), ALT_PEN_ABS_ELEV_BLEND)
func _alt_penalty(elevation: float, sea_level: float = -1.0) -> float:
	return _get_terrain_generator()._alt_penalty(elevation, sea_level)
func _derived_snow_cover(temp_now: float, land_h: float, terrain: int, cover: int) -> float:
	return _get_terrain_generator()._derived_snow_cover(temp_now, land_h, terrain, cover)
func _compute_temperature(ny: float, elevation: float, sea_level: float = -1.0) -> float:
	var lat_temp: float = DCClimateMath.lat_temp_bell_from_ny(ny)
	var alt_penalty: float = _alt_penalty(elevation, sea_level)
	return clampf(lat_temp - alt_penalty, 0.0, 1.0)
func _bootstrap_sea_ice_fraction(map: MapData, cfg: MapConfig) -> void:
	_get_terrain_generator()._bootstrap_sea_ice_fraction(map, cfg)
func _decide_terrain(elevation: float, temperature: float, moisture: float, cfg: MapConfig, permanent_only: bool = false) -> TerrainType.TERRAIN:
	return _get_terrain_generator()._decide_terrain(elevation, temperature, moisture, cfg, permanent_only)
func _derive_landform(cell: HexCell, cfg: MapConfig) -> int:
	return _get_terrain_generator()._derive_landform(cell, cfg)
func _derive_vegetation(cell: HexCell, landform: int, temperature: float) -> int:
	return _get_terrain_generator()._derive_vegetation(cell, landform, temperature)
func _whittaker_vegetation(temperature: float, moisture: float, landform: int) -> int:
	return _get_terrain_generator()._whittaker_vegetation(temperature, moisture, landform)
func _derive_cover(cell: HexCell, snow_cover: float) -> int:
	return _get_terrain_generator()._derive_cover(cell, snow_cover)
func _sync_axes_for_cell(cell: HexCell, cfg: MapConfig, snow_cover: float, temperature_override: float = -1.0) -> void:
	_get_terrain_generator()._sync_axes_for_cell(cell, cfg, snow_cover, temperature_override)
func _sync_axes_for_map(map: MapData, cfg: MapConfig) -> void:
	for cell: HexCell in map.all_cells():
		_sync_axes_for_cell(cell, cfg, 0.0)
func _compute_ocean_currents(map: MapData, world: WorldData, hex_size: float) -> void:
	_get_terrain_generator()._compute_ocean_currents(map, world, hex_size)
func _compute_terrain_perturbed_wind(map: MapData) -> void:
	_get_terrain_generator()._compute_terrain_perturbed_wind(map)
static func _is_water(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.LAKE \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
		or t == TerrainType.TERRAIN.SEA_ICE
func _generate_static_research_signals(map: MapData) -> void:
	_get_terrain_generator()._generate_static_research_signals(map)
func _append_natural_resource_research_signals(map: MapData) -> void:
	_get_terrain_generator()._append_natural_resource_research_signals(map)
func _bio_occupancy_base_knobs(map_ref: MapData) -> Dictionary:
	return _get_terrain_generator()._bio_occupancy_base_knobs(map_ref)
func _bio_occupancy_daily_knobs(map_ref: MapData) -> Dictionary:
	return _get_terrain_generator()._bio_occupancy_daily_knobs(map_ref)
func _bio_reserve_column(map_ref: MapData, resource_id: String, n: int,
		empty: PackedFloat32Array) -> PackedFloat32Array:
	return _get_terrain_generator()._bio_reserve_column(map_ref, resource_id, n, empty)
func _publish_bio_occupancy_to_runtime(map_ref: MapData) -> void:
	_get_terrain_generator()._publish_bio_occupancy_to_runtime(map_ref)
func _seed_bio_occupancy(map_ref: MapData) -> void:
	_get_terrain_generator()._seed_bio_occupancy(map_ref)
func _log_bio_occupancy_seed_summary(knobs: Dictionary, seed_res: Dictionary,
		landmass_count: int, province_count: int) -> void:
	_get_terrain_generator()._log_bio_occupancy_seed_summary(knobs, seed_res, landmass_count, province_count)
func _log_bio_occupancy_seed(knobs: Dictionary, seed_res: Dictionary, landmass_count: int,
		province_count: int) -> void:
	_get_terrain_generator()._log_bio_occupancy_seed(knobs, seed_res, landmass_count, province_count)
func _log_bio_occupancy_seed_native(report: Dictionary, knobs: Dictionary) -> void:
	_get_terrain_generator()._log_bio_occupancy_seed_native(report, knobs)
func run_bio_occupancy_pass_native(map_ref, run_diffusion: bool = false,
		day_index: int = 0, slice_enabled: bool = false,
		bio_slice_cells: int = BIO_OCCUPANCY_SLICE_CELLS) -> Dictionary:
	return _get_terrain_generator().run_bio_occupancy_pass_native(map_ref, run_diffusion,
		day_index, slice_enabled, bio_slice_cells)
func _resolve_bio_observation_country_handle() -> int:
	if _bio_observation_country_handle == 0 and _country_facade != null:
		var start_cell := int(gameplay_start_report().get("cell", -1))
		if start_cell >= 0:
			_bio_observation_country_handle = int(_country_facade.cell_summary(
				start_cell).get("country_handle", 0))
	return _bio_observation_country_handle
static func _is_permanent_landform(t: int) -> bool:
	return t == TerrainType.TERRAIN.OASIS \
			or t == TerrainType.TERRAIN.DELTA \
			or t == TerrainType.TERRAIN.SALT_FLAT \
			or t == TerrainType.TERRAIN.BADLANDS \
			or t == TerrainType.TERRAIN.CHAPARRAL \
			or t == TerrainType.TERRAIN.MOOR \
			or t == TerrainType.TERRAIN.FLOODPLAIN \
			or t == TerrainType.TERRAIN.MESA
func _cube_to_row(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.y, 0, cfg.height - 1)
func _cube_row_norm(cell: HexCell, cfg: MapConfig) -> float:
	return float(_cube_to_row(cell, cfg)) / float(maxi(cfg.height - 1, 1))
func public_cube_row_norm(cell: HexCell) -> float:
	if _last_cfg == null or cell == null:
		return 0.5
	return _cube_row_norm(cell, _last_cfg)
func _publish_native_generation_from_slots(map: MapData, cfg: MapConfig) -> bool:
	return _get_mapgen_climate_passes_a()._publish_native_generation_from_slots(map, cfg)
func _bake_temp_baseline_year_native(map: MapData) -> void:
	_get_mapgen_climate_passes_a()._bake_temp_baseline_year_native(map)
func _moisture_lat_weight(ny: float) -> float:
	var abs_lat := absf(ny * 2.0 - 1.0)
	var t := clampf((abs_lat - 0.18) / 0.64, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
func refresh_climate_daily(map: MapData, season_phase: float) -> void:
	_get_mapgen_climate_passes_a().refresh_climate_daily(map, season_phase)
func refresh_climate_loading(map: MapData, season_phase: float) -> void:
	await _get_mapgen_climate_passes_a().refresh_climate_loading(map, season_phase)
func _climate_pass_a(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_climate_pass_a_module.run(map, season_phase)
func _climate_pass_b(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_climate_pass_b_module.run(map, season_phase)
func _dump_sea_ice_breakdown_if_slow() -> void:
	_get_mapgen_climate_passes_a()._dump_sea_ice_breakdown_if_slow()
func _dump_weather_breakdown_if_slow() -> void:
	_get_mapgen_climate_passes_a()._dump_weather_breakdown_if_slow()
func _sea_ice_slice_budget_cells() -> int:
	return _get_mapgen_climate_passes_a()._sea_ice_slice_budget_cells()
func _sea_ice_solar_gate_enabled(cp) -> bool:
	return cp != null and cp.get("sea_ice_solar_gate_enabled") != null \
		and bool(cp.sea_ice_solar_gate_enabled)
func _sea_ice_freeze_gate(insolation_now: float, freeze_low: float, freeze_high: float) -> float:
	var hi: float = maxf(freeze_high, freeze_low + 0.001)
	return clampf(1.0 - smoothstep(freeze_low, hi, insolation_now), 0.0, 1.0)
func _sea_ice_insolation_input(map: MapData, cells: Array, season_phase: float) -> PackedFloat32Array:
	return _get_mapgen_climate_passes_a()._sea_ice_insolation_input(map, cells, season_phase)
func _abort_sea_ice_state_machine(reason: String = "abort") -> void:
	_get_mapgen_climate_passes_a()._abort_sea_ice_state_machine(reason)
func _begin_sea_ice_state_machine(map: MapData, season_phase: float, token: int) -> bool:
	return _get_mapgen_climate_passes_a()._begin_sea_ice_state_machine(map, season_phase, token)
func _run_sea_ice_state_machine_slice(map: MapData, season_phase: float, token: int) -> Dictionary:
	return _get_mapgen_climate_passes_a()._run_sea_ice_state_machine_slice(map, season_phase, token)
func _consume_sea_ice_dt_days(max_dt_days: float = 30.0) -> float:
	return _get_mapgen_climate_passes_a()._consume_sea_ice_dt_days(max_dt_days)
func _consume_climate_dt_days() -> float:
	return _get_mapgen_climate_passes_a()._consume_climate_dt_days()
func _consume_weather_dt_days() -> float:
	return _get_mapgen_climate_passes_a()._consume_weather_dt_days()
func _apply_sea_ice_daily_pass(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_sea_ice_daily_pass_module.run(map, season_phase)
func _ocean_water_pass(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_ocean_water_pass_module.run(map, season_phase)
func _ocean_land_pass(map: MapData, season_phase: float) -> void:
	_ensure_daily_pass_modules()
	_ocean_land_pass_module.run(map, season_phase)
func _build_climate_b_foliage_table() -> PackedFloat32Array:
	return _get_mapgen_climate_passes_a()._build_climate_b_foliage_table()
func _begin_ocean_heat_transport_sliced(map: MapData, season_phase: float, cp: ClimateProfile) -> bool:
	return _get_mapgen_climate_passes_a()._begin_ocean_heat_transport_sliced(map, season_phase, cp)
func _ocean_slice_budget_cells() -> int:
	return _get_mapgen_climate_passes_a()._ocean_slice_budget_cells()
func _make_climate_pass_result(pass_type: String, done: bool, elapsed_ms: float, processed_cells: int,
		cursor_start: int, cursor_end: int, status: String = "", token: int = 0,
		stage: String = "", abort_reason: String = "") -> Dictionary:
	return _get_mapgen_climate_passes_a()._make_climate_pass_result(pass_type, done, elapsed_ms, processed_cells, cursor_start, cursor_end, status, token, stage, abort_reason)
func _climate_pass_state_matches(pass_type: String, map: MapData, token: int = 0) -> bool:
	return _get_mapgen_climate_passes_a()._climate_pass_state_matches(pass_type, map, token)
func begin_climate_pass(pass_type: String, map: MapData, season_phase: float, opts: Dictionary = {}) -> Dictionary:
	return _get_mapgen_climate_passes_a().begin_climate_pass(pass_type, map, season_phase, opts)
func abort_climate_pass(pass_type: String, reason: String = "abort") -> Dictionary:
	return _get_mapgen_climate_passes_a().abort_climate_pass(pass_type, reason)
func _abort_all_climate_passes(reason: String = "abort_all") -> void:
	_get_mapgen_climate_passes_a()._abort_all_climate_passes(reason)
func _run_climate_pass_legacy_fallback(pass_type: String, map: MapData, season_phase: float, token: int, reason: String) -> Dictionary:
	push_error("[climate/%s] native failed: slice fallback retired (%s); previous fields retained" % [pass_type, reason])
	return _make_climate_pass_result(pass_type, false, 0.0, 0, -1, -1, _CLIMATE_PASS_STATUS_FAILED, token, pass_type, reason)
func run_climate_pass_slice(pass_type: String, map: MapData, season_phase: float, opts: Dictionary = {}) -> Dictionary:
	return _get_mapgen_climate_passes_a().run_climate_pass_slice(pass_type, map, season_phase, opts)
func run_ocean_water_pass_slice(map: MapData, season_phase: float) -> Dictionary:
	_ensure_daily_pass_modules()
	return _ocean_water_pass_module.run_ocean_water_pass_slice(map, season_phase)
func run_ocean_land_pass_slice(map: MapData, season_phase: float) -> Dictionary:
	_ensure_daily_pass_modules()
	return _ocean_land_pass_module.run_ocean_land_pass_slice(map, season_phase)
func refresh_daily(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	var fronts: Array[WeatherFront] = refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
	refresh_daily_stage_b(map, world)
	return fronts
func publish_weather_lut_after_weather_commit(map: MapData, world: WorldData, native_lut: PackedByteArray = PackedByteArray(), force_changed: bool = false) -> Dictionary:
	return _get_climate_pass_b_module().publish_weather_lut_after_weather_commit(map, world, native_lut, force_changed)
func refresh_weather_daily(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	return _get_climate_pass_b_module().refresh_weather_daily(map, world, season_idx, climate_anomaly, season_phase)
func weather_native_daily_readiness_report() -> Dictionary:
	return _get_climate_pass_b_module().weather_native_daily_readiness_report()
func weather_native_daily_available() -> bool:
	return bool(weather_native_daily_readiness_report().get("ready", false))
func refresh_daily_stage_a(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	return _get_climate_pass_b_module().refresh_daily_stage_a(map, world, season_idx, climate_anomaly, season_phase)
func weather_uses_field_solver() -> bool:
	return _weather_system != null \
		and _weather_system.has_method("uses_weather_field") \
		and bool(_weather_system.uses_weather_field())
func weather_field_slice_cells() -> int:
	return _get_climate_pass_b_module().weather_field_slice_cells()
func begin_weather_refresh_stage_a(map: MapData, world: WorldData, season_idx: int,
		climate_anomaly: float, season_phase: float = -1.0) -> void:
	_get_climate_pass_b_module().begin_weather_refresh_stage_a(map, world, season_idx, climate_anomaly, season_phase)
func run_weather_refresh_stage_a_slice(cell_budget: int) -> Dictionary:
	return _get_climate_pass_b_module().run_weather_refresh_stage_a_slice(cell_budget)
func commit_weather_refresh_stage_a(map: MapData, world: WorldData) -> Array[WeatherFront]:
	return _get_climate_pass_b_module().commit_weather_refresh_stage_a(map, world)
func runtime_hydrology_enabled() -> bool:
	var cp_now := _c()
	return cp_now != null and bool(cp_now.runtime_hydrology_enabled)
func run_hydrology_discharge_pass_native(map: MapData, world: WorldData) -> Dictionary:
	return _get_climate_pass_b_module().run_hydrology_discharge_pass_native(map, world)
func refresh_daily_stage_b(map: MapData, world: WorldData) -> void:
	_get_climate_pass_b_module().refresh_daily_stage_b(map, world)
func active_weather_fronts() -> Array[WeatherFront]:
	if _weather_system == null:
		return [] as Array[WeatherFront]
	return _weather_system.active_fronts()
func set_daily_climate_refresh_stride(s: int) -> void:
	_get_wind_heat_transport().set_daily_climate_refresh_stride(s)
func _build_transpiration_donor_table() -> PackedFloat32Array:
	return _get_wind_heat_transport()._build_transpiration_donor_table()
func _make_transpiration_native_unavailable(reason: String, t_wall_us: int, n_cells: int = 0) -> Dictionary:
	return _get_wind_heat_transport()._make_transpiration_native_unavailable(reason, t_wall_us, n_cells)
func _sync_transpiration_native_outputs(map: MapData, dirty_indices: PackedInt32Array, dirty_values: PackedFloat32Array) -> Dictionary:
	return _get_wind_heat_transport()._sync_transpiration_native_outputs(map, dirty_indices, dirty_values)
func run_transpiration_pass_native(map: MapData) -> Dictionary:
	_ensure_daily_pass_modules()
	return _transpiration_pass_module.run_native(map)
func _build_albedo_donor_table() -> PackedFloat32Array:
	return _get_wind_heat_transport()._build_albedo_donor_table()
func _ensure_vegdyn_lut() -> void:
	_get_wind_heat_transport()._ensure_vegdyn_lut()

func _season_temp_offset(ny: float, season: int) -> float:
	var phase_mid: float = float(season) + 0.5
	return _insolation_season_offset(ny, phase_mid)
func _subsolar_lat_rad(season_phase: float) -> float:
	return _get_wind_heat_transport()._subsolar_lat_rad(season_phase)
func _compute_insolation(ny: float, season_phase: float) -> float:
	return _get_wind_heat_transport()._compute_insolation(ny, season_phase)
func _insolation_annual_mean(ny: float) -> float:
	return _get_wind_heat_transport()._insolation_annual_mean(ny)
func _rebuild_insol_mean_lut() -> void:
	_get_wind_heat_transport()._rebuild_insol_mean_lut()
func _insol_dev(ny: float, season_phase: float) -> float:
	var mean_val: float = _insolation_annual_mean(ny)
	var now_val: float = _compute_insolation(ny, season_phase)
	return clampf(DCClimateMath.compute_insolation_dev_from_values(ny, now_val, mean_val), -1.0, 1.0)
func _insolation_season_offset(ny: float, season_phase: float) -> float:
	return _get_wind_heat_transport()._insolation_season_offset(ny, season_phase)
func month_of_year(season_phase: float) -> Dictionary:
	return _get_wind_heat_transport().month_of_year(season_phase)
func cell_ny(cell: HexCell) -> float:
	if cell == null or _last_cfg == null:
		return 0.5
	return _cube_row_norm(cell, _last_cfg)
func observe_local_month(cell: HexCell, season_phase: float) -> Dictionary:
	return _get_wind_heat_transport().observe_local_month(cell, season_phase)
func _build_native_wind_baseline(map: MapData) -> PackedFloat32Array:
	return _get_wind_heat_transport()._build_native_wind_baseline(map)
func _supports_wind_air_slot_temp() -> bool:
	return _data_core_world_ext != null \
			and bool(_data_core_world_ext.supports_wind_air_slot_temp())
func _publish_wind_heat_native_outputs(map: MapData) -> void:
	_get_wind_heat_transport()._publish_wind_heat_native_outputs(map)
func run_wind_air_mass_pass_native(map: MapData, season_phase: float) -> Dictionary:
	return _get_wind_heat_transport().run_wind_air_mass_pass_native(map, season_phase)
func run_wind_surface_pass_native(map: MapData, season_phase: float) -> Dictionary:
	return _get_wind_heat_transport().run_wind_surface_pass_native(map, season_phase)
func _wind_air_mass_pass(map: MapData, season_phase: float, cooperative: bool = false) -> void:
	await _get_wind_heat_transport()._wind_air_mass_pass(map, season_phase, cooperative)
func _wind_surface_pass(map: MapData, season_phase: float, cooperative: bool = false) -> void:
	await _get_wind_heat_transport()._wind_surface_pass(map, season_phase, cooperative)
func _on_baker_stage_progress(stage: String, fraction: float) -> void:
	var mapped_stage := "encode" if stage == "done" else stage
	bake_progress.emit(mapped_stage, lerpf(0.44, 0.88, clampf(fraction, 0.0, 1.0)))
func _yield_generation_frame():
	return _loading_frames.next_frame()
func run_async_climate_round_bench(pass_name: String = "transp") -> Dictionary:
	return _get_wind_heat_transport().run_async_climate_round_bench(pass_name)
func run_async_climate_round_stage1_bench() -> Dictionary:
	return run_async_climate_round_bench("transp")
func _bench_async_transp(map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	return _get_wind_heat_transport()._bench_async_transp(map, n_cells, cp_f5, report)
func _bench_async_pass_a(map: MapData, n_cells: int, cp_f5: ClimateProfile, report: Dictionary) -> Dictionary:
	return _get_wind_heat_transport()._bench_async_pass_a(map, n_cells, cp_f5, report)
func _busy_wait_poll(timeout_us: int) -> Dictionary:
	return _get_wind_heat_transport()._busy_wait_poll(timeout_us)
func _diff_f32_arrays(a: PackedFloat32Array, b: PackedFloat32Array, n: int) -> Dictionary:
	return _get_wind_heat_transport()._diff_f32_arrays(a, b, n)
func cancel_loading_work() -> void:
	_get_wind_heat_transport().cancel_loading_work()
func _loading_profile_step(label: String) -> void:
	_get_wind_heat_transport()._loading_profile_step(label)
func _loading_tail_stage_for(label: String) -> String:
	return _get_wind_heat_transport()._loading_tail_stage_for(label)
func _emit_loading_tail_progress(label: String) -> void:
	_get_wind_heat_transport()._emit_loading_tail_progress(label)
func _generation_slice_due() -> bool:
	return _get_wind_heat_transport()._generation_slice_due()
func _prepare_season_geometry_cooperative(map: MapData, n: int) -> void:
	await _get_wind_heat_transport()._prepare_season_geometry_cooperative(map, n)
