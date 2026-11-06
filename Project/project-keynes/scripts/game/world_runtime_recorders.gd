extends RefCounted

## Passive recorder calls and result formatting. Sampling and elapsed-time ownership stay in host.

static func _gm_one_recorder_state(recorder: RefCounted) -> Dictionary:
	if recorder == null:
		return {"available": false, "recording": false, "rows": 0}
	return {"available": true,
		"recording": bool(recorder.call("is_recording")) if recorder.has_method("is_recording") else false,
		"rows": int(recorder.call("row_count")) if recorder.has_method("row_count") else 0}

static func _recorder_ready(recorder: RefCounted) -> bool:
	if recorder == null or not recorder.has_method("on_fast_tick"):
		return false
	if recorder.has_method("is_recording") and not bool(recorder.call("is_recording")):
		return false
	return true

static func record(recorder: RefCounted, sample: Dictionary):
	return recorder.call("on_fast_tick", sample)

static func apply_tile_result(tile_result, out: Dictionary) -> void:
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

static func apply_economy_result(economy_result, out: Dictionary) -> void:
	if economy_result is Dictionary:
		var economy_dict := economy_result as Dictionary
		out["economy_recorded"] = bool(economy_dict.get("recorded", false))
		out["economy_rows"] = int(economy_dict.get("rows", 0))
		out["economy_reason"] = str(economy_dict.get("reason", ""))
		out["economy_epoch_id"] = int(economy_dict.get("epoch_id", -1))
