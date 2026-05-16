extends "res://scripts/simulation/sus/sus_job.gd"
class_name SeasonRefreshJob

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world: WorldData = null
var _stage: int = 0
var _stage_cursor: int = 0
var _season_idx: int = 0
var _round_active: bool = false


func _init(p_generator, p_map: MapData, p_world: WorldData) -> void:
	id = &"season_refresh"
	priority = 50
	slice_budget_ms = 0.55
	max_slices_per_tick = 1
	must_run = false
	generator = p_generator
	map = p_map
	world = p_world
	policy = SusPolicyScript.AlwaysPolicy.new()


func should_run(ctx: SusTickContext) -> bool:
	if generator == null or map == null or world == null:
		return false
	if _round_active:
		return true
	if not generator.has_method("has_pending_season_refresh"):
		return false
	return bool(generator.has_pending_season_refresh())


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or map == null or world == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }

	if not _round_active:
		if generator.has_method("begin_pending_season_refresh"):
			_season_idx = int(generator.begin_pending_season_refresh())
		_stage = 0
		_stage_cursor = 0
		_round_active = true

	var micro_handled: bool = false
	var micro_done: bool = false
	var micro_stage_name: String = ""
	var stage_started: int = _stage
	if generator.has_method("run_season_refresh_stage_micro"):
		var micro: Dictionary = generator.run_season_refresh_stage_micro(map, world, _season_idx, _stage, _stage_cursor)
		micro_handled = bool(micro.get("handled", false))
		if micro_handled:
			_stage_cursor = int(micro.get("cursor", _stage_cursor))
			micro_done = bool(micro.get("done", false))
			micro_stage_name = str(micro.get("stage_name", ""))
			if micro_done:
				_stage += 1
				_stage_cursor = 0

	if not micro_handled and generator.has_method("run_season_refresh_stage"):
		generator.run_season_refresh_stage(map, world, _season_idx, _stage)
		_stage += 1
		_stage_cursor = 0
	if micro_stage_name == "":
		micro_stage_name = _season_stage_name(stage_started)

	# 12 stages：moisture / rain_shadow / redecide / river / veg_fb / shrubland /
	# mangrove / glacier / swamp / sync_current / rebake_biome / consume_feedback。
	# 拆细后每 stage 上界 < 30ms（原 7-stage 时单 stage 可能 ~100ms）。
	var done: bool = _stage >= 12
	if done:
		_round_active = false
		if generator.has_method("finish_season_refresh"):
			generator.finish_season_refresh(map, world, _season_idx)
		_stage = 0
		_stage_cursor = 0

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	var progress: float = 1.0 if done else float(_stage) / 12.0
	if micro_handled and not micro_done and map != null and map.cell_count() > 0:
		progress = (float(_stage) + clampf(float(_stage_cursor) / float(map.cell_count()), 0.0, 1.0)) / 12.0
	return {
		"done": done,
		"work_done": 1,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": progress,
		"stage": stage_started,
		"stage_name": micro_stage_name,
	}


func reset_progress() -> void:
	super.reset_progress()
	_stage = 0
	_stage_cursor = 0
	_round_active = false


func _season_stage_name(stage: int) -> String:
	match stage:
		0: return "stage_0_moisture"
		1: return "stage_1_rain_shadow"
		2: return "stage_2_redecide"
		3: return "stage_3_river"
		4: return "stage_4_veg_feedback"
		5: return "stage_5_shrubland"
		6: return "stage_6_mangrove"
		7: return "stage_7_glacier"
		8: return "stage_8_swamp"
		9: return "stage_9_sync"
		10: return "stage_10_atlas_queue"
		11: return "stage_11_feedback"
		_: return "stage_%d" % stage
