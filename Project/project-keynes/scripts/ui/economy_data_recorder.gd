# economy_data_recorder.gd
#
# GM 面板的经济录制控制面。经济快照抓取、CSV v19 编码和写盘全部由
# DCWorldExt/EconomyCsvRecorder 完成；这里仅准备静态配置并轮询状态。
class_name EconomyDataRecorder
extends RefCounted


const RESOURCE_MIDDLE_NAMES: PackedStringArray = [
	"timber", "stone", "fertile_soil", "coal", "oil", "natural_gas",
	"copper_ore", "iron_ore", "gold_ore", "silver_ore", "salt", "saltpeter",
	"rare_earth", "clay", "wild_game", "marine_fish", "arable_land", "paddy_land",
	"plantation_land", "pasture", "bauxite", "limestone", "silica_sand",
	"phosphate_rock", "tin_ore", "lead_ore", "zinc_ore", "manganese_ore",
	"sulfur", "flint",
]

const DESKTOP_EXPORT_DIR_RELATIVE: String = "../../tmp"
const MOBILE_EXPORT_DIR: String = "user://economy_data"
const HARD_ROW_LIMIT: int = 5_000_000
const DEFAULT_CELL_STRIDE: int = 1

var _main = null
var _status: Dictionary = {"state": "idle", "recording": false, "draining": false}
var _paths: Array = []
var _cell_stride: int = DEFAULT_CELL_STRIDE
var _max_rows: int = HARD_ROW_LIMIT
var _current_cell_only: bool = false
var _record_summary: bool = true
var _record_cohorts: bool = true
var _record_buildings: bool = true
var _record_resources: bool = true
var _record_market: bool = true
var _last_reported_captured_epochs: int = 0
var _last_polled_state: String = "idle"
var _local_start_error: bool = false


func bind_main(m) -> void:
	_main = m


func is_recording() -> bool:
	var state: String = str(_status.get("state", "idle"))
	return state == "opening" or state == "recording" or state == "draining"


func row_count() -> int:
	return int(_status.get("captured_rows", 0))


func set_record_summary(v: bool) -> void:
	if not is_recording():
		_record_summary = v


func set_record_cohorts(v: bool) -> void:
	if not is_recording():
		_record_cohorts = v


func set_record_buildings(v: bool) -> void:
	if not is_recording():
		_record_buildings = v


func set_record_resources(v: bool) -> void:
	if not is_recording():
		_record_resources = v


func set_record_market(v: bool) -> void:
	if not is_recording():
		_record_market = v


func set_current_cell_only(v: bool) -> void:
	if not is_recording():
		_current_cell_only = v


func set_sampling_config(cell_stride: int = DEFAULT_CELL_STRIDE,
		max_rows: int = HARD_ROW_LIMIT) -> void:
	if is_recording():
		return
	_cell_stride = maxi(1, cell_stride)
	_max_rows = clampi(max_rows, 1, HARD_ROW_LIMIT)


func sampling_summary() -> Dictionary:
	_poll_status()
	var out: Dictionary = _status.duplicate()
	out["cell_stride"] = _cell_stride
	out["max_rows"] = _max_rows
	out["current_cell_only"] = _current_cell_only
	out["record_summary"] = _record_summary
	out["record_cohorts"] = _record_cohorts
	out["record_buildings"] = _record_buildings
	out["record_resources"] = _record_resources
	out["record_market"] = _record_market
	out["last_tick_ms"] = float(_status.get("capture_ms_last", 0.0))
	out["enabled_dims"] = _enabled_dims_string()
	return out


func start() -> void:
	if is_recording():
		return
	_local_start_error = false
	var world = _get_world()
	var map = _current_map()
	if world == null or map == null:
		push_warning("[economy-record] start failed: world/map unavailable")
		return
	if not world.has_method("start_economy_csv_recording"):
		push_error("[economy-record] native CSV v19 API unavailable; rebuild dots_ext")
		return
	if not map.has_method("cell_count") or not map.has_method("cell_at"):
		push_error("[economy-record] MapData coordinate API unavailable")
		return
	var cell_count: int = int(map.cell_count())
	if cell_count <= 0:
		push_warning("[economy-record] start failed: no cells")
		return
	var cell_indices := PackedInt32Array()
	var selected_index: int = -1
	if _current_cell_only:
		var selected = _selected_cell()
		if selected == null:
			_set_local_start_error("selection_required", "请先在地图上选择一个地块")
			return
		selected_index = int(selected.index)
		if selected_index < 0 or selected_index >= cell_count:
			_set_local_start_error("selection_out_of_range", "选中地块索引已失效，请重新选择")
			return
		cell_indices.append(selected_index)
	var q_arr := PackedInt32Array()
	var r_arr := PackedInt32Array()
	var s_arr := PackedInt32Array()
	q_arr.resize(cell_count)
	r_arr.resize(cell_count)
	s_arr.resize(cell_count)
	for idx in range(cell_count):
		var cell = map.cell_at(idx)
		if cell == null:
			push_error("[economy-record] null cell at %d" % idx)
			return
		q_arr[idx] = int(cell.q)
		r_arr[idx] = int(cell.r)
		s_arr[idx] = int(cell.s)

	var resource_slot_ids := PackedInt32Array()
	var resource_ids := PackedStringArray()
	if world.has_method("component_id"):
		for middle_name in RESOURCE_MIDDLE_NAMES:
			var sid: int = int(world.component_id("cell_res_" + middle_name + "_reserve"))
			if sid >= 0:
				resource_slot_ids.append(sid)
				resource_ids.append(middle_name)

	var export_dir: String = _export_dir_absolute()
	var err: Error = DirAccess.make_dir_recursive_absolute(export_dir)
	if err != OK:
		push_error("[economy-record] cannot create export dir %s err=%d" % [export_dir, err])
		return
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var ts: String = "%04d%02d%02d_%02d%02d%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
	]
	var scope_tag: String = ""
	if selected_index >= 0:
		scope_tag = "_cell%d_q%d_r%d" % [
			selected_index, q_arr[selected_index], r_arr[selected_index],
		]
	var native_paths: Dictionary = {}
	for dim in ["summary", "cohorts", "buildings", "resources", "market"]:
		native_paths[dim] = export_dir.path_join(
			"economy_record_%s_v19%s_%s.csv" % [ts, scope_tag, dim])

	_status = world.call("start_economy_csv_recording", {
		"record_summary": _record_summary,
		"record_cohorts": _record_cohorts,
		"record_buildings": _record_buildings,
		"record_resources": _record_resources,
		"record_market": _record_market,
		"cell_stride": _cell_stride,
		"cell_indices": cell_indices,
		"max_rows": _max_rows,
		"q_arr": q_arr,
		"r_arr": r_arr,
		"s_arr": s_arr,
		"resource_slot_ids": resource_slot_ids,
		"resource_ids": resource_ids,
		"paths": native_paths,
	})
	_paths.clear()
	for path in _status.get("paths", []):
		_paths.append(path)
	_last_reported_captured_epochs = 0
	_last_polled_state = str(_status.get("state", "idle"))
	if not bool(_status.get("ok", false)):
		var error_code: String = str(_status.get("error_code", "start_failed"))
		if error_code == "":
			error_code = "start_failed"
		_set_local_start_error(error_code, str(_status.get("error_message", "unknown")))
		return
	print("[economy-record] native v5 start cells=%d sampled=%d resources=%d stride=%d max_rows=%d dims=%s" % [
		cell_count, int(_status.get("sampled_cell_count", 0)), resource_ids.size(),
		_cell_stride, _max_rows, _enabled_dims_string(),
	])


func stop_and_export() -> Array:
	var world = _get_world()
	if world != null and world.has_method("request_stop_economy_csv_recording"):
		_status = world.call("request_stop_economy_csv_recording")
		_paths.clear()
		for path in _status.get("paths", []):
			_paths.append(path)
	return _paths


func on_fast_tick(_sample: Dictionary) -> Dictionary:
	var before: int = int(_status.get("captured_epochs", 0))
	_poll_status()
	var after: int = int(_status.get("captured_epochs", 0))
	var captured: bool = after > before or after > _last_reported_captured_epochs
	_last_reported_captured_epochs = after
	return {
		"recorded": captured,
		"epoch_id": int(_status.get("last_captured_epoch", -1)),
		"rows": int(_status.get("captured_rows", 0)),
		"elapsed_ms": float(_status.get("capture_ms_last", 0.0)),
		"reason": str(_status.get("error_code", "")),
	}


func _poll_status() -> void:
	if _local_start_error:
		return
	var world = _get_world()
	if world == null or not world.has_method("get_economy_csv_recording_status"):
		return
	var next_status: Dictionary = world.call("get_economy_csv_recording_status")
	var next_state: String = str(next_status.get("state", "idle"))
	if next_state != _last_polled_state:
		if next_state == "completed":
			print("[economy-record] background export completed -> %s" % str(next_status.get("paths", [])))
		elif next_state == "error":
			push_warning("[economy-record] stopped: %s first_unrecorded_epoch=%d" % [
				str(next_status.get("error_code", "unknown")),
				int(next_status.get("first_unrecorded_epoch", -1)),
			])
	_last_polled_state = next_state
	_status = next_status
	_paths.clear()
	for path in _status.get("paths", []):
		_paths.append(path)


func _get_world():
	if _main == null or not _main.has_method("get_generator"):
		return null
	var gen = _main.get_generator()
	if gen == null or not gen.has_method("get_data_core_world_ext"):
		return null
	return gen.get_data_core_world_ext()


func _current_map():
	if _main == null or not _main.has_method("get_current_map"):
		return null
	return _main.get_current_map()


func _selected_cell():
	if _main == null or not _main.has_method("get_selected_cell"):
		return null
	return _main.get_selected_cell()


func _set_local_start_error(code: String, message: String) -> void:
	_local_start_error = true
	_status = {
		"state": "error",
		"recording": false,
		"draining": false,
		"error_code": code,
		"error_message": message,
		"paths": PackedStringArray(),
	}
	push_warning("[economy-record] start failed: %s" % message)


func _enabled_dims_string() -> String:
	var dims := PackedStringArray()
	if _record_summary: dims.append("summary")
	if _record_cohorts: dims.append("cohorts")
	if _record_buildings: dims.append("buildings")
	if _record_resources: dims.append("resources")
	if _record_market: dims.append("market")
	return ",".join(dims)


static func _arr_i(arr, i: int):
	if _is_array_like(arr) and i >= 0 and i < arr.size():
		return arr[i]
	return 0


static func _array_size(arr) -> int:
	return arr.size() if _is_array_like(arr) else 0


static func _is_array_like(value) -> bool:
	return value is Array \
		or value is PackedByteArray \
		or value is PackedInt32Array \
		or value is PackedInt64Array \
		or value is PackedFloat32Array \
		or value is PackedFloat64Array \
		or value is PackedStringArray


static func _export_dir_absolute() -> String:
	if OS.has_feature("mobile"):
		return ProjectSettings.globalize_path(MOBILE_EXPORT_DIR).simplify_path()
	return ProjectSettings.globalize_path("res://").path_join(DESKTOP_EXPORT_DIR_RELATIVE).simplify_path()
