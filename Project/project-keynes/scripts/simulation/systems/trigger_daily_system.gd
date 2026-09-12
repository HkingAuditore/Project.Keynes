extends DCSystem
class_name TriggerDailySystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
var facade: TriggerFacade

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
	if facade == null or not facade.is_configured() or ctx == null:
		return false
	# H8: trigger_should_run() already returns false under worker authority. The
	# explicit check keeps the reason readable and covers a world_ext build without
	# the authority gate.
	if _worker_authoritative():
		return false
	return bool(facade.world_ext().trigger_should_run(ctx.day_index))

func _worker_authoritative() -> bool:
	var ext: Object = facade.world_ext() if facade != null else null
	if ext == null or not ext.has_method("trigger_worker_authoritative"):
		return false
	return bool(ext.trigger_worker_authoritative())

func is_deadline_critical(ctx: SusTickContext) -> bool:
	return ctx != null and should_run(ctx)

func tick(ctx) -> Dictionary:
	var started := Time.get_ticks_usec()
	if facade == null or not facade.is_configured(): return {"done": true, "stage_name": "trigger_unavailable"}
	var day := int(ctx.day_index) if ctx != null else 0
	# H8: the worker owns the day. Ingest and effect handoff run inside the native
	# graph pulse under authority, so this system has nothing left to do; running
	# run_trigger_daily here would only get suppressed anyway.
	if _worker_authoritative():
		return {"done": true, "work_done": 0, "progress_ratio": 1.0,
			"elapsed_ms": float(Time.get_ticks_usec() - started) / 1000.0,
			"stage_name": "trigger_evaluate", "path": "TRIGGER_WORKER",
			"suppressed": true, "events_ingested": 0, "effects_dispatched": 0}
	var ingested := facade.ingest_committed_events(day)
	var result: Dictionary = facade.world_ext().run_trigger_daily(day)
	var effects := facade.dispatch_effects()
	return {"done": bool(result.get("done", true)), "work_done": int(result.get("work_done", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started) / 1000.0, "progress_ratio": 1.0,
		"stage_name": String(result.get("stage", "trigger_evaluate")), "path": "TRIGGER_GRAPH",
		"events_ingested": int(ingested.get("accepted", 0)), "effects_dispatched": int(effects.get("dispatched", 0)),
		"fallback_reason": String(result.get("reason", ""))}

# 报告按需构造。原来每 tick 拉一份完整 native 报告只为读一个 gap_count，而这个
# 计数没有下游消费者——诊断需要时直接问 facade 即可。
func last_report() -> Dictionary:
	return facade.report() if facade != null and facade.is_configured() else {}
