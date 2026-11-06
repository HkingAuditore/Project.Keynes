extends SceneTree

const OldHost = preload("res://tests/game/world_runtime_web_reference.gd")
var checks := 0
var failures := 0

class Generator extends MapGenerator:
	var calls: Array = []
	var starts_ok := true
	var daily_calls := 0
	func sus_tick_daily(_clock, _day: int = -1, _phase: float = NAN) -> Dictionary:
		daily_calls += 1
		return {"probe_tick": true}
	func start_runtime_worker(config: Dictionary) -> Dictionary:
		calls.append(config.duplicate(true))
		return {"ok": starts_ok, "code": "probe_start_failed" if not starts_ok else "ok",
			"native_daily_inline": bool(config.get("native_daily_inline", false))}
	func capture_country_worker_inputs() -> Dictionary: return {"ok": true}
	func get_data_core_world_ext(): return null

class Current extends WorldRuntimeHost:
	var web := true
	var worker := false
	var active := true
	func _is_web_build() -> bool: return web
	func _web_worker_requested() -> bool: return worker
	func _resolve_climate_authority_policy() -> Dictionary: return {"enabled": active, "reason": "test_policy"}
	func _sync_runtime_worker_clock() -> void: pass
	func _apply_web_worker_parallel_channels(_active: bool, _started: Dictionary) -> void: pass

class Previous extends OldHost:
	var web := true
	var worker := false
	var active := true
	func _is_web_build() -> bool: return web
	func _web_worker_requested() -> bool: return worker
	func _resolve_climate_authority_policy() -> Dictionary: return {"enabled": active, "reason": "test_policy"}
	func _sync_runtime_worker_clock() -> void: pass
	func _apply_web_worker_parallel_channels(_active: bool, _started: Dictionary) -> void: pass

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	# Expected failure-channel push_error is exercised, but not treated as an unexpected engine error.
	var old_errors := Engine.print_error_messages
	Engine.print_error_messages = false
	for cause in ["neither", "authority", "daily_api", "start_api", "disabled"]:
		for web in [false, true]:
			for escape in [false, true]:
				_case(cause, web, escape)
	Engine.print_error_messages = old_errors
	var host := Current.new()
	_check("escape default off", not host._web_gdscript_daily_fallback_allowed())
	OS.set_environment("PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK", "1")
	_check("environment escape", host._web_gdscript_daily_fallback_allowed())
	OS.set_environment("PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK", "true")
	_check("exact string only", not host._web_gdscript_daily_fallback_allowed())
	OS.unset_environment("PK_WEB_ALLOW_GDSCRIPT_DAILY_FALLBACK")
	host.free()
	# A missing prefetch API must still choose native inline, not reject a working executor.
	host = Current.new()
	host.worker = true
	host._generator = Generator.new()
	host._start_production_shadow_worker()
	_check("missing prefetch preserves native fallback", host._web_worker_inline_fallback and host._native_daily_inline_active and not host.is_runtime_fault_paused())
	host.free()
	print("web daily fallback: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _case(cause: String, web: bool, escape: bool) -> void:
	var current := Current.new()
	var previous := Previous.new()
	var emitted: Array = []
	current.world_generation_failed.connect(func(message: String): emitted.append(message))
	for host in [current, previous]:
		host.web = web
		host.runtime_web_allow_gdscript_daily_fallback = escape
		host._generator = Generator.new()
		host._world_clock = WorldClock.new()
		host._world_clock.auto_start = false
		host._world_clock.pause(false)
		match cause:
			"neither": host.runtime_native_daily_inline = false
			"authority": host.active = false
			"disabled": host.runtime_shadow_on_generate = false
			"start_api": host._generator.starts_ok = false
			"daily_api": host._native_daily_inline_active = true
		if cause == "daily_api":
			host._run_native_daily_inline_day(1, {})
		else:
			host._start_production_shadow_worker()
	var blocked := web and not escape
	_check(cause + " fault decision", current.is_runtime_fault_paused() == blocked)
	_check(cause + " original start calls", current._generator.calls == previous._generator.calls)
	if blocked:
		_check(cause + " clock held", current._world_clock.paused)
		_check(cause + " visible failure signal", emitted.size() == 1 and not emitted[0].is_empty())
		_check(cause + " diagnostic code", String(current.get_runtime_fault_diagnostics().get("fault_code", "")).begins_with("web_"))
		_check(cause + " detailed error", current.last_world_generation_error_text().contains(current._web_worker_start_code))
		current._runtime_ready_for_ticks = true
		_check(cause + " tick blocked", current.run_daily_tick(2, 0.0).is_empty())
		current._clock_day_changed_impl(2)
		_check(cause + " no SUS or counter advance", current._generator.daily_calls == 0 and current._fast_tick_count == 0)
		current._reject_web_daily_fallback("duplicate", "duplicate")
		_check(cause + " single failure notification", emitted.size() == 1)
		current._clear_web_daily_fallback_failure()
		_check(cause + " new session can retry", not current.is_runtime_fault_paused() and not current._world_clock.authority_fault_hold)
		current._runtime_worker_fault_paused = true
		current._runtime_last_fault_diagnostics = {"source": "native_fault"}
		current._clear_web_daily_fallback_failure()
		_check(cause + " native fault retained", current.is_runtime_fault_paused())
	else:
		_check(cause + " original diagnostic", current._web_worker_start_code == previous._web_worker_start_code)
		_check(cause + " original inline flag", current._native_daily_inline_active == previous._native_daily_inline_active)
		_check(cause + " original pause state", current._world_clock.paused == previous._world_clock.paused)
		_check(cause + " no new signal", emitted.is_empty())
	for host in [current, previous]:
		host._world_clock.free()
		host._world_clock = null
		host.free()

func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
		print("[FAIL] " + label)
