extends DCSystem
class_name WeatherLutUploadSystem

const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const FeatureFlagsScript = preload("res://scripts/data_core/feature_flags.gd")

var baker: MapBakerScript = null
var map: MapData = null
var world_data: WorldData = null
var weather_job = null
var _last_breakdown: Dictionary = {}
var _diag_should_count: int = 0
var _diag_tick_count: int = 0
var _diag_last_should_log_msec: int = -1000000



func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData, p_weather_job = null) -> void:
	id = &"weather_lut_upload"
	priority = 260

	use_job_should_run = true
	must_run = false
	starvation_threshold = 8
	max_slices_per_tick = 1
	slice_budget_ms = 0.25
	baker = p_baker
	map = p_map
	world_data = p_world
	weather_job = p_weather_job


func declare_reads() -> Array[StringName]:
	return [

		DCComponentIds.CELL_WEATHER_TYPE,
		DCComponentIds.CELL_WEATHER_INTENSITY,
		DCComponentIds.CELL_WEATHER_CLOUD,
		DCComponentIds.CELL_WEATHER_PRECIP,
		DCComponentIds.CELL_WEATHER_DIRTY,
	]



func declare_writes() -> Array[StringName]:
	return [
		DCComponentIds.CELL_WEATHER_DIRTY,
	]



func should_run(ctx: SusTickContext) -> bool:
	var active: bool = FeatureFlagsScript.cell_indirection_active()
	var has_inputs: bool = baker != null and map != null and world_data != null
	var weather_ran: bool = true
	var has_weather_job: bool = weather_job != null
	if has_weather_job and weather_job.get("ran_this_tick") != null:
		weather_ran = bool(weather_job.ran_this_tick)
	var should: bool = active and has_inputs and weather_ran
	_diag_should_count += 1
	var now_ms: int = Time.get_ticks_msec()
	if _diag_should_count <= 12 or now_ms - _diag_last_should_log_msec >= 2000:
		_diag_last_should_log_msec = now_ms
		print("[weather-lut][should] #%d tick=%d active=%s inputs=%s has_weather_job=%s weather_ran=%s should=%s lut_dims=%s update_usec=%d" % [
			_diag_should_count,
			int(ctx.tick_index) if ctx != null else -1,
			str(active), str(has_inputs), str(has_weather_job), str(weather_ran), str(should),
			str(world_data.lut_dims if world_data != null else Vector2i.ZERO),
			int(world_data.weather_lut_update_usec) if world_data != null else -1,
		])
	return should





func tick(ctx) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	if baker == null or map == null or world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0, "path": "weather_lut_upload", "reason": "missing_inputs"}
	var dirty_count: int = _weather_dirty_count()
	var stats: Dictionary = _weather_stats()
	var report: Dictionary = baker.refresh_weather_lut_from_weather(map, world_data)
	var elapsed_ms: float = float(Time.get_ticks_usec() - t0) / 1000.0
	report["done"] = true
	report["work_done"] = map.cell_count() if map != null else 0
	report["elapsed_ms"] = elapsed_ms
	report["progress_ratio"] = 1.0
	report["path"] = "weather_lut_upload"
	report["weather_dirty_count"] = dirty_count
	report.merge(stats, true)
	_diag_tick_count += 1
	print("[weather-lut][tick] #%d tick=%d dirty=%d n=%d cloud_max=%.3f cloud_nonzero=%d precip_max=%.3f precip_nonzero=%d type_nonzero=%d has_soa=%s published=%s changed=%s reason=%s elapsed=%.3f update_usec=%d" % [
		_diag_tick_count,
		int(ctx.tick_index) if ctx != null else -1,
		dirty_count,
		int(stats.get("weather_stat_n", 0)),
		float(stats.get("weather_cloud_max", 0.0)),
		int(stats.get("weather_cloud_nonzero", 0)),
		float(stats.get("weather_precip_max", 0.0)),
		int(stats.get("weather_precip_nonzero", 0)),
		int(stats.get("weather_type_nonzero", 0)),
		str(stats.get("weather_has_soa", false)),
		str(report.get("weather_lut_published", false)),
		str(report.get("weather_lut_changed", false)),
		str(report.get("weather_lut_reason", "")),
		elapsed_ms,
		int(world_data.weather_lut_update_usec),
	])
	_last_breakdown = report.duplicate(true)
	_clear_weather_dirty_mask()
	return report



func run_slice(ctx: SusTickContext) -> Dictionary:
	return tick(ctx)


func reset_progress() -> void:
	super.reset_progress()
	_last_breakdown.clear()


func last_breakdown() -> Dictionary:
	return _last_breakdown


func _weather_stats() -> Dictionary:
	var out: Dictionary = {
		"weather_stat_n": 0,
		"weather_has_soa": false,
		"weather_cloud_max": 0.0,
		"weather_cloud_nonzero": 0,
		"weather_precip_max": 0.0,
		"weather_precip_nonzero": 0,
		"weather_type_nonzero": 0,
	}
	if map == null:
		return out
	var n: int = map.cell_count()
	out.weather_stat_n = n
	var has_soa: bool = map.weather_type_arr.size() >= n and map.weather_cloud_arr.size() >= n and map.weather_precip_arr.size() >= n
	out.weather_has_soa = has_soa
	if has_soa:
		for i in range(n):
			var c: float = float(map.weather_cloud_arr[i])
			var p: float = float(map.weather_precip_arr[i])
			out.weather_cloud_max = maxf(float(out.weather_cloud_max), c)
			out.weather_precip_max = maxf(float(out.weather_precip_max), p)
			if c > 0.001:
				out.weather_cloud_nonzero = int(out.weather_cloud_nonzero) + 1
			if p > 0.001:
				out.weather_precip_nonzero = int(out.weather_precip_nonzero) + 1
			if int(map.weather_type_arr[i]) != 0:
				out.weather_type_nonzero = int(out.weather_type_nonzero) + 1
	return out


func _weather_dirty_count() -> int:
	if map == null or map.weather_dirty_mask.is_empty():
		return 0
	var count: int = 0
	for v in map.weather_dirty_mask:
		if int(v) != 0:
			count += 1
	return count



func _clear_weather_dirty_mask() -> void:
	if map == null:
		return
	for i in range(map.weather_dirty_mask.size()):
		map.weather_dirty_mask[i] = 0
