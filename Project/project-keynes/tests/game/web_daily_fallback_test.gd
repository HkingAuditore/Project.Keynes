extends SceneTree

var checks := 0
var failures := 0


class GeneratorProbe extends MapGenerator:
	var starts: Array[bool] = []
	var worker_available := true
	var inline_available := true

	func start_runtime_worker(config: Dictionary) -> Dictionary:
		var inline_mode := bool(config.get("native_daily_inline", false))
		starts.append(inline_mode)
		var available := inline_available if inline_mode else worker_available
		return {"ok": available, "code": "probe_start_failed", "native_daily_inline": inline_mode}

	func capture_country_worker_inputs() -> Dictionary:
		return {"ok": true}

	func initialize_world_environment(_history: Array = []) -> Dictionary:
		return {"ok": true}

	func get_data_core_world_ext():
		return null


class WebHost extends WorldRuntimeHost:
	var worker_requested := false

	func _is_web_build() -> bool:
		return true

	func _web_worker_requested() -> bool:
		return worker_requested

	func _sync_runtime_worker_clock() -> void:
		pass


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_case("use native inline", false, true, true, true, [true])
	_case("use native worker", true, true, true, true, [false])
	_case("worker rejection falls back to native inline", true, true, false, true, [false, true])
	_case("both native starts fail", true, true, false, false, [false, true], "web_native_start_failed")
	_case("neither native executor requested", false, false, true, true, [], "web_native_executor_not_requested")
	print("web daily fallback: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _case(label: String, worker_requested: bool, allow_inline: bool, worker_available: bool,
		inline_available: bool, expected_starts: Array, expected_fault: String = "") -> void:
	var host := WebHost.new()
	var clock := WorldClock.new()
	var generator := GeneratorProbe.new()
	var failures_seen: Array[String] = []
	generator.inline_available = inline_available
	generator.worker_available = worker_available
	host.worker_requested = worker_requested
	host.runtime_native_daily_inline = allow_inline
	host._world_clock = clock
	host._generator = generator
	host.world_generation_failed.connect(func(message: String): failures_seen.append(message))
	var print_errors := Engine.print_error_messages
	Engine.print_error_messages = false
	host._start_runtime_executor()
	Engine.print_error_messages = print_errors

	_check(label + " uses the expected native start sequence", generator.starts == expected_starts)
	if expected_fault.is_empty():
		_check(label + " starts without a runtime fault", host._web_worker_start_ok
			and not host.is_runtime_fault_paused() and failures_seen.is_empty()
			and host._native_daily_inline_active == expected_starts.back())
	else:
		_check(label + " holds the clock and reports why",
			host.is_runtime_fault_paused() and clock.authority_fault_hold and clock.paused
			and host.get_runtime_fault_diagnostics().get("fault_code") == expected_fault
			and failures_seen.size() == 1 and not failures_seen[0].is_empty())
		_check(label + " cannot admit a date through the failed runtime",
			host._admit_runtime_calendar(2) == -1 and not host._native_environment_active)
		host._reject_web_daily_fallback("duplicate", "duplicate")
		_check(label + " emits one failure notification", failures_seen.size() == 1)
		host._clear_web_daily_fallback_failure()
		_check(label + " leaves a new session free to retry",
			not host.is_runtime_fault_paused() and not clock.authority_fault_hold)
		host._runtime_worker_fault_paused = true
		host._runtime_last_fault_diagnostics = {"source": "native_fault"}
		host._clear_web_daily_fallback_failure()
		_check(label + " preserves a native simulation fault", host.is_runtime_fault_paused())

	host._world_clock = null
	host._generator = null
	host.free()
	clock.free()


func _check(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
		print("[FAIL] " + label)
