extends DCSystem
class_name EffectRuntimeSystem

const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var facade = null

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
	# F8: when EFFECT is worker-authoritative, effect_should_run is false and
	# this SUS must not evaluate or dispatch catalog Effects on the main thread.
	if facade == null or not facade.is_configured() or ctx == null:
		return false
	if bool(facade.world_ext().effect_should_run(ctx.day_index)):
		return true
	# ...but family colonization CLAIM/SETTLE transactions are enqueued onto the
	# main EffectRuntime by Economy, not by the worker catalog. dispatch_effect_
	# native_country is deliberately left unsuppressed for them; without this
	# reduced pass nothing ever calls it and expeditions park in SETTLING.
	return _colonization_adapter_pending()


# Cheap predicate so the reduced pass below only wakes while an externally
# enqueued transaction is actually waiting on the Country/Economy adapters.
func _colonization_adapter_pending() -> bool:
	var ext = facade.world_ext()
	if not ext.has_method("get_effect_native_adapter_report"):
		return false
	var report: Dictionary = ext.get_effect_native_adapter_report()
	return not bool(report.get("idle", true))


func is_deadline_critical(ctx: SusTickContext) -> bool:
	return ctx != null and should_run(ctx)


func tick(ctx) -> Dictionary:
	var started_us := Time.get_ticks_usec()
	if facade == null or not facade.is_configured():
		return {"done": true, "stage_name": "effect_unavailable"}
	# Worker owns catalog Effect evaluation. Skip run_effect_daily, the Modifier
	# adapter and the legacy transaction fallback — all of those are suppressed
	# or worker-owned — but still settle Economy-origin colonization
	# transactions, whose CLAIM must reach Country and be ACKed here.
	if facade.world_ext().has_method("get_runtime_thread_report"):
		var report: Dictionary = facade.world_ext().get_runtime_thread_report()
		if bool(report.get("effect_worker_authoritative", false)):
			var claim: Dictionary = {}
			if facade.world_ext().has_method("dispatch_effect_native_country"):
				claim = facade.world_ext().dispatch_effect_native_country()
			if facade.world_ext().has_method("ack_effect_native_country"):
				facade.world_ext().ack_effect_native_country()
			var settle: Dictionary = {}
			if facade.world_ext().has_method("dispatch_effect_native_economy"):
				settle = facade.world_ext().dispatch_effect_native_economy()
			return {
				"done": true,
				"work_done": int(claim.get("submitted_commands", 0))
					+ int(settle.get("submitted_commands", 0)),
				"elapsed_ms": float(Time.get_ticks_usec() - started_us) / 1000.0,
				"progress_ratio": 1.0,
				"stage_name": "effect_worker_colonization_adapters",
				"path": "EFFECT_WORKER",
				"native_country_transactions": int(claim.get(
					"submitted_transactions", 0)),
				"native_country_commands": int(claim.get("submitted_commands", 0)),
				"native_economy_transactions": int(settle.get(
					"submitted_transactions", 0)),
				"native_economy_commands": int(settle.get("submitted_commands", 0)),
			}
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
		"legacy_fallback_transactions": facade.legacy_fallback_transactions() \
			if facade.has_method("legacy_fallback_transactions") else 0,
		"native_claimed_transactions": int(dispatched.get("native_claimed_transactions", 0)),
		"missing_adapters": int(dispatched.get("missing_adapters", 0)),
		"fallback_reason": String(result.get("last_error", "")),
	}

# 报告按需构造。原来每 tick 拉一份完整 native 报告，只为读一个由 GDScript 侧自己
# 维护的 legacy_fallback_transactions。
func last_report() -> Dictionary:
	return facade.report() if facade != null and facade.is_configured() else {}
