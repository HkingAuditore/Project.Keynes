extends RefCounted

# CLM2 v9 capture cursors, in codec order. Only the restore writeback installs them.
const FIELDS := ["_last_sea_ice_pass_day", "_last_climate_pass_day", "_climate_dt_cached_day", "_climate_dt_cached_val", "_last_weather_pass_day", "_weather_dt_cached_day", "_weather_dt_cached_val", "_runtime_climate_worker_weather_embed_day", "_runtime_climate_worker_stage_b_call_index", "_last_season_refresh_day", "_last_capture_season_refresh_day"]

static func capture(generator: Object) -> PackedFloat64Array:
	var values := PackedFloat64Array()
	for field in FIELDS:
		values.append(float(generator.get(field)))
	# The accepted capture consumes this season edge before its day can commit.
	values[-1] = float(generator.get("_last_season_refresh_day"))
	return values

static func apply(generator: Object, result: Dictionary) -> void:
	var values: PackedFloat64Array = result.get("restored_capture_cursors", PackedFloat64Array())
	if values.size() != FIELDS.size(): return
	for index in FIELDS.size():
		var prior = generator.get(FIELDS[index])
		generator.set(FIELDS[index], int(values[index]) if prior is int else values[index])
