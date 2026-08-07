extends DCSystem
class_name IdeologyRuntimeSystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
var facade = null
var _last_report: Dictionary = {}

func _init(p_facade) -> void:
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

func should_run(ctx: SusTickContext) -> bool:
	return facade != null and facade.is_configured() and ctx != null \
		and bool(facade.world_ext().ideology_should_run(ctx.day_index))
func is_deadline_critical(ctx: SusTickContext) -> bool: return ctx != null and should_run(ctx)
func tick(ctx) -> Dictionary:
	if facade == null or not facade.is_configured(): return {"done": true, "stage_name": "ideology_unavailable"}
	var started := Time.get_ticks_usec()
	var result: Dictionary = facade.world_ext().run_ideology_daily(int(ctx.day_index) if ctx != null else 0)
	_last_report = facade.report()
	return {"done": bool(result.get("done", true)), "work_done": int(result.get("commands_applied", 0)) + int(result.get("active_visits", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started) / 1000.0, "progress_ratio": 1.0 if bool(result.get("done", true)) else 0.0,
		"stage_name": String(result.get("stage", "ideology_runtime")), "path": "IDEOLOGY_GRAPH",
		"active_visits": int(result.get("active_visits", 0)), "dormant_scan_count": int(result.get("dormant_scan_count", 0))}
func last_report() -> Dictionary: return _last_report.duplicate(true)
