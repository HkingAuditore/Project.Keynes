extends SceneTree

const Reference = preload("res://tests/game/world_runtime_lifecycle_reference.gd")
var checks := 0
var failures := 0

class RestartGenerator extends RefCounted:
	var reports := 0
	var capture_ok := true
	func request_runtime_stop() -> Dictionary:
		return {"ok": true}
	func get_runtime_thread_report() -> Dictionary:
		reports += 1
		return {"simulation_host_state": "STOPPED", "simulation_executor_exited": reports > 1}
	func capture_country_worker_inputs() -> Dictionary:
		return {"ok": capture_ok, "code": "ok" if capture_ok else "test_capture_refused"}

class RestartHost extends RefCounted:
	var _generator := RestartGenerator.new()
	var _country_worker_transport_capture := {}
	var runtime_shadow_on_generate := true
	var _web_worker_start_ok := false
	var _web_worker_start_code := "test_start_refused"
	var start_ok := true
	var starts := 0
	func climate_authority_diagnostics() -> Dictionary: return {}
	func _resolve_climate_authority_policy() -> Dictionary: return {"enabled": true}
	func _service_country_worker_transport() -> void: pass
	func _consume_country_worker_read_view_if_authoritative() -> void: pass
	func _start_production_shadow_worker() -> void:
		starts += 1
		_web_worker_start_ok = start_ok

class RejectedPolicyHost extends WorldRuntimeHost:
	func _restart_worker_with_current_policy() -> Dictionary:
		return {"ok": false, "code": "test_start_refused"}

func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] %s" % label)

func _init() -> void:
	var host := FileAccess.get_file_as_string("res://scripts/game/world_runtime_host.gd")
	var lifecycle := FileAccess.get_file_as_string("res://scripts/game/world_runtime_lifecycle.gd")
	for method in Reference.HOST_METHODS:
		_check("host keeps " + method, host.contains(method))
	for method in Reference.LIFECYCLE_METHODS:
		_check("lifecycle owns " + method, lifecycle.contains(method))
	_check("host delegates close", host.contains("return await _lifecycle.close_world(self)"))
	_check("stop precedes world release", lifecycle.find("await host._stop_previous_runtime_worker()") < lifecycle.find("host._current_map = null"))
	_check("presentation release detaches renderer", lifecycle.contains("host._renderer.set_world_ext(null)"))
	_check("web fallback source untouched", host.contains("runtime_web_allow_gdscript_daily_fallback"))
	_check_restart_boundaries()
	print("world runtime lifecycle: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _check_restart_boundaries() -> void:
	var adapter := preload("res://scripts/game/world_runtime_lifecycle.gd").new()
	var rejected := RestartHost.new()
	rejected._generator.capture_ok = false
	var result: Dictionary = adapter.restart_worker_with_current_policy(rejected)
	_check("restart waits for executor return beyond STOPPED", rejected._generator.reports == 2)
	_check("capture failure reaches the caller", not result.get("ok", true) and result.get("code", "") == "test_capture_refused")
	_check("capture failure does not start an executor", rejected.starts == 0)
	var failed := RestartHost.new()
	failed.start_ok = false
	result = adapter.restart_worker_with_current_policy(failed)
	_check("start failure reaches the caller", not result.get("ok", true) and result.get("code", "") == "test_start_refused")
	var accepted := RestartHost.new()
	result = adapter.restart_worker_with_current_policy(accepted)
	_check("successful restart reports success", result.get("ok", false) and accepted.starts == 1)
	var public_host := RejectedPolicyHost.new()
	result = public_host.set_climate_authority_override("force_on")
	_check("public policy setter propagates restart failure", not result.get("ok", true) and result.get("code", "") == "test_start_refused")
	public_host.free()
