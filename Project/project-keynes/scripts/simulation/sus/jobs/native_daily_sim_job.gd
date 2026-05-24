extends DCSystem
class_name NativeDailySimJob

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world: WorldData = null
var _did_run_last_tick: bool = false
var _last_result: Dictionary = {}


func _init(p_generator, p_map: MapData, p_world: WorldData, p_stride: int = 1) -> void:
	generator = p_generator
	map = p_map
	world = p_world
	id = &"native_daily_sim"
	priority = 10
	must_run = true
	max_slices_per_tick = 1
	slice_budget_ms = 1.0
	starvation_threshold = 0
	policy = SusPolicyScript.StridePolicy.new(max(1, p_stride), 0)


func reset_run_flag() -> void:
	_did_run_last_tick = false


func did_run_last_tick() -> bool:
	return _did_run_last_tick


func last_result() -> Dictionary:
	return _last_result.duplicate(true)


func should_run(ctx: SusTickContext) -> bool:
	return generator != null and generator.has_method("run_native_daily_tick_from_job") and super.should_run(ctx)


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	var res: Dictionary = generator.run_native_daily_tick_from_job(ctx, map, world)
	_last_result = res.duplicate(true)
	_did_run_last_tick = int(res.get("rc", -1)) == 0
	var elapsed_ms: float = float(res.get("total_ms", (Time.get_ticks_usec() - t0) / 1000.0))
	return {
		"done": true,
		"work_done": 1 if _did_run_last_tick else 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"stage_name": "native_daily",
	}


func reset_progress() -> void:
	super.reset_progress()
	_did_run_last_tick = false
	_last_result.clear()
