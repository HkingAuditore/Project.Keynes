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
	"weather_precip_arr",
	"weather_vapor_arr",
	"weather_convergence_arr",
	"weather_instability_arr",
	"weather_field_init_arr",
	"air_mass_temp_anomaly_arr",
	"has_river_arr",
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
	"is_water_arr",
	"climate_dirty_mask",
	"weather_dirty_mask",
]

const EXPORT_DIR_RELATIVE: String = "../../tmp"
const HARD_ROW_LIMIT: int = 5000000


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


func bind_main(m) -> void:
	_main = m


func is_recording() -> bool:
	return _recording


func row_count() -> int:
	return _row_count


func tick_count() -> int:
	return _tick_count


func hit_limit() -> bool:
	return _hit_limit


func start() -> void:
	_close_file()
	_recording = false
	_hit_limit = false
	_row_count = 0
	_tick_count = 0
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

	_soa_fields = _collect_soa_fields(map_data, _cell_count)
	if _soa_fields.is_empty():
		push_warning("[tile-data-record] start failed: no cell-level SoA fields found")
		return

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

	_map_ref = map_data
	if _main != null and _main.has_method("get_fast_tick_count"):
		_start_tick = int(_main.get_fast_tick_count())
	else:
		_start_tick = 0
	_recording = true
	print("[tile-data-record] start cells=%d soa_cols=%d start_tick=%d path=%s" % [
		_cell_count, _soa_fields.size(), _start_tick, _path,
	])


func stop_and_export() -> String:
	var out_path: String = _path
	_recording = false
	_close_file()
	if _row_count <= 0:
		print("[tile-data-record] stop: no rows captured")
		return ""
	print("[tile-data-record] exported ticks=%d rows=%d cols=%d -> %s%s" % [
		_tick_count, _row_count, _columns.size(), out_path,
		"  (HIT LIMIT)" if _hit_limit else "",
	])
	return out_path


func on_fast_tick(sample: Dictionary) -> void:
	if not _recording or _file == null:
		return
	if _hit_limit:
		return

	var map_data = _current_map()
	if map_data == null:
		_abort_recording("current map became null")
		return
	if map_data != _map_ref:
		_abort_recording("map changed during recording")
		return
	if not map_data.has_method("cell_count") or int(map_data.cell_count()) != _cell_count:
		_abort_recording("cell_count changed during recording")
		return
	if map_data.has_method("has_soa") and not bool(map_data.has_soa()):
		_abort_recording("MapData SoA became unavailable")
		return
	if _row_count + _cell_count > HARD_ROW_LIMIT:
		_hit_limit = true
		_recording = false
		_close_file()
		push_warning("[tile-data-record] hit hard row limit (%d), auto-stopped before writing a partial tick." % HARD_ROW_LIMIT)
		return

	var arrays: Dictionary = {}
	for field in _soa_fields:
		var arr = map_data.get(field)
		if _array_size(arr) != _cell_count:
			_abort_recording("SoA field changed size: %s" % field)
			return
		arrays[field] = arr

	for idx in range(_cell_count):
		var cell = map_data.cell_at(idx)
		if cell == null:
			continue
		var row: Dictionary = _base_row(sample, idx, cell)
		for field in _soa_fields:
			row[field] = _array_value(arrays[field], idx)
		_file.store_line(_format_row_line(row, _columns))
		_row_count += 1
	_tick_count += 1


static func _export_dir_absolute() -> String:
	return ProjectSettings.globalize_path("res://").path_join(EXPORT_DIR_RELATIVE).simplify_path()


static func _collect_soa_fields(map_data, cell_count: int) -> PackedStringArray:
	var fields: PackedStringArray = PackedStringArray()
	for name in SOA_FIELD_CANDIDATES:
		var field: String = str(name)
		var arr = map_data.get(field)
		if _array_size(arr) == cell_count:
			fields.append(field)
	return fields


func _current_map():
	if _main == null or not _main.has_method("get_current_map"):
		return null
	return _main.get_current_map()


func _base_row(sample: Dictionary, idx: int, cell) -> Dictionary:
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
		"cell_index": idx,
		"q": int(cell.q),
		"r": int(cell.r),
		"s": int(cell.s),
	}


func _abort_recording(reason: String) -> void:
	_recording = false
	_close_file()
	push_warning("[tile-data-record] auto-stop: %s; partial CSV kept at %s" % [reason, _path])


func _close_file() -> void:
	if _file != null:
		_file.close()
	_file = null


static func _array_size(arr) -> int:
	var t: int = typeof(arr)
	if t == TYPE_PACKED_FLOAT32_ARRAY or t == TYPE_PACKED_INT32_ARRAY or t == TYPE_PACKED_BYTE_ARRAY:
		return arr.size()
	return -1


static func _array_value(arr, idx: int):
	return arr[idx]


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
