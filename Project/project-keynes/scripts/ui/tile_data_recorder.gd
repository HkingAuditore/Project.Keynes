# tile_data_recorder.gd
#
# 地块数据录制器 —— 在 fast_tick 末尾把每个地块的 SoA 快照流式写成 CSV。
# 每行 = 一个 tick 的一个 cell。DebugConsole 负责 start / stop 控制；main.gd
# 只转发本 tick 的基础 sample，本类自行从 main.get_current_map() 读取 MapData。
class_name TileDataRecorder
extends RefCounted


const FIXED_COLUMNS: Array = [
	"row_idx",
	"tick_idx",
	"timestamp_ms",
	"was_skipped_day",
	"fps",
	"fast_ms",
	"t_sus_ms",
	"t_render_ms",
	"t_ui_ms",
	"climate_max_temp_delta",
	"climate_p95_temp_delta",
	"climate_p99_temp_delta",
	"climate_preclamp_max_temp_delta",
	"climate_preclamp_p99_temp_delta",
	"climate_temp_delta_gt_005_count",
	"climate_temp_delta_gt_010_count",
	"climate_temp_delta_gt_020_count",
	"climate_temp_delta_clamped_count",
	"climate_max_transport_anomaly",
	"climate_transport_abs_p95",
	"climate_transport_nonzero_ratio",
	"climate_sea_ice_delta_max",
	"climate_precip_p95",
	"climate_slp_delta_p95",
	"climate_wind_delta_p95",
	"climate_ocean_delta_p95",
	"climate_slp_abs_p95",
	"climate_wind_mag_p95",
	"climate_ocean_mag_p95",
	"climate_upwelling_abs_p95",
	"climate_current_pass",
	"climate_partial",
	"climate_progress_ratio",
	"climate_processed_cells",
	"climate_cursor_start",
	"climate_cursor_end",
	"climate_pass_status",
	"climate_pass_stage",
	"climate_pass_substage",
	"climate_pass_path",
	"climate_budget_interrupted",
	"climate_pass_token",
	"weather_dirty_count",
	"water_budget_error",
	"active_weather_ratio",
	"weather_diag_present",
	"weather_field_commit_path",
	"weather_refresh_convergence",
	"weather_field_solve_tick",
	"weather_convergence_refresh_stride",
	"weather_native_convergence_boost",
	"weather_convergence_dirty_count",
	"weather_convergence_delta_p95",
	"weather_convergence_published",
	"weather_target_mismatch_count",
	"weather_transitioning_count",
	"weather_transition_alpha_mean",
	"weather_transition_alpha_p95",
	"climate_thermal_finalizer_applied",
	"phys_phase_locked",
	"phys_diag_tick_idx",
	"phys_sim_day",
	"phys_stage",
	"phys_stage_name",
	"phys_next_stage",
	"phys_next_stage_name",
	"phys_path",
	"phys_done",
	"phys_round_active",
	"phys_physical_round_id",
	"phys_visual_round_active",
	"phys_visual_round_id",
	"phys_visual_pending_commit",
	"phys_visual_lag_ticks",
	"phys_visual_pixel_progress",
	"phys_visual_next_pixel_idx",
	"phys_visual_total_pixels",
	"phys_pending_commit",
	"phys_need_pixel",
	"phys_run_ocean",
	"phys_phase_int_seen",
	"phys_ticks_per_slice",
	"phys_wind_period_ticks",
	"phys_ocean_period_ticks",
	"phys_slice_count",
	"phys_next_pixel_idx",
	"phys_total_pixels",
	"phys_pixel_quota",
	"phys_progress_ratio",
	"phys_processed_pixels",
	"phys_cursor_start",
	"phys_cursor_end",
	"phys_raster_requested_start",
	"phys_raster_requested_end",
	"phys_raster_returned_start",
	"phys_raster_returned_end",
	"phys_raster_pixels",
	"phys_raster_wall_ms",
	"phys_raster_native_ms",
	"phys_raster_used_cpp",
	"phys_raster_atlas_updated",
	"phys_raster_fallback_reason",
	"phys_raster_progress_guard_fired",
	"phys_slp_path",
	"phys_slp_native_ms",
	"phys_slp_rc_ms",
	"phys_slp_out_size",
	"phys_slp_published_to_slot",
	"phys_slp_commit_ok",
	"phys_slp_thermal_p95",
	"phys_slp_delta_p95",
	"phys_wind_cpp_done",
	"phys_wind_rc_ms",
	"phys_wind_wx_size",
	"phys_wind_wy_size",
	"phys_wind_speed_out_size",
	"phys_wind_map_speed_size",
	"phys_wind_commit_ok",
	"phys_wind_delta_p95",
	"phys_daily_wind_due",
	"phys_daily_wind_tick_idx",
	"phys_daily_wind_season_phase",
	"phys_daily_wind_ran",
	"phys_daily_wind_path",
	"phys_daily_wind_elapsed_ms",
	"phys_daily_wind_refresh_ms",
	"phys_daily_wind_slp_ms",
	"phys_daily_wind_wind_ms",
	"phys_daily_wind_fallback_reason",
	"phys_daily_wind_slp_commit_ok",
	"phys_daily_wind_wind_commit_ok",
	"phys_daily_wind_wind_cpp_done",
	"phys_daily_wind_slp_published_to_slot",
	"phys_daily_wind_slp_delta_p95",
	"phys_daily_wind_delta_p95",
	"phys_psi_path",
	"phys_psi_native_ms",
	"phys_ocean_delta_p95",
	"phys_thermal_current_p95",
	"phys_ocean_current_preclamp_p95",
	"phys_ocean_current_preclamp_max",
	"phys_ocean_current_clamp_count",
	"phys_ocean_current_clamp_ratio",
	"phys_ocean_current_max_magnitude",
	"cell_index",
	"q",
	"r",
	"s",
]

# MapData 上所有 cell-count 长度的 SoA 候选。start 时会按当前 cell_count 过滤；
# 例如 demo_thermal_gradient_arr 在未启用时 size=0，不会进入本次 CSV header。
const SOA_FIELD_CANDIDATES: Array = [
	"temp_arr",
	"temp_arr_prev",
	"moisture_arr",
	"moisture_arr_prev",
	"snow_cover_arr",
	"snow_cover_arr_prev",
	"temp_baseline_arr",
	"temp_30d_arr",
	"temp_365d_arr",
	"temp_anomaly_arr",
	"sea_ice_frac_arr",
	"sea_ice_frac_arr_prev",
	"weather_intensity_arr",
	"weather_cloud_arr",
	"weather_cloud_water_arr",
	"weather_precip_arr",
	"weather_transition_alpha_arr",
	"weather_classification_temp_arr",
	"weather_classification_moisture_arr",
	"weather_vapor_arr",
	"weather_convergence_arr",
	"weather_instability_arr",
	"weather_field_init_arr",
	"air_mass_temp_anomaly_arr",
	"has_river_arr",
	"hydro_parent_arr",
	"river_discharge_arr",
	"river_discharge_30d_arr",
	"river_storage_arr",
	"groundwater_storage_arr",
	"surface_runoff_arr",
	"ema_initialized_arr",
	"temp_season_offset_arr",
	"insolation_now_arr",
	"insolation_dev_arr",
	"day_length_arr",
	"heat_input_arr",
	"thermal_energy_arr",
	"snowpack_arr",
	"water_balance_30d_arr",
	"vegetation_vitality_arr",
	"vitality_low_streak_arr",
	"vitality_high_streak_arr",
	"soil_moisture_arr",
	"vegetation_growth_pressure_arr",
	"temperature_transport_anomaly_arr",
	"vegetation_heat_stress_arr",
	"vegetation_drought_stress_arr",
	"vegetation_cold_stress_arr",
	"vegetation_regen_score_arr",
	"demo_thermal_gradient_arr",
	"elevation_arr",
	"base_moisture_arr",
	"ocean_current_x_arr",
	"ocean_current_y_arr",
	"wind_x_arr",
	"wind_y_arr",
	"slp_arr",
	"wind_speed_arr",
	"upwelling_strength_arr",
	"wind_stress_curl_arr",
	"ocean_psi_arr",
	"cell_pos_x_arr",
	"cell_pos_y_arr",
	"cell_lat_norm_arr",
	"temp_baseline_year_arr",
	"terrain_arr",
	"landform_arr",
	"vegetation_arr",
	"base_terrain_arr",
	"base_landform_arr",
	"base_vegetation_arr",
	"cover_arr",
	"weather_type_arr",
	"weather_prev_type_arr",
	"weather_target_type_arr",
	"is_water_arr",
	"climate_dirty_mask",
	"weather_dirty_mask",
]

const EXPORT_DIR_RELATIVE: String = "../../tmp"
const HARD_ROW_LIMIT: int = 5000000
const DEFAULT_TICK_STRIDE: int = 1
const DEFAULT_CELL_STRIDE: int = 1
const BATCH_LINE_LIMIT: int = 2048
const DEFAULT_COMPACT_FIELDS: bool = false

# Optional compact preset for targeted investigations. The default remains full
# fidelity: every recorded tick, every cell, and every available SoA field.
const COMPACT_SOA_FIELD_CANDIDATES: Array = [
	"temp_arr",
	"moisture_arr",
	"sea_ice_frac_arr",
	"weather_precip_arr",
	"weather_transition_alpha_arr",
	"air_mass_temp_anomaly_arr",
	"temperature_transport_anomaly_arr",
	"ocean_current_x_arr",
	"ocean_current_y_arr",
	"wind_x_arr",
	"wind_y_arr",
	"slp_arr",
	"wind_speed_arr",
	"upwelling_strength_arr",
	"terrain_arr",
	"landform_arr",
	"vegetation_arr",
	"weather_type_arr",
	"weather_target_type_arr",
	"is_water_arr",
	"climate_dirty_mask",
	"weather_dirty_mask",
]


var _main = null
var _recording: bool = false
var _hit_limit: bool = false
var _row_count: int = 0
var _tick_count: int = 0
var _start_tick: int = 0
var _map_ref = null
var _cell_count: int = 0
var _columns: PackedStringArray = PackedStringArray()
var _soa_fields: PackedStringArray = PackedStringArray()
var _file: FileAccess = null
var _path: String = ""
var _tick_stride: int = DEFAULT_TICK_STRIDE
var _cell_stride: int = DEFAULT_CELL_STRIDE
var _max_rows: int = HARD_ROW_LIMIT
var _compact_fields: bool = DEFAULT_COMPACT_FIELDS
var _recorded_tick_count: int = 0
var _skipped_tick_count: int = 0
var _last_tick_ms: float = 0.0
var _last_tick_rows: int = 0
var _line_batch: PackedStringArray = PackedStringArray()
var _cell_q_arr: PackedInt32Array = PackedInt32Array()
var _cell_r_arr: PackedInt32Array = PackedInt32Array()
var _cell_s_arr: PackedInt32Array = PackedInt32Array()
var _soa_field_types: PackedInt32Array = PackedInt32Array()
var _csv_encoder_ext = null
var _last_tick_collect_ms: float = 0.0
var _last_tick_stats_ms: float = 0.0
var _last_tick_format_ms: float = 0.0
var _last_tick_flush_ms: float = 0.0
var _last_tick_encoder_path: String = "gdscript"


func bind_main(m) -> void:
	_main = m


func is_recording() -> bool:
	return _recording


func row_count() -> int:
	return _row_count


func tick_count() -> int:
	return _tick_count


func recorded_tick_count() -> int:
	return _recorded_tick_count


func skipped_tick_count() -> int:
	return _skipped_tick_count


func hit_limit() -> bool:
	return _hit_limit


func last_tick_ms() -> float:
	return _last_tick_ms


func sampling_summary() -> Dictionary:
	return {
		"tick_stride": _tick_stride,
		"cell_stride": _cell_stride,
		"max_rows": _max_rows,
		"compact_fields": _compact_fields,
		"last_tick_ms": _last_tick_ms,
		"last_tick_rows": _last_tick_rows,
		"last_tick_collect_ms": _last_tick_collect_ms,
		"last_tick_stats_ms": _last_tick_stats_ms,
		"last_tick_format_ms": _last_tick_format_ms,
		"last_tick_flush_ms": _last_tick_flush_ms,
		"last_tick_encoder_path": _last_tick_encoder_path,
		"recorded_ticks": _recorded_tick_count,
		"skipped_ticks": _skipped_tick_count,
	}


func set_sampling_config(tick_stride: int = DEFAULT_TICK_STRIDE,
		cell_stride: int = DEFAULT_CELL_STRIDE,
		max_rows: int = HARD_ROW_LIMIT,
		compact_fields: bool = DEFAULT_COMPACT_FIELDS) -> void:
	if _recording:
		push_warning("[tile-data-record] sampling config ignored while recording")
		return
	_tick_stride = maxi(1, tick_stride)
	_cell_stride = maxi(1, cell_stride)
	_max_rows = clampi(max_rows, 1, HARD_ROW_LIMIT)
	_compact_fields = compact_fields


func start() -> void:
	_close_file()
	_recording = false
	_hit_limit = false
	_row_count = 0
	_tick_count = 0
	_recorded_tick_count = 0
	_skipped_tick_count = 0
	_last_tick_ms = 0.0
	_last_tick_rows = 0
	_last_tick_collect_ms = 0.0
	_last_tick_stats_ms = 0.0
	_last_tick_format_ms = 0.0
	_last_tick_flush_ms = 0.0
	_last_tick_encoder_path = "gdscript"
	_line_batch.clear()
	_cell_q_arr = PackedInt32Array()
	_cell_r_arr = PackedInt32Array()
	_cell_s_arr = PackedInt32Array()
	_soa_field_types = PackedInt32Array()
	_csv_encoder_ext = null
	_path = ""

	var map_data = _current_map()
	if map_data == null:
		push_warning("[tile-data-record] start failed: current map is null")
		return
	if map_data.has_method("has_soa") and not bool(map_data.has_soa()):
		push_warning("[tile-data-record] start failed: MapData SoA is not built")
		return
	if not map_data.has_method("cell_count") or not map_data.has_method("cell_at"):
		push_warning("[tile-data-record] start failed: MapData API missing")
		return

	_cell_count = int(map_data.cell_count())
	if _cell_count <= 0:
		push_warning("[tile-data-record] start failed: no cells")
		return

	_cell_q_arr.resize(_cell_count)
	_cell_r_arr.resize(_cell_count)
	_cell_s_arr.resize(_cell_count)
	for idx in range(_cell_count):
		var cell = map_data.cell_at(idx)
		if cell == null:
			push_warning("[tile-data-record] start failed: null cell at index %d" % idx)
			_cell_q_arr = PackedInt32Array()
			_cell_r_arr = PackedInt32Array()
			_cell_s_arr = PackedInt32Array()
			return
		_cell_q_arr[idx] = int(cell.q)
		_cell_r_arr[idx] = int(cell.r)
		_cell_s_arr[idx] = int(cell.s)

	_soa_fields = _collect_soa_fields(map_data, _cell_count, _compact_fields)
	if _soa_fields.is_empty():
		push_warning("[tile-data-record] start failed: no cell-level SoA fields found")
		return
	_soa_field_types.resize(_soa_fields.size())
	for i in range(_soa_fields.size()):
		_soa_field_types[i] = typeof(map_data.get(_soa_fields[i]))

	_columns = PackedStringArray()
	for c in FIXED_COLUMNS:
		_columns.append(str(c))
	for f in _soa_fields:
		_columns.append(f)

	var export_dir: String = _export_dir_absolute()
	DirAccess.make_dir_recursive_absolute(export_dir)
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	_path = export_dir.path_join("tile_data_record_%04d%02d%02d_%02d%02d%02d.csv" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
	])

	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file == null:
		var err: int = FileAccess.get_open_error()
		push_error("[tile-data-record] open failed path=%s err=%d" % [_path, err])
		_path = ""
		return

	_file.store_8(0xEF)
	_file.store_8(0xBB)
	_file.store_8(0xBF)
	_file.store_line(_format_header_line(_columns))
	_csv_encoder_ext = _discover_csv_encoder_ext()

	_map_ref = map_data
	if _main != null and _main.has_method("get_fast_tick_count"):
		_start_tick = int(_main.get_fast_tick_count())
	else:
		_start_tick = 0
	_recording = true
	print("[tile-data-record] start cells=%d soa_cols=%d tick_stride=%d cell_stride=%d max_rows=%d compact=%s start_tick=%d path=%s" % [
		_cell_count, _soa_fields.size(), _tick_stride, _cell_stride, _max_rows,
		str(_compact_fields), _start_tick, _path,
	])


func stop_and_export() -> String:
	var out_path: String = _path
	_recording = false
	_flush_line_batch()
	_close_file()
	if _row_count <= 0:
		print("[tile-data-record] stop: no rows captured")
		return ""
	print("[tile-data-record] exported seen_ticks=%d recorded_ticks=%d skipped_ticks=%d rows=%d cols=%d -> %s%s" % [
		_tick_count, _recorded_tick_count, _skipped_tick_count, _row_count,
		_columns.size(), out_path,
		"  (HIT LIMIT)" if _hit_limit else "",
	])
	return out_path


func on_fast_tick(sample: Dictionary) -> Dictionary:
	var t_tick_us0: int = Time.get_ticks_usec()
	_last_tick_rows = 0
	_last_tick_collect_ms = 0.0
	_last_tick_stats_ms = 0.0
	_last_tick_format_ms = 0.0
	_last_tick_flush_ms = 0.0
	_last_tick_encoder_path = "gdscript"
	if not _recording or _file == null:
		return {"recorded": false, "rows": 0, "reason": "not_recording"}
	if _hit_limit:
		return {"recorded": false, "rows": 0, "reason": "hit_limit"}
	_tick_count += 1

	var global_tick: int = int(sample.get("tick_idx", _start_tick + _tick_count))
	var local_tick: int = maxi(0, global_tick - _start_tick)
	if _tick_stride > 1 and (local_tick % _tick_stride) != 0:
		_skipped_tick_count += 1
		_last_tick_ms = (Time.get_ticks_usec() - t_tick_us0) / 1000.0
		return {
			"recorded": false,
			"rows": 0,
			"reason": "tick_stride",
			"tick_stride": _tick_stride,
			"cell_stride": _cell_stride,
		}

	var map_data = _current_map()
	if map_data == null:
		_abort_recording("current map became null")
		return {"recorded": false, "rows": 0, "reason": "map_null"}
	if map_data != _map_ref:
		_abort_recording("map changed during recording")
		return {"recorded": false, "rows": 0, "reason": "map_changed"}
	if not map_data.has_method("cell_count") or int(map_data.cell_count()) != _cell_count:
		_abort_recording("cell_count changed during recording")
		return {"recorded": false, "rows": 0, "reason": "cell_count_changed"}
	if map_data.has_method("has_soa") and not bool(map_data.has_soa()):
		_abort_recording("MapData SoA became unavailable")
		return {"recorded": false, "rows": 0, "reason": "soa_unavailable"}

	var sampled_rows: int = int(ceil(float(_cell_count) / float(_cell_stride)))
	if _row_count + sampled_rows > _max_rows:
		_hit_limit = true
		_recording = false
		_flush_line_batch()
		_close_file()
		push_warning("[tile-data-record] hit row limit (%d), auto-stopped before writing a partial tick." % _max_rows)
		return {"recorded": false, "rows": 0, "reason": "row_limit"}

	var t_collect_us0: int = Time.get_ticks_usec()
	var arrays: Array = []
	arrays.resize(_soa_fields.size())
	for field_i in range(_soa_fields.size()):
		var field: String = _soa_fields[field_i]
		var arr = map_data.get(field)
		if _array_size(arr) != _cell_count:
			_abort_recording("SoA field changed size: %s" % field)
			return {"recorded": false, "rows": 0, "reason": "soa_size_changed"}
		arrays[field_i] = arr
	_last_tick_collect_ms = (Time.get_ticks_usec() - t_collect_us0) / 1000.0

	var t_stats_us0: int = Time.get_ticks_usec()
	var climate: Dictionary = sample.get("climate", {})
	var precip_arr = map_data.get("weather_precip_arr")
	if _array_size(precip_arr) == _cell_count:
		climate["precip_p95"] = _packed_float_p95(precip_arr)
	var physical_stats: Dictionary = _physical_field_stats(map_data)
	for key in physical_stats.keys():
		climate[key] = physical_stats[key]
	sample["climate"] = climate
	var weather: Dictionary = sample.get("weather", {})
	var transition_stats: Dictionary = _weather_transition_stats(map_data)
	for key in transition_stats.keys():
		weather[key] = transition_stats[key]
	sample["weather"] = weather
	_last_tick_stats_ms = (Time.get_ticks_usec() - t_stats_us0) / 1000.0
	var first_cell = map_data.cell_at(0)
	if first_cell == null:
		_abort_recording("cell 0 became null during recording")
		return {"recorded": false, "rows": 0, "reason": "cell_null"}
	var fixed_suffix: String = _tick_fixed_suffix(sample, first_cell)

	var t_format_us0: int = Time.get_ticks_usec()
	if _try_write_native_csv_rows(fixed_suffix, arrays):
		_last_tick_encoder_path = "gdext"
		_last_tick_format_ms = (Time.get_ticks_usec() - t_format_us0) / 1000.0 - _last_tick_flush_ms
		if _last_tick_format_ms < 0.0:
			_last_tick_format_ms = 0.0
	else:
		_last_tick_encoder_path = "gdscript"
		for idx in range(0, _cell_count, _cell_stride):
			_line_batch.append(_format_record_line(
				_row_count,
				fixed_suffix,
				idx,
				_cell_q_arr[idx],
				_cell_r_arr[idx],
				_cell_s_arr[idx],
				arrays,
				_soa_field_types
			))
			_row_count += 1
			_last_tick_rows += 1
			if _line_batch.size() >= BATCH_LINE_LIMIT:
				_last_tick_flush_ms += _flush_line_batch()
		_last_tick_format_ms = (Time.get_ticks_usec() - t_format_us0) / 1000.0 - _last_tick_flush_ms
		if _last_tick_format_ms < 0.0:
			_last_tick_format_ms = 0.0
	_recorded_tick_count += 1
	_last_tick_ms = (Time.get_ticks_usec() - t_tick_us0) / 1000.0
	return {
		"recorded": true,
		"rows": _last_tick_rows,
		"reason": "",
		"elapsed_ms": _last_tick_ms,
		"collect_ms": _last_tick_collect_ms,
		"stats_ms": _last_tick_stats_ms,
		"format_ms": _last_tick_format_ms,
		"flush_ms": _last_tick_flush_ms,
		"encoder_path": _last_tick_encoder_path,
		"tick_stride": _tick_stride,
		"cell_stride": _cell_stride,
	}


static func _export_dir_absolute() -> String:
	return ProjectSettings.globalize_path("res://").path_join(EXPORT_DIR_RELATIVE).simplify_path()


static func _collect_soa_fields(map_data, cell_count: int, compact_fields: bool = DEFAULT_COMPACT_FIELDS) -> PackedStringArray:
	var fields: PackedStringArray = PackedStringArray()
	var candidates: Array = COMPACT_SOA_FIELD_CANDIDATES if compact_fields else SOA_FIELD_CANDIDATES
	for name in candidates:
		var field: String = str(name)
		var arr = map_data.get(field)
		if _array_size(arr) == cell_count:
			fields.append(field)
	return fields


func _current_map():
	if _main == null or not _main.has_method("get_current_map"):
		return null
	return _main.get_current_map()


func _discover_csv_encoder_ext():
	if _main == null or not _main.has_method("get_generator"):
		return null
	var gen = _main.get_generator()
	if gen == null or not gen.has_method("get_data_core_world_ext"):
		return null
	var ext = gen.get_data_core_world_ext()
	if ext != null and ext.has_method("encode_tile_csv_rows"):
		return ext
	return null


func _try_write_native_csv_rows(fixed_suffix: String, arrays: Array) -> bool:
	if _csv_encoder_ext == null or _file == null:
		return false
	if not _csv_encoder_ext.has_method("encode_tile_csv_rows"):
		_csv_encoder_ext = null
		return false
	var rows: int = int(ceil(float(_cell_count) / float(_cell_stride)))
	if rows <= 0:
		return false
	var encoded = _csv_encoder_ext.call("encode_tile_csv_rows", {
		"row_start": _row_count,
		"fixed_suffix": fixed_suffix,
		"cell_start": 0,
		"cell_count": _cell_count,
		"cell_stride": _cell_stride,
		"q_arr": _cell_q_arr,
		"r_arr": _cell_r_arr,
		"s_arr": _cell_s_arr,
		"arrays": arrays,
	})
	if not (encoded is PackedByteArray):
		return false
	var buf: PackedByteArray = encoded
	if buf.is_empty():
		return false
	var t_flush_us0: int = Time.get_ticks_usec()
	_flush_line_batch()
	_file.store_buffer(buf)
	_last_tick_flush_ms += (Time.get_ticks_usec() - t_flush_us0) / 1000.0
	_row_count += rows
	_last_tick_rows = rows
	return true


func _base_row(sample: Dictionary, idx: int, cell) -> Dictionary:
	var climate: Dictionary = sample.get("climate", {})
	var pass_diag: Dictionary = climate.get("pass_diag", {})
	var weather: Dictionary = sample.get("weather", {})
	var phys: Dictionary = sample.get("ocean_currents", {})
	return {
		"row_idx": _row_count,
		"tick_idx": int(sample.get("tick_idx", 0)),
		"timestamp_ms": int(sample.get("timestamp_ms", 0)),
		"was_skipped_day": bool(sample.get("was_skipped_day", false)),
		"fps": int(sample.get("fps", 0)),
		"fast_ms": float(sample.get("fast_ms", 0.0)),
		"t_sus_ms": float(sample.get("t_sus_ms", 0.0)),
		"t_render_ms": float(sample.get("t_render_ms", 0.0)),
		"t_ui_ms": float(sample.get("t_ui_ms", 0.0)),
		"climate_max_temp_delta": float(climate.get("max_temp_delta", 0.0)),
		"climate_p95_temp_delta": float(climate.get("p95_temp_delta", 0.0)),
		"climate_p99_temp_delta": float(climate.get("p99_temp_delta", 0.0)),
		"climate_preclamp_max_temp_delta": float(climate.get("preclamp_max_temp_delta", 0.0)),
		"climate_preclamp_p99_temp_delta": float(climate.get("preclamp_p99_temp_delta", 0.0)),
		"climate_temp_delta_gt_005_count": int(climate.get("temp_delta_gt_005_count", 0)),
		"climate_temp_delta_gt_010_count": int(climate.get("temp_delta_gt_010_count", 0)),
		"climate_temp_delta_gt_020_count": int(climate.get("temp_delta_gt_020_count", 0)),
		"climate_temp_delta_clamped_count": int(climate.get("temp_delta_clamped_count", 0)),
		"climate_max_transport_anomaly": float(climate.get("max_transport_anomaly", 0.0)),
		"climate_transport_abs_p95": float(climate.get("transport_abs_p95", 0.0)),
		"climate_transport_nonzero_ratio": float(climate.get("transport_nonzero_ratio", 0.0)),
		"climate_sea_ice_delta_max": float(climate.get("sea_ice_delta_max", 0.0)),
		"climate_precip_p95": float(climate.get("precip_p95", 0.0)),
		"climate_slp_delta_p95": float(climate.get("slp_delta_p95", 0.0)),
		"climate_wind_delta_p95": float(climate.get("wind_delta_p95", 0.0)),
		"climate_ocean_delta_p95": float(climate.get("ocean_delta_p95", 0.0)),
		"climate_slp_abs_p95": float(climate.get("slp_abs_p95", 0.0)),
		"climate_wind_mag_p95": float(climate.get("wind_mag_p95", 0.0)),
		"climate_ocean_mag_p95": float(climate.get("ocean_mag_p95", 0.0)),
		"climate_upwelling_abs_p95": float(climate.get("upwelling_abs_p95", 0.0)),
		"climate_current_pass": str(climate.get("current_pass", "")),
		"climate_partial": bool(climate.get("partial", false)),
		"climate_progress_ratio": float(climate.get("progress_ratio", 0.0)),
		"climate_processed_cells": int(climate.get("processed_cells", 0)),
		"climate_cursor_start": int(climate.get("cursor_start", -1)),
		"climate_cursor_end": int(climate.get("cursor_end", -1)),
		"climate_pass_status": str(climate.get("pass_status", "")),
		"climate_pass_stage": str(pass_diag.get("stage", "")),
		"climate_pass_substage": str(pass_diag.get("substage", "")),
		"climate_pass_path": str(pass_diag.get("path", climate.get("path", ""))),
		"climate_budget_interrupted": bool(climate.get("budget_interrupted", pass_diag.get("budget_interrupted", false))),
		"climate_pass_token": int(climate.get("pass_token", pass_diag.get("token", 0))),
		"weather_dirty_count": int(weather.get("weather_dirty_count", climate.get("weather_dirty_count", 0))),
		"water_budget_error": float(weather.get("water_budget_error", climate.get("water_budget_error", 0.0))),
		"active_weather_ratio": float(weather.get("active_weather_ratio", climate.get("active_weather_ratio", 0.0))),
		"weather_diag_present": not weather.is_empty(),
		"weather_field_commit_path": str(weather.get("field_commit_path", "")),
		"weather_refresh_convergence": bool(weather.get("refresh_convergence", false)),
		"weather_field_solve_tick": int(weather.get("field_solve_tick", -1)),
		"weather_convergence_refresh_stride": int(weather.get("field_convergence_refresh_stride", 0)),
		"weather_native_convergence_boost": bool(weather.get("native_convergence_boost", false)),
		"weather_convergence_dirty_count": int(weather.get("weather_convergence_dirty_count", 0)),
		"weather_convergence_delta_p95": float(weather.get("weather_convergence_delta_p95", 0.0)),
		"weather_convergence_published": bool(weather.get("convergence_published", false)),
		"weather_target_mismatch_count": int(weather.get("target_mismatch_count", 0)),
		"weather_transitioning_count": int(weather.get("transitioning_count", 0)),
		"weather_transition_alpha_mean": float(weather.get("transition_alpha_mean", 0.0)),
		"weather_transition_alpha_p95": float(weather.get("transition_alpha_p95", 0.0)),
		"climate_thermal_finalizer_applied": bool(climate.get("thermal_finalizer_applied", false)),
		"phys_phase_locked": float(phys.get("phase_locked", phys.get("season_phase", 0.0))),
		"phys_diag_tick_idx": int(phys.get("tick_idx", -1)),
		"phys_sim_day": int(phys.get("sim_day", -1)),
		"phys_stage": int(phys.get("stage", phys.get("phys_stage", -1))),
		"phys_stage_name": str(phys.get("stage_name", phys.get("phys_stage_name", ""))),
		"phys_next_stage": int(phys.get("next_stage", -1)),
		"phys_next_stage_name": str(phys.get("next_stage_name", "")),
		"phys_path": str(phys.get("path", "")),
		"phys_done": bool(phys.get("done", false)),
		"phys_round_active": bool(phys.get("phys_round_active", phys.get("round_active", false))),
		"phys_physical_round_id": int(phys.get("physical_round_id", 0)),
		"phys_visual_round_active": bool(phys.get("visual_round_active", false)),
		"phys_visual_round_id": int(phys.get("visual_round_id", 0)),
		"phys_visual_pending_commit": bool(phys.get("visual_pending_commit", phys.get("pending_commit", false))),
		"phys_visual_lag_ticks": int(phys.get("visual_lag_ticks", 0)),
		"phys_visual_pixel_progress": float(phys.get("visual_pixel_progress", 1.0)),
		"phys_visual_next_pixel_idx": int(phys.get("visual_next_pixel_idx", phys.get("next_pixel_idx", 0))),
		"phys_visual_total_pixels": int(phys.get("visual_total_pixels", phys.get("total_pixels", 0))),
		"phys_pending_commit": bool(phys.get("pending_commit", phys.get("visual_pending_commit", false))),
		"phys_need_pixel": bool(phys.get("need_pixel", false)),
		"phys_run_ocean": bool(phys.get("run_ocean", false)),
		"phys_phase_int_seen": int(phys.get("phase_int_seen", -9999)),
		"phys_ticks_per_slice": int(phys.get("ticks_per_slice", 0)),
		"phys_wind_period_ticks": int(phys.get("wind_period_ticks", 0)),
		"phys_ocean_period_ticks": int(phys.get("ocean_period_ticks", 0)),
		"phys_slice_count": int(phys.get("slice_count", 0)),
		"phys_next_pixel_idx": int(phys.get("next_pixel_idx", 0)),
		"phys_total_pixels": int(phys.get("total_pixels", 0)),
		"phys_pixel_quota": int(phys.get("pixel_quota", phys.get("current_pixel_quota", 0))),
		"phys_progress_ratio": float(phys.get("progress_ratio", 0.0)),
		"phys_processed_pixels": int(phys.get("processed_pixels", 0)),
		"phys_cursor_start": int(phys.get("cursor_start", -1)),
		"phys_cursor_end": int(phys.get("cursor_end", -1)),
		"phys_raster_requested_start": int(phys.get("raster_requested_start", -1)),
		"phys_raster_requested_end": int(phys.get("raster_requested_end", -1)),
		"phys_raster_returned_start": int(phys.get("raster_returned_start", -1)),
		"phys_raster_returned_end": int(phys.get("raster_returned_end", -1)),
		"phys_raster_pixels": int(phys.get("raster_pixels", 0)),
		"phys_raster_wall_ms": float(phys.get("raster_wall_ms", -1.0)),
		"phys_raster_native_ms": float(phys.get("raster_native_ms", -1.0)),
		"phys_raster_used_cpp": bool(phys.get("raster_used_cpp", false)),
		"phys_raster_atlas_updated": bool(phys.get("raster_atlas_updated", false)),
		"phys_raster_fallback_reason": str(phys.get("raster_fallback_reason", "")),
		"phys_raster_progress_guard_fired": bool(phys.get("raster_progress_guard_fired", false)),
		"phys_slp_path": str(phys.get("slp_path", phys.get("stage_slp_path", ""))),
		"phys_slp_native_ms": float(phys.get("slp_native_ms", phys.get("stage_slp_native_ms", -1.0))),
		"phys_slp_rc_ms": float(phys.get("slp_rc_ms", -1.0)),
		"phys_slp_out_size": int(phys.get("slp_out_size", -1)),
		"phys_slp_published_to_slot": bool(phys.get("slp_published_to_slot", false)),
		"phys_slp_commit_ok": bool(phys.get("slp_commit_ok", false)),
		"phys_slp_thermal_p95": float(phys.get("slp_thermal_p95", 0.0)),
		"phys_slp_delta_p95": float(phys.get("slp_delta_p95", 0.0)),
		"phys_wind_cpp_done": bool(phys.get("wind_cpp_done", false)),
		"phys_wind_rc_ms": float(phys.get("wind_rc_ms", -1.0)),
		"phys_wind_wx_size": int(phys.get("wind_wx_size", -1)),
		"phys_wind_wy_size": int(phys.get("wind_wy_size", -1)),
		"phys_wind_speed_out_size": int(phys.get("wind_speed_out_size", -1)),
		"phys_wind_map_speed_size": int(phys.get("wind_map_speed_size", -1)),
		"phys_wind_commit_ok": bool(phys.get("wind_commit_ok", false)),
		"phys_wind_delta_p95": float(phys.get("wind_delta_p95", 0.0)),
		"phys_daily_wind_due": bool(phys.get("daily_wind_due", false)),
		"phys_daily_wind_tick_idx": int(phys.get("daily_wind_tick_idx", -1)),
		"phys_daily_wind_season_phase": float(phys.get("daily_wind_season_phase", 0.0)),
		"phys_daily_wind_ran": bool(phys.get("daily_wind_ran", false)),
		"phys_daily_wind_path": str(phys.get("daily_wind_path", "")),
		"phys_daily_wind_elapsed_ms": float(phys.get("daily_wind_elapsed_ms", -1.0)),
		"phys_daily_wind_refresh_ms": float(phys.get("daily_wind_refresh_ms", -1.0)),
		"phys_daily_wind_slp_ms": float(phys.get("daily_wind_slp_ms", -1.0)),
		"phys_daily_wind_wind_ms": float(phys.get("daily_wind_wind_ms", -1.0)),
		"phys_daily_wind_fallback_reason": str(phys.get("daily_wind_fallback_reason", "")),
		"phys_daily_wind_slp_commit_ok": bool(phys.get("daily_wind_slp_commit_ok", false)),
		"phys_daily_wind_wind_commit_ok": bool(phys.get("daily_wind_wind_commit_ok", false)),
		"phys_daily_wind_wind_cpp_done": bool(phys.get("daily_wind_wind_cpp_done", false)),
		"phys_daily_wind_slp_published_to_slot": bool(phys.get("daily_wind_slp_published_to_slot", false)),
		"phys_daily_wind_slp_delta_p95": float(phys.get("daily_wind_slp_delta_p95", 0.0)),
		"phys_daily_wind_delta_p95": float(phys.get("daily_wind_wind_delta_p95", phys.get("daily_wind_delta_p95", 0.0))),
		"phys_psi_path": str(phys.get("psi_path", phys.get("stage_psi_path", ""))),
		"phys_psi_native_ms": float(phys.get("psi_native_ms", phys.get("stage_psi_native_ms", -1.0))),
		"phys_ocean_delta_p95": float(phys.get("ocean_delta_p95", 0.0)),
		"phys_thermal_current_p95": float(phys.get("thermal_current_p95", 0.0)),
		"phys_ocean_current_preclamp_p95": float(phys.get("ocean_current_preclamp_p95", 0.0)),
		"phys_ocean_current_preclamp_max": float(phys.get("ocean_current_preclamp_max", 0.0)),
		"phys_ocean_current_clamp_count": int(phys.get("ocean_current_clamp_count", 0)),
		"phys_ocean_current_clamp_ratio": float(phys.get("ocean_current_clamp_ratio", 0.0)),
		"phys_ocean_current_max_magnitude": float(phys.get("ocean_current_max_magnitude", 0.0)),
		"cell_index": idx,
		"q": int(cell.q),
		"r": int(cell.r),
		"s": int(cell.s),
	}


func _tick_fixed_suffix(sample: Dictionary, cell) -> String:
	var row: Dictionary = _base_row(sample, 0, cell)
	var cell_col: int = FIXED_COLUMNS.find("cell_index")
	if cell_col <= 1:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for i in range(1, cell_col):
		var col: String = str(FIXED_COLUMNS[i])
		parts.append(_csv_escape(row[col]) if row.has(col) else "")
	return "," + ",".join(parts)


static func _format_record_line(row_idx: int, fixed_suffix: String,
		cell_index: int, q: int, r: int, s: int,
		arrays: Array, field_types: PackedInt32Array) -> String:
	var tail: PackedStringArray = PackedStringArray()
	var field_count: int = arrays.size()
	tail.resize(4 + field_count)
	tail[0] = str(cell_index)
	tail[1] = str(q)
	tail[2] = str(r)
	tail[3] = str(s)
	for i in range(field_count):
		match int(field_types[i]):
			TYPE_PACKED_FLOAT32_ARRAY:
				tail[4 + i] = _csv_float(float(arrays[i][cell_index]))
			TYPE_PACKED_INT32_ARRAY:
				tail[4 + i] = str(int(arrays[i][cell_index]))
			TYPE_PACKED_BYTE_ARRAY:
				tail[4 + i] = str(int(arrays[i][cell_index]))
			_:
				tail[4 + i] = _csv_escape(_array_value(arrays[i], cell_index))
	return str(row_idx) + fixed_suffix + "," + ",".join(tail)


func _abort_recording(reason: String) -> void:
	_recording = false
	_flush_line_batch()
	_close_file()
	push_warning("[tile-data-record] auto-stop: %s; partial CSV kept at %s" % [reason, _path])


func _close_file() -> void:
	if _file != null:
		_flush_line_batch()
		_file.close()
	_file = null


func _flush_line_batch() -> float:
	if _file == null or _line_batch.is_empty():
		return 0.0
	var t_us0: int = Time.get_ticks_usec()
	_file.store_string("\n".join(_line_batch))
	_file.store_string("\n")
	_line_batch.clear()
	return (Time.get_ticks_usec() - t_us0) / 1000.0


static func _array_size(arr) -> int:
	var t: int = typeof(arr)
	if t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_INT32_ARRAY or t == TYPE_PACKED_BYTE_ARRAY:
		return arr.size()
	return -1


static func _array_value(arr, idx: int):
	return arr[idx]


static func _physical_field_stats(map_data) -> Dictionary:
	var out: Dictionary = {}
	var slp_arr = map_data.get("slp_arr")
	if typeof(slp_arr) == TYPE_PACKED_FLOAT32_ARRAY and not slp_arr.is_empty():
		out["slp_abs_p95"] = _packed_float_abs_p95(slp_arr)
	var wind_speed_arr = map_data.get("wind_speed_arr")
	if typeof(wind_speed_arr) == TYPE_PACKED_FLOAT32_ARRAY and not wind_speed_arr.is_empty():
		out["wind_mag_p95"] = _packed_float_abs_p95(wind_speed_arr)
	var transport_arr = map_data.get("temperature_transport_anomaly_arr")
	if typeof(transport_arr) == TYPE_PACKED_FLOAT32_ARRAY and not transport_arr.is_empty():
		out["transport_abs_p95"] = _packed_float_abs_p95(transport_arr)
		out["transport_nonzero_ratio"] = _packed_float_nonzero_ratio(transport_arr, 0.0001)
	var ocean_stats: Dictionary = _packed_vector_mag_stats(map_data.get("ocean_current_x_arr"), map_data.get("ocean_current_y_arr"))
	if not ocean_stats.is_empty():
		out["ocean_mag_p95"] = ocean_stats["p95"]
	var upwelling_arr = map_data.get("upwelling_strength_arr")
	if typeof(upwelling_arr) == TYPE_PACKED_FLOAT32_ARRAY and not upwelling_arr.is_empty():
		out["upwelling_abs_p95"] = _packed_float_abs_p95(upwelling_arr)
	return out


static func _weather_transition_stats(map_data) -> Dictionary:
	var type_arr = map_data.get("weather_type_arr")
	var target_arr = map_data.get("weather_target_type_arr")
	var alpha_arr = map_data.get("weather_transition_alpha_arr")
	if _array_size(type_arr) <= 0 or _array_size(target_arr) != _array_size(type_arr) or _array_size(alpha_arr) != _array_size(type_arr):
		return {}
	var n: int = _array_size(type_arr)
	var mismatch_count: int = 0
	var transitioning_count: int = 0
	var alpha_sum: float = 0.0
	var alpha_values: Array = []
	for i in range(n):
		if int(type_arr[i]) != int(target_arr[i]):
			mismatch_count += 1
		var alpha: float = float(alpha_arr[i])
		if is_nan(alpha) or is_inf(alpha):
			alpha = 0.0
		alpha = clampf(alpha, 0.0, 1.0)
		if alpha > 0.0 and alpha < 0.999:
			transitioning_count += 1
			alpha_sum += alpha
			alpha_values.append(alpha)
	alpha_values.sort()
	return {
		"target_mismatch_count": mismatch_count,
		"transitioning_count": transitioning_count,
		"transition_alpha_mean": alpha_sum / float(maxi(transitioning_count, 1)),
		"transition_alpha_p95": _sorted_p95(alpha_values),
	}


static func _packed_vector_mag_stats(x_arr, y_arr) -> Dictionary:
	if typeof(x_arr) != TYPE_PACKED_FLOAT32_ARRAY or typeof(y_arr) != TYPE_PACKED_FLOAT32_ARRAY:
		return {}
	var n: int = mini(x_arr.size(), y_arr.size())
	if n <= 0:
		return {}
	var values: Array = []
	for i in range(n):
		var x: float = float(x_arr[i])
		var y: float = float(y_arr[i])
		if is_nan(x) or is_inf(x) or is_nan(y) or is_inf(y):
			continue
		values.append(sqrt(x * x + y * y))
	values.sort()
	if values.is_empty():
		return {}
	return { "p95": _sorted_p95(values) }


static func _packed_float_abs_p95(arr) -> float:
	var values: Array = []
	for i in range(arr.size()):
		var v: float = float(arr[i])
		if is_nan(v) or is_inf(v):
			continue
		values.append(absf(v))
	values.sort()
	return _sorted_p95(values)


static func _packed_float_nonzero_ratio(arr, eps: float = 0.0001) -> float:
	var total: int = 0
	var nonzero: int = 0
	for i in range(arr.size()):
		var v: float = float(arr[i])
		if is_nan(v) or is_inf(v):
			continue
		total += 1
		if absf(v) > eps:
			nonzero += 1
	return float(nonzero) / float(maxi(total, 1))


static func _packed_float_p95(arr) -> float:
	var values: Array = []
	values.resize(arr.size())
	for i in range(arr.size()):
		values[i] = float(arr[i])
	values.sort()
	return _sorted_p95(values)


static func _sorted_p95(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var pos: int = clampi(int(floor(float(values.size() - 1) * 0.95)), 0, values.size() - 1)
	return float(values[pos])


static func _format_header_line(columns: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c in columns:
		parts.append(_csv_escape(c))
	return ",".join(parts)


static func _format_row_line(row: Dictionary, columns: PackedStringArray) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for c in columns:
		parts.append(_csv_escape(row[c]) if row.has(c) else "")
	return ",".join(parts)


static func _csv_escape(value) -> String:
	var s: String = ""
	var t: int = typeof(value)
	if t == TYPE_NIL:
		return ""
	elif t == TYPE_BOOL:
		s = "true" if bool(value) else "false"
	elif t == TYPE_INT:
		s = str(int(value))
	elif t == TYPE_FLOAT:
		var fv: float = float(value)
		if is_nan(fv) or is_inf(fv):
			return ""
		s = ("%.6f" % fv).rstrip("0").rstrip(".")
		if s == "" or s == "-":
			s = "0"
	else:
		s = str(value)

	if s.find(",") != -1 or s.find("\"") != -1 or s.find("\n") != -1 or s.find("\r") != -1:
		s = s.replace("\"", "\"\"")
		return "\"" + s + "\""
	return s


static func _csv_float(value: float) -> String:
	if is_nan(value) or is_inf(value):
		return ""
	var s: String = ("%.6f" % value).rstrip("0").rstrip(".")
	if s == "" or s == "-":
		return "0"
	return s
