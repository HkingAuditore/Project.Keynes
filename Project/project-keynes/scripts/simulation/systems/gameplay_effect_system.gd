extends DCSystem
class_name GameplayEffectSystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var facade: EffectFacade
var _last_report: Dictionary = {}

func _init(p_facade: EffectFacade) -> void:
	id = &"gameplay_effect"
	priority = 95
	must_run = false
	max_slices_per_tick = 1
	use_job_should_run = true
	use_job_deadline_critical = true
	starvation_threshold = 2
	slice_budget_ms = 0.25
	policy = SusPolicyScript.AlwaysPolicy.new()
	facade = p_facade

func should_run(ctx: SusTickContext) -> bool:
	return facade != null and facade.is_configured() and ctx != null \
		and facade.world_ext().has_method("gameplay_effect_should_run") \
		and bool(facade.world_ext().gameplay_effect_should_run(ctx.day_index))

func is_deadline_critical(ctx: SusTickContext) -> bool:
	return ctx != null and should_run(ctx)

func tick(ctx) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	if facade == null or not facade.is_configured():
		return {"done": true, "stage_name": "gameplay_effect_unavailable"}
	var ext: Object = facade.world_ext()
	var day := int(ctx.day_index) if ctx != null else 0
	var result: Dictionary = ext.run_gameplay_effects(day)
	var effect_ack: Dictionary = ext.ack_effect_native_gameplay() \
		if ext.has_method("ack_effect_native_gameplay") else {}
	_last_report = result.duplicate(true)
	return {
		"done": bool(result.get("done", true)),
		"work_done": int(result.get("committed", 0)) + int(result.get("rejected", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started_us) / 1000.0,
		"progress_ratio": 1.0 if bool(result.get("done", true)) else 0.0,
		"stage_name": String(result.get("stage", "gameplay_effect")),
		"path": String(result.get("path", "GAMEPLAY_EFFECT")),
		"effect_native_acked": int(effect_ack.get("acknowledged", 0)),
	}

func last_report() -> Dictionary:
	return _last_report.duplicate(true)
