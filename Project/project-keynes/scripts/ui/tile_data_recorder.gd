# tile_data_recorder.gd
#
# 地块数据录制器 —— 在 fast_tick 末尾把每个地块的 SoA 快照流式写成 CSV。
# 每行 = 一个 tick 的一个 cell。DebugConsole 负责 start / stop 控制；main.gd
# 只转发本 tick 的基础 sample，本类自行从 main.get_current_map() 读取 MapData。
class_name TileDataRecorder
extends RefCounted

const TileCsv = preload("res://scripts/ui/tile_data_recorder_csv.gd")
const TileMetrics = preload("res://scripts/ui/tile_data_recorder_metrics.gd")

const SCHEMA_VERSION: int = 1
const FIXED_COLUMNS: Array = TileCsv.FIXED_COLUMNS
const SOA_FIELD_CANDIDATES: Array = TileCsv.SOA_FIELD_CANDIDATES
const DESKTOP_EXPORT_DIR_RELATIVE: String = "../../tmp"
const MOBILE_EXPORT_DIR: String = "user://tile_data"
const HARD_ROW_LIMIT: int = 5000000
const DEFAULT_TICK_STRIDE: int = 1
const DEFAULT_CELL_STRIDE: int = 1
const BATCH_LINE_LIMIT: int = 2048
const DEFAULT_COMPACT_FIELDS: bool = false
const COMPACT_SOA_FIELD_CANDIDATES: Array = TileCsv.COMPACT_SOA_FIELD_CANDIDATES

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
var _session_metadata: Dictionary = {}
var _sidecar_path: String = ""
var _country_samples: Array[Dictionary] = []
var _country_receipts: Array[Dictionary] = []
var _country_receipt_cursor: int = 0
var _modifier_samples: Array[Dictionary] = []
var _effect_samples: Array[Dictionary] = []
var _runtime_report_start: Dictionary = {}
var _runtime_report_end: Dictionary = {}
var _first_seen_tick: int = -1
var _last_seen_tick: int = -1
var _first_recorded_tick: int = -1
var _last_recorded_tick: int = -1


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


func schema_version() -> int:
	return SCHEMA_VERSION


func sidecar_path() -> String:
	return _sidecar_path


func set_session_metadata(metadata: Dictionary) -> void:
	_session_metadata = metadata.duplicate(true)


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


func start(metadata: Dictionary = {}) -> void:
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
	_sidecar_path = ""
	_country_samples.clear()
	_modifier_samples.clear()
	_effect_samples.clear()
	_country_receipts.clear()
	_country_receipt_cursor = 0
	_runtime_report_start = {}
	_runtime_report_end = {}
	_first_seen_tick = -1
	_last_seen_tick = -1
	_first_recorded_tick = -1
	_last_recorded_tick = -1
	if not metadata.is_empty():
		_session_metadata = metadata.duplicate(true)
	elif OS.is_debug_build() and Engine.has_meta(&"stage_c_tile_metadata"):
		var raw_metadata = Engine.get_meta(&"stage_c_tile_metadata", {})
		if raw_metadata is Dictionary:
			_session_metadata = (raw_metadata as Dictionary).duplicate(true)

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
	for c in TileCsv.FIXED_COLUMNS:
		_columns.append(str(c))
	for f in _soa_fields:
		_columns.append(f)

	var export_dir: String = String(_session_metadata.get("output_dir", ""))
	if export_dir.is_empty():
		export_dir = _export_dir_absolute()
	export_dir = ProjectSettings.globalize_path(export_dir).simplify_path()
	DirAccess.make_dir_recursive_absolute(export_dir)
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var requested_csv_path := String(_session_metadata.get("csv_path", ""))
	if not requested_csv_path.is_empty():
		_path = ProjectSettings.globalize_path(requested_csv_path).simplify_path()
		DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	else:
		var requested_name := String(_session_metadata.get("csv_name", ""))
		if requested_name.is_empty():
			requested_name = "tile_data_record_%04d%02d%02d_%02d%02d%02d.csv" % [
				int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
				int(dt.get("hour", 0)), int(dt.get("minute", 0)), int(dt.get("second", 0)),
			]
		_path = export_dir.path_join(requested_name)
	_sidecar_path = String(_session_metadata.get("sidecar_path", ""))
	if _sidecar_path.is_empty():
		_sidecar_path = _path.get_basename() + ".sidecar.json"
	_sidecar_path = ProjectSettings.globalize_path(_sidecar_path).simplify_path()
	DirAccess.make_dir_recursive_absolute(_sidecar_path.get_base_dir())

	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file == null:
		var err: int = FileAccess.get_open_error()
		push_error("[tile-data-record] open failed path=%s err=%d" % [_path, err])
		_path = ""
		return

	_file.store_8(0xEF)
	_file.store_8(0xBB)
	_file.store_8(0xBF)
	_file.store_line(TileCsv._format_header_line(_columns))
	_csv_encoder_ext = _discover_csv_encoder_ext()

	_map_ref = map_data
	_runtime_report_start = _runtime_report_snapshot()
	if _main != null and _main.has_method("get_fast_tick_count"):
		_start_tick = int(_main.get_fast_tick_count())
	else:
		_start_tick = 0
	_recording = true
	_write_sidecar(false)
	print("[tile-data-record] start cells=%d soa_cols=%d tick_stride=%d cell_stride=%d max_rows=%d compact=%s start_tick=%d path=%s" % [
		_cell_count, _soa_fields.size(), _tick_stride, _cell_stride, _max_rows,
		str(_compact_fields), _start_tick, _path,
	])


func stop_and_export() -> String:
	var out_path: String = _path
	_recording = false
	_flush_line_batch()
	_close_file()
	_runtime_report_end = _runtime_report_snapshot()
	_write_sidecar(true)
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
	if _first_seen_tick < 0:
		_first_seen_tick = global_tick
	_last_seen_tick = global_tick
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
		if TileCsv._array_size(arr) != _cell_count:
			_abort_recording("SoA field changed size: %s" % field)
			return {"recorded": false, "rows": 0, "reason": "soa_size_changed"}
		arrays[field_i] = arr
	_last_tick_collect_ms = (Time.get_ticks_usec() - t_collect_us0) / 1000.0

	var t_stats_us0: int = Time.get_ticks_usec()
	var climate: Dictionary = sample.get("climate", {})
	var precip_arr = map_data.get("weather_precip_arr")
	if TileCsv._array_size(precip_arr) == _cell_count:
		climate["precip_p95"] = TileMetrics._packed_float_p95(precip_arr)
	var physical_stats: Dictionary = TileMetrics._physical_field_stats(map_data)
	for key in physical_stats.keys():
		climate[key] = physical_stats[key]
	sample["climate"] = climate
	var weather: Dictionary = sample.get("weather", {})
	var transition_stats: Dictionary = TileMetrics._weather_transition_stats(map_data)
	for key in transition_stats.keys():
		weather[key] = transition_stats[key]
	sample["weather"] = weather
	_capture_country_evidence(global_tick, map_data)
	_capture_modifier_evidence(global_tick)
	_capture_effect_evidence(global_tick)
	_last_tick_stats_ms = (Time.get_ticks_usec() - t_stats_us0) / 1000.0
	var first_cell = map_data.cell_at(0)
	if first_cell == null:
		_abort_recording("cell 0 became null during recording")
		return {"recorded": false, "rows": 0, "reason": "cell_null"}
	var fixed_suffix: String = TileCsv._tick_fixed_suffix(sample, first_cell, _row_count)

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
	if _first_recorded_tick < 0:
		_first_recorded_tick = global_tick
	_last_recorded_tick = global_tick
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
	if OS.has_feature("mobile"):
		return ProjectSettings.globalize_path(MOBILE_EXPORT_DIR).simplify_path()
	return ProjectSettings.globalize_path("res://").path_join(DESKTOP_EXPORT_DIR_RELATIVE).simplify_path()


static func _collect_soa_fields(map_data, cell_count: int, compact_fields: bool = DEFAULT_COMPACT_FIELDS) -> PackedStringArray:
	return TileCsv._collect_soa_fields(map_data, cell_count, compact_fields)


func _capture_country_evidence(tick_idx: int, map_data) -> void:
	if _main == null or not _main.has_method("get_generator"):
		return
	var generator = _main.get_generator()
	if generator == null or not generator.has_method("get_country_facade"):
		return
	var facade = generator.get_country_facade()
	if facade == null or not facade.has_method("report") \
			or not facade.has_method("cell_summary"):
		return
	var report: Dictionary = facade.report()
	if not bool(report.get("bootstrapped", false)):
		return

	var first_cell_by_slot := {}
	var owners = map_data.get("country_slot_arr")
	if TileCsv._array_size(owners) == _cell_count:
		for cell_idx in range(_cell_count):
			var slot := int(owners[cell_idx])
			if slot >= 0 and not first_cell_by_slot.has(slot):
				first_cell_by_slot[slot] = cell_idx
	var slots: Array = first_cell_by_slot.keys()
	slots.sort()
	var countries: Array[Dictionary] = []
	for slot_value in slots:
		var cell_idx := int(first_cell_by_slot[slot_value])
		var summary: Dictionary = facade.cell_summary(cell_idx)
		var handle := int(summary.get("country_handle", 0))
		if handle == 0:
			continue
		var snapshot: Dictionary = facade.snapshot(handle) \
			if facade.has_method("snapshot") else {}
		var treasury: Dictionary = facade.treasury_snapshot(handle) \
			if facade.has_method("treasury_snapshot") else {}
		var research: Dictionary = facade.research_snapshot(handle) \
			if facade.has_method("research_snapshot") else {}
		countries.append({
			"country_slot": int(slot_value),
			"country_handle": handle,
			"country_id": String(summary.get("country_id", "")),
			"state_version": int(summary.get("state_version", -1)),
			"territory_count": int(summary.get("territory_count", -1)),
			"cash": int(treasury.get("cash", summary.get("cash", 0))),
			"good_ids": Array(treasury.get("good_ids", PackedStringArray())),
			"good_quantities": Array(treasury.get(
				"quantities", PackedInt64Array())),
			"technology_ids": Array(snapshot.get(
				"technology_ids", PackedStringArray())),
			"research_states": Array(research.get(
				"technology_states", PackedInt32Array())),
			"research_queue": Array(research.get(
				"queue_technology_indices", PackedInt32Array())),
		})

	var worker_view: Dictionary = {}
	var world_ext = facade.world_ext() if facade.has_method("world_ext") else null
	if world_ext != null:
		worker_view = world_ext.get_country_worker_read_view(0)
	_country_samples.append({
		"tick_idx": tick_idx,
		"reference_generation": int(report.get("generation", -1)),
		"reference_state_hash": int(report.get("state_hash", 0)),
		"worker_available": bool(worker_view.get("available", false)),
		"worker_generation": int(worker_view.get("generation", -1)),
		"worker_committed_day": int(worker_view.get("committed_day", -1)),
		"worker_state_hash": int(worker_view.get("state_hash", 0)),
		"worker_territory_watermark": int(worker_view.get(
			"territory_watermark", -1)),
		"worker_research_watermark": int(worker_view.get(
			"research_watermark", -1)),
		"worker_tax_watermark": int(worker_view.get("tax_watermark", -1)),
		"countries": countries,
	})

	if facade.has_method("poll_worker_command_receipts"):
		var receipt_batch: Dictionary = facade.poll_worker_command_receipts(
			_country_receipt_cursor, 4096)
		if bool(receipt_batch.get("ok", false)):
			for value in receipt_batch.get("receipts", []):
				if value is Dictionary:
					var receipt: Dictionary = value.duplicate(true)
					receipt["observed_tick_idx"] = tick_idx
					_country_receipts.append(receipt)
			_country_receipt_cursor = maxi(_country_receipt_cursor,
				int(receipt_batch.get("last_publication_sequence",
					_country_receipt_cursor)))


## E8 ModifierClientEvidence: record worker Modifier POD hashes for ACTIVE/OFF
## dual recordings. Uses runtime thread report fields — not Climate tile arrays.
func _capture_modifier_evidence(tick_idx: int) -> void:
	if _main == null or not _main.has_method("get_generator"):
		return
	var generator = _main.get_generator()
	if generator == null or not generator.has_method("get_runtime_thread_report"):
		return
	var report: Dictionary = generator.get_runtime_thread_report()
	_modifier_samples.append({
		"tick_idx": tick_idx,
		"state_hash": int(report.get("modifier_pod_state_hash", 0)),
		"snapshot_generation": int(report.get("modifier_pod_snapshot_generation", 0)),
		"ack_count": int(report.get("modifier_pod_ack_count", 0)),
		"ready": bool(report.get("modifier_pod_ready", false)),
		"worker_authoritative": bool(report.get("modifier_worker_authoritative", false)),
		"fallback_reason": String(report.get("modifier_pod_fallback_reason", "")),
	})


## F8 EffectClientEvidence: record worker Effect POD hashes for ACTIVE/OFF
## dual recordings. Uses runtime thread report fields — not Climate tile arrays.
func _capture_effect_evidence(tick_idx: int) -> void:
	if _main == null or not _main.has_method("get_generator"):
		return
	var generator = _main.get_generator()
	if generator == null or not generator.has_method("get_runtime_thread_report"):
		return
	var report: Dictionary = generator.get_runtime_thread_report()
	_effect_samples.append({
		"tick_idx": tick_idx,
		"state_hash": int(report.get("effect_pod_state_hash", 0)),
		"snapshot_generation": int(report.get("effect_pod_snapshot_generation", 0)),
		"ack_count": int(report.get("effect_pod_ack_count", 0)),
		"ready": bool(report.get("effect_pod_ready", false)),
		"worker_authoritative": bool(report.get("effect_worker_authoritative", false)),
		"fallback_reason": String(report.get("effect_pod_fallback_reason", "")),
	})


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
	if ext != null:
		return ext
	return null


func _try_write_native_csv_rows(fixed_suffix: String, arrays: Array) -> bool:
	if _csv_encoder_ext == null or _file == null:
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


static func _format_record_line(row_idx: int, fixed_suffix: String,
		cell_index: int, q: int, r: int, s: int,
		arrays: Array, field_types: PackedInt32Array) -> String:
	return TileCsv._format_record_line(row_idx, fixed_suffix, cell_index, q, r, s, arrays, field_types)


func _abort_recording(reason: String) -> void:
	_recording = false
	_flush_line_batch()
	_close_file()
	_runtime_report_end = _runtime_report_snapshot()
	_write_sidecar(true, reason)
	push_warning("[tile-data-record] auto-stop: %s; partial CSV kept at %s" % [reason, _path])


func _runtime_report_snapshot() -> Dictionary:
	var report: Dictionary = {}
	if _main != null and _main.has_method("get_generator"):
		var generator = _main.get_generator()
		if generator != null and generator.has_method("get_runtime_thread_report"):
			report = generator.get_runtime_thread_report()
	if _main != null and _main.has_method("climate_authority_diagnostics"):
		report["climate_authority_diagnostics"] = _main.climate_authority_diagnostics()
	return report


func _write_sidecar(final: bool, stop_reason: String = "") -> void:
	if _sidecar_path.is_empty():
		return
	var report := _runtime_report_end if final and not _runtime_report_end.is_empty() \
		else _runtime_report_snapshot()
	var authority_mode := String(_session_metadata.get("authority_mode", "")).to_upper()
	if authority_mode.is_empty():
		authority_mode = "ACTIVE" if String(report.get(
			"simulation_thread_mode", "OFF")).to_upper() == "ACTIVE" else "OFF"
	var worker_mode := String(_session_metadata.get("worker_mode", "")).to_upper()
	if worker_mode.is_empty():
		worker_mode = "ACTIVE" if authority_mode == "ACTIVE" else "SHADOW"
	var climate_diag: Dictionary = report.get("climate_authority_diagnostics", {})
	var payload: Dictionary = {
		"schema": "TileDataRecorderSidecar",
		"schema_version": SCHEMA_VERSION,
		"csv_path": _path,
		"session": _session_metadata.duplicate(true),
		"authority_mode": authority_mode,
		"worker_mode": worker_mode,
		"fields": Array(_columns),
		"soa_fields": Array(_soa_fields),
		"tick_coverage": {
			"tick_stride": _tick_stride,
			"first_seen_tick": _first_seen_tick,
			"last_seen_tick": _last_seen_tick,
			"first_recorded_tick": _first_recorded_tick,
			"last_recorded_tick": _last_recorded_tick,
			"seen_ticks": _tick_count,
			"recorded_ticks": _recorded_tick_count,
			"skipped_ticks": _skipped_tick_count,
		},
		"cell_coverage": {
			"cell_count": _cell_count,
			"cell_stride": _cell_stride,
			"first_cell_index": 0 if _cell_count > 0 else -1,
			"last_cell_index": _cell_count - 1,
			"rows": _row_count,
		},
		"sampling": sampling_summary(),
		"country_evidence": {
			"schema": "CountryClientEvidence",
			"schema_version": 1,
			"samples": _country_samples.duplicate(true),
			"terminal_receipts": _country_receipts.duplicate(true),
			"last_receipt_request_id": _country_receipt_cursor,
		},
		"modifier_evidence": {
			"schema": "ModifierClientEvidence",
			"schema_version": 1,
			"state_hash": int(_modifier_samples.back().get("state_hash", 0)) if not _modifier_samples.is_empty() else 0,
			"snapshot_generation": int(_modifier_samples.back().get("snapshot_generation", 0)) if not _modifier_samples.is_empty() else 0,
			"ack_count": int(_modifier_samples.back().get("ack_count", 0)) if not _modifier_samples.is_empty() else 0,
			"samples": _modifier_samples.duplicate(true),
		},
		"effect_evidence": {
			"schema": "EffectClientEvidence",
			"schema_version": 1,
			"state_hash": int(_effect_samples.back().get("state_hash", 0)) if not _effect_samples.is_empty() else 0,
			"snapshot_generation": int(_effect_samples.back().get("snapshot_generation", 0)) if not _effect_samples.is_empty() else 0,
			"ack_count": int(_effect_samples.back().get("ack_count", 0)) if not _effect_samples.is_empty() else 0,
			"samples": _effect_samples.duplicate(true),
		},
		"runtime": {
			"committed_day": int(report.get("simulation_committed_day", -1)),
			"writeback_day": int(climate_diag.get("writeback_last_day", -1)),
			"worker_fault_count": int(report.get("worker_fault_count", 0)),
			"runtime_report_start": _runtime_report_start.duplicate(true),
			"runtime_report_end": report.duplicate(true),
		},
		"stop_reason": stop_reason,
		"complete": final,
	}
	var file := FileAccess.open(_sidecar_path, FileAccess.WRITE)
	if file == null:
		push_warning("[tile-data-record] sidecar open failed path=%s err=%d" % [
			_sidecar_path, FileAccess.get_open_error()])
		return
	file.store_string(JSON.stringify(payload, "  "))
	file.close()


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


static func _csv_escape(value) -> String:
	return TileCsv._csv_escape(value)
