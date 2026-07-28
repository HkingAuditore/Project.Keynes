class_name ModifierDailySystem
extends DCSystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var facade = null
var _last_report: Dictionary = {}


func _init(p_facade) -> void:
	id = &"modifier_daily"
	priority = 90
	must_run = false
	max_slices_per_tick = 1
	use_job_should_run = true
	use_job_deadline_critical = true
	starvation_threshold = 2
	slice_budget_ms = 0.5
	policy = SusPolicyScript.AlwaysPolicy.new()
	facade = p_facade


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	return facade != null and facade.is_configured() and ctx != null \
		and bool(facade.world_ext().modifier_should_run(ctx.day_index))


func is_deadline_critical(ctx: SusTickContext) -> bool:
	# Expiry and due commands must publish before same-day domain consumers.
	return ctx != null and should_run(ctx)


func tick(ctx) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	if facade == null or not facade.is_configured():
		return {"done": true, "elapsed_ms": 0.0, "stage_name": "modifier_unavailable"}
	var result: Dictionary = facade.world_ext().run_modifier_daily(
		int(ctx.day_index) if ctx != null else 0)
	_last_report = result.duplicate(true)
	facade.dispatch_events()
	return {
		"done": bool(result.get("done", true)),
		"work_done": int(result.get("work_done", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started_us) / 1000.0,
		"progress_ratio": 1.0,
		"stage_name": String(result.get("stage", "modifier_publish")),
		"path": String(result.get("path", "MODIFIER_GRAPH")),
		"commands_applied": int(result.get("commands_applied", 0)),
		"expired": int(result.get("expired", 0)),
	}


func last_report() -> Dictionary:
	return _last_report.duplicate(true)
