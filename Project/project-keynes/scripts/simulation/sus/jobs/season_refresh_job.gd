extends "res://scripts/simulation/sus/sus_job.gd"
class_name SeasonRefreshJob

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world: WorldData = null
var _stage: int = 0
var _season_idx: int = 0
var _round_active: bool = false


func _init(p_generator, p_map: MapData, p_world: WorldData) -> void:
	id = &"season_refresh"
	priority = 50
	slice_budget_ms = 0.0
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
		_round_active = true

	if generator.has_method("run_season_refresh_stage"):
		generator.run_season_refresh_stage(map, world, _season_idx, _stage)
	_stage += 1

	# 12 stages：moisture / rain_shadow / redecide / river / veg_fb / shrubland /
	# mangrove / glacier / swamp / sync_current / rebake_biome / consume_feedback。
	# 拆细后每 stage 上界 < 30ms（原 7-stage 时单 stage 可能 ~100ms）。
	var done: bool = _stage >= 12
	if done:
		_round_active = false
		if generator.has_method("finish_season_refresh"):
			generator.finish_season_refresh(map, world, _season_idx)
		_stage = 0

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	return {
		"done": done,
		"work_done": 1,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0 if done else float(_stage) / 12.0,
	}


func reset_progress() -> void:
	super.reset_progress()
	_stage = 0
	_round_active = false
