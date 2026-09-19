extends DCSystem
class_name BioOccupancyDailySystem

## Daily occupancy: established stands persist unless climate leaves a margin
## around the envelope (vegetation succession and carrier IMEX do not instantly
## extinct). Agricultural introduce and neighbor diffusion still require the
## strict envelope plus carrier. Native authority is `run_bio_occupancy_pass`.
## Country knowledge is submitted only for 0→1 occupancy on explored cells.

const _SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world_clock = null
var diffusion_stride: int = 8
var _last_path: String = "none"
var slice_enabled: bool = false
var execution_mode: String = "auto"
var _round_active: bool = false
var _round_slice_cells: int = 2048
var _round_native_ms: float = 0.0
var _round_processed_cells: int = 0
var _round_slice_enabled: bool = false
var _round_count: int = 0
var _full_round_ema_ms: float = 0.0
var _throughput_cells_per_ms: float = 0.0


func _init(p_generator, p_map: MapData, p_diffusion_stride: int = 8) -> void:
	id = &"bio_occupancy_daily"
	priority = 121
	slice_budget_ms = 0.40
	execution_mode = String(Engine.get_meta(&"bio_occupancy_execution_mode", "auto")).to_lower()
	if execution_mode not in ["auto", "oneshot", "sliced"]:
		execution_mode = "auto"
	if bool(Engine.get_meta(&"bio_occupancy_slice_enabled", false)):
		execution_mode = "sliced"
	# A sliced round is a same-day transaction, but it remains cooperative:
	# one deterministic cell range per scheduler visit, with WorldClock frozen
	# until the staging buffer is fully committed.
	max_slices_per_tick = 1
	must_run = false
	generator = p_generator
	map = p_map
	if generator != null:
		world_clock = generator.get("_world_clock_ref")
	diffusion_stride = maxi(1, p_diffusion_stride)
	policy = _SusPolicyScript.StridePolicy.new(1, 0)


func declare_reads() -> Array[StringName]:
	return [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_TEMP_30D,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_IS_WATER,
		DCComponentIds.CELL_HAS_RIVER,
		DCComponentIds.CELL_EXPLORED,
		DCComponentIds.CELL_RES_PASTURE_RESERVE,
		DCComponentIds.CELL_RES_WILD_GAME_RESERVE,
		DCComponentIds.CELL_RES_ARABLE_LAND_RESERVE,
		DCComponentIds.CELL_RES_PADDY_LAND_RESERVE,
		DCComponentIds.CELL_RES_PLANTATION_LAND_RESERVE,
		DCComponentIds.CELL_LANDMASS_ID,
		DCComponentIds.CELL_PROVINCE_ID,
	]


func declare_writes() -> Array[StringName]:
	return [DCComponentIds.CELL_BIO_OCCUPANCY_BITS]


func declare_pools() -> Array[StringName]:
	return [DCComponentIds.POOL_CELLS]


func feature_flag() -> StringName:
	return &""


func tick(ctx) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	if generator == null or map == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}
	var day_index := 0
	if ctx != null:
		day_index = int(ctx.day_index)
	var run_diffusion := (day_index % diffusion_stride) == 0
	if not _round_active:
		_round_active = true
		_round_native_ms = 0.0
		_round_processed_cells = 0
		_round_slice_enabled = _choose_sliced(map.cell_count())
		_round_slice_cells = clampi(
			int(round(_throughput_cells_per_ms * 0.75)) if _throughput_cells_per_ms > 0.0 else 2048,
			2048, 32768)
	slice_enabled = _round_slice_enabled
	var res: Dictionary = {}
	if generator.has_method("run_bio_occupancy_pass_native"):
		res = generator.run_bio_occupancy_pass_native(
			map, run_diffusion, day_index, slice_enabled, _round_slice_cells)
	_last_path = str(res.get("path", "none"))
	var done := bool(res.get("done", true))
	_round_native_ms += float(res.get("native_compute_ms", 0.0))
	_round_processed_cells += int(res.get("processed_cells", 0))
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"bio_occupancy_day_barrier", slice_enabled and not done)
	if done:
		_submit_occupancy_discoveries(res, day_index)
		_finish_round_timing()
	var elapsed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	return {
		"done": done,
		"work_done": int(res.get("processed_cells", map.cell_count())),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": float(res.get("progress_ratio", 1.0)),
		"stage_name": "bio_occupancy_daily",
		"path": _last_path,
		"run_diffusion": run_diffusion,
		"newly_occupied": int((res.get("newly_occupied_cells", PackedInt32Array()) as PackedInt32Array).size()),
		"processed_cells": int(res.get("processed_cells", map.cell_count())),
		"native_compute_ms": float(res.get("native_compute_ms", 0.0)),
		"bridge_ms": float(res.get("bridge_ms", 0.0)),
		"publish_ms": float(res.get("publish_ms", 0.0)),
		"native_ms": float(res.get("native_ms", elapsed_ms)),
		"published_to_slot": bool(res.get("published_to_slot", false)),
		"bio_occupancy_slice_enabled": slice_enabled,
		"bio_slice_native_ms": float(res.get("bio_slice_native_ms", 0.0)),
		"bio_slice_publish_ms": float(res.get("bio_slice_publish_ms", 0.0)),
		"bio_knob_cache_hit": bool(res.get("bio_knob_cache_hit", false)),
		"bio_knob_cache_build_ms": float(res.get("bio_knob_cache_build_ms", 0.0)),
		"bio_slice_fallback_reason": str(res.get("bio_slice_fallback_reason", "")),
		"fallback_reason": str(res.get("fallback_reason", "")),
		"fail_stage": str(res.get("fail_stage", "")),
	}


func _choose_sliced(cell_count: int) -> bool:
	if execution_mode == "oneshot":
		return false
	if execution_mode == "sliced":
		return true
	if _round_count == 0:
		return cell_count > 50000
	return _full_round_ema_ms > 1.25


func _finish_round_timing() -> void:
	if _round_native_ms > 0.0:
		var sample_throughput := float(_round_processed_cells) / _round_native_ms
		_throughput_cells_per_ms = sample_throughput if _throughput_cells_per_ms <= 0.0 \
			else lerpf(_throughput_cells_per_ms, sample_throughput, 0.25)
		_full_round_ema_ms = _round_native_ms if _round_count == 0 \
			else lerpf(_full_round_ema_ms, _round_native_ms, 0.25)
	_round_count += 1
	_round_active = false


func _submit_occupancy_discoveries(res: Dictionary, day_index: int) -> void:
	if bool(res.get("native_evidence_submission", false)):
		return
	if generator == null or not generator.has_method("get_country_facade") \
			or not generator.has_method("gameplay_start_report"):
		return
	var facade = generator.get_country_facade()
	if facade == null:
		return
	var start_cell := int(generator.gameplay_start_report().get("cell", -1))
	if start_cell < 0:
		return
	var handle := int(facade.cell_summary(start_cell).get("country_handle", 0))
	if handle == 0:
		return
	var cells: PackedInt32Array = res.get("newly_occupied_cells", PackedInt32Array())
	var signals: PackedInt32Array = res.get("newly_occupied_signal_ids", PackedInt32Array())
	if cells.size() != signals.size() or cells.is_empty():
		return
	var ext = generator.get_data_core_world_ext() if generator.has_method(
		"get_data_core_world_ext") else null
	if ext == null or not ext.has_method("filter_bio_research_observations"):
		return
	var filtered: Dictionary = ext.filter_bio_research_observations(cells, signals)
	if not bool(filtered.get("ok", false)):
		return
	var eligible_cells: PackedInt32Array = filtered.get(
		"observation_cells", PackedInt32Array())
	var eligible_signals: PackedInt32Array = filtered.get(
		"observation_signals", PackedInt32Array())
	if not eligible_cells.is_empty():
		facade.submit_observation_batch(handle, eligible_cells, eligible_signals,
			day_index + 1)
