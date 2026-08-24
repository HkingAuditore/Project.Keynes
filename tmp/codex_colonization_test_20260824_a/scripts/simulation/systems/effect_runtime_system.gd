extends DCSystem
class_name EffectRuntimeSystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var facade = null
var _last_report: Dictionary = {}

func _init(p_facade) -> void:
	id = &"effect_runtime"
	priority = 85
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
		and bool(facade.world_ext().effect_should_run(ctx.day_index))

func is_deadline_critical(ctx: SusTickContext) -> bool:
	return ctx != null and should_run(ctx)

func tick(ctx) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	if facade == null or not facade.is_configured():
		return {"done": true, "stage_name": "effect_unavailable"}
	var day := int(ctx.day_index) if ctx != null else 0
	var result: Dictionary = facade.world_ext().run_effect_daily(day)
	# C++ owns Effect -> Modifier batching. The facade remains the compatibility
	# path for unsupported/custom command domains only.
	# Economy performs generation-safe transaction preflight before any sibling
	# adapter can enqueue the same multi-domain transaction. A permanent Economy
	# rejection therefore cannot leave a newly queued Modifier command behind.
	var native_economy_dispatched: Dictionary = {}
	if facade.world_ext().has_method("dispatch_effect_native_economy"):
		native_economy_dispatched = facade.world_ext().dispatch_effect_native_economy()
	var native_dispatched: Dictionary = {}
	if facade.world_ext().has_method("dispatch_effect_native_modifier"):
		native_dispatched = facade.world_ext().dispatch_effect_native_modifier()
	var native_country_dispatched: Dictionary = {}
	if facade.world_ext().has_method("dispatch_effect_native_country"):
		native_country_dispatched = facade.world_ext().dispatch_effect_native_country()
	var native_gameplay_dispatched: Dictionary = {}
	if facade.world_ext().has_method("dispatch_effect_native_gameplay"):
		native_gameplay_dispatched = facade.world_ext().dispatch_effect_native_gameplay()
	var dispatched: Dictionary = facade.dispatch_transactions()
	_last_report = facade.report()
	return {
		"done": bool(result.get("done", true)),
		"work_done": int(result.get("work_done", 0)),
		"elapsed_ms": float(Time.get_ticks_usec() - started_us) / 1000.0,
		"progress_ratio": float(result.get("progress_ratio", 1.0)),
		"stage_name": String(result.get("stage", "effect_evaluate")),
		"path": "EFFECT_GRAPH",
		"transactions_planned": int(result.get("transactions_planned", 0)),
		"transactions_dispatched": int(dispatched.get("dispatched", 0)),
		"native_modifier_transactions": int(native_dispatched.get("submitted_transactions", 0)),
		"native_modifier_commands": int(native_dispatched.get("submitted_commands", 0)),
		"native_country_transactions": int(native_country_dispatched.get("submitted_transactions", 0)),
		"native_country_commands": int(native_country_dispatched.get("submitted_commands", 0)),
		"native_economy_transactions": int(native_economy_dispatched.get("submitted_transactions", 0)),
		"native_economy_commands": int(native_economy_dispatched.get("submitted_commands", 0)),
		"native_economy_rejected_transactions": int(native_economy_dispatched.get(
			"rejected_transactions", 0)),
		"native_economy_retryable_transactions": int(native_economy_dispatched.get(
			"retryable_transactions", 0)),
		"native_gameplay_transactions": int(native_gameplay_dispatched.get("submitted_transactions", 0)),
		"native_gameplay_commands": int(native_gameplay_dispatched.get("submitted_commands", 0)),
		"legacy_fallback_transactions": int(_last_report.get("legacy_fallback_transactions", 0)),
		"native_claimed_transactions": int(dispatched.get("native_claimed_transactions", 0)),
		"missing_adapters": int(dispatched.get("missing_adapters", 0)),
		"fallback_reason": String(result.get("last_error", "")),
	}

func last_report() -> Dictionary:
	return _last_report.duplicate(true)
