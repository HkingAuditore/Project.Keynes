extends DCSystem
class_name IdeologyRuntimeSystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
var facade = null
var world_clock: WorldClock = null
var _last_report: Dictionary = {}

func _init(p_facade, p_world_clock: WorldClock = null) -> void:
	id = &"ideology_runtime"
	priority = 82
	must_run = false
	max_slices_per_tick = 1
	use_job_should_run = true
	use_job_deadline_critical = true
	starvation_threshold = 2
	slice_budget_ms = 0.35
	policy = SusPolicyScript.AlwaysPolicy.new()
	facade = p_facade
	world_clock = p_world_clock

func should_run(ctx: SusTickContext) -> bool:
	return facade != null and facade.is_configured() and ctx != null \
		and bool(facade.world_ext().ideology_should_run(ctx.day_index))
func is_deadline_critical(ctx: SusTickContext) -> bool: return ctx != null and should_run(ctx)
func tick(ctx) -> Dictionary:
	if facade == null or not facade.is_configured(): return {"done": true, "stage_name": "ideology_unavailable"}
	var started := Time.get_ticks_usec()
	var result: Dictionary = facade.world_ext().run_ideology_daily(int(ctx.day_index) if ctx != null else 0)
	if facade.has_method("drain_receipts"):
		facade.drain_receipts()
	_last_report = facade.report()
	var done := bool(result.get("done", true))
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"ideology_day_barrier", not done)
	return {"done": done, "work_done": int(result.get("commands_applied", 0)) + int(result.get("active_visits", 0)) + int(result.get("pending_transition_visits", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started) / 1000.0,
		"progress_ratio": float(result.get("progress_ratio", 1.0 if done else 0.0)),
		"stage_name": String(result.get("stage", "ideology_runtime")),
		"path": String(result.get("path", "IDEOLOGY_GRAPH")),
		"cursor_start": int(result.get("cursor_start", 0)),
		"cursor_end": int(result.get("cursor_end", 0)),
		"active_visits": int(result.get("active_visits", 0)),
		"pending_transition_visits": int(result.get("pending_transition_visits", 0)),
		"sparse_idea_scan_count": int(result.get("sparse_idea_scan_count", 0)),
		"dormant_scan_count": int(result.get("dormant_scan_count", 0))}
func last_report() -> Dictionary: return _last_report.duplicate(true)

func reset_progress() -> void:
	super.reset_progress()
	_last_report.clear()
	if world_clock != null and world_clock.has_method("request_simulation_backpressure"):
		world_clock.request_simulation_backpressure(&"ideology_day_barrier", false)
