extends DCSystem
class_name TriggerDailySystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
var facade: TriggerFacade
var _last_report: Dictionary = {}

func _init(p_facade: TriggerFacade) -> void:
	id = &"trigger_runtime"
	priority = 80
	must_run = false
	max_slices_per_tick = 1
	use_job_should_run = true
	use_job_deadline_critical = true
	starvation_threshold = 2
	slice_budget_ms = 0.5
	policy = SusPolicyScript.AlwaysPolicy.new()
	facade = p_facade

func should_run(ctx: SusTickContext) -> bool:
	return facade != null and facade.is_configured() and ctx != null \
		and bool(facade.world_ext().trigger_should_run(ctx.day_index))

func is_deadline_critical(ctx: SusTickContext) -> bool:
	return ctx != null and should_run(ctx)

func tick(ctx) -> Dictionary:
	var started := Time.get_ticks_usec()
	if facade == null or not facade.is_configured(): return {"done": true, "stage_name": "trigger_unavailable"}
	var day := int(ctx.day_index) if ctx != null else 0
	var ingested := facade.ingest_committed_events(day)
	var result: Dictionary = facade.world_ext().run_trigger_daily(day)
	var effects := facade.dispatch_effects()
	_last_report = facade.report()
	return {"done": bool(result.get("done", true)), "work_done": int(result.get("work_done", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started) / 1000.0, "progress_ratio": 1.0,
		"stage_name": String(result.get("stage", "trigger_evaluate")), "path": "TRIGGER_GRAPH",
		"events_ingested": int(ingested.get("accepted", 0)), "effects_dispatched": int(effects.get("dispatched", 0)),
		"gap_count": int(_last_report.get("gap_count", 0)), "fallback_reason": String(result.get("reason", ""))}

func last_report() -> Dictionary: return _last_report.duplicate(true)
