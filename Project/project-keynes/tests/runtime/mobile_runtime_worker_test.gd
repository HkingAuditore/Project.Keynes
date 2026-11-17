extends "res://tests/runtime/runtime_load_daily_test.gd"

# Substitute only platform predicates; execute the real session/clock/native path.
class MobileHost extends WorldRuntimeHost:
	var selector: RefCounted
	var reference_inline := false
	func _native_daily_inline_requested() -> bool:
		return true if reference_inline else selector._native_daily_inline_requested(self)

var _reference_inline := false
var _platform := "android"
var _day_calls_ms: Array[float] = []
var _service_calls_ms: Array[float] = []

func _create_host() -> WorldRuntimeHost:
	for arg in OS.get_cmdline_user_args():
		if arg == "--reference-inline": _reference_inline = true
		if arg.begins_with("--platform="): _platform = arg.trim_prefix("--platform=")
	var source := FileAccess.get_file_as_string("res://scripts/game/world_runtime_daily_adapter_part1.gd")
	for feature in ["android", "ios", "mobile", "web"]:
		source = source.replace('OS.has_feature("%s")' % feature,
			"true" if feature == _platform or feature == "mobile" else "false")
	var script := GDScript.new()
	script.source_code = source
	_expect("mobile production selector compiles", script.reload() == OK)
	var selector: RefCounted = script.new()
	var policy_host := WorldRuntimeHost.new()
	for value in ["0", "1"]:
		OS.set_environment("PK_MOBILE_NATIVE_WORKER", value)
		_expect("explicit mobile executor override " + value,
			selector._native_daily_inline_requested(policy_host) == (value == "0"))
	OS.unset_environment("PK_MOBILE_NATIVE_WORKER")
	policy_host.free()
	var host := MobileHost.new()
	host.selector = script.new()
	host.reference_inline = _reference_inline
	_expect("mobile default keeps full-day execution off the main thread",
		_reference_inline or not host._native_daily_inline_requested())
	return host

func _run_day(host: WorldRuntimeHost, economy, clock: WorldClock, day: int) -> Dictionary:
	var ext: Object = economy.world_ext()
	if day == 1:
		_expect("actual executor matches selected mobile mode",
			bool(ext.get_runtime_thread_report().get("native_daily_inline", false)) == _reference_inline)
	# No player controller or UI refresh is needed to resume the worker.
	clock.current_day = float(day + 1)
	var started := Time.get_ticks_usec()
	host._on_clock_day_changed(day + 1)
	_day_calls_ms.append(float(Time.get_ticks_usec() - started) / 1000.0)
	for slice in range(MAX_SLICES_PER_DAY):
		started = Time.get_ticks_usec()
		host._process(0.0)
		_service_calls_ms.append(float(Time.get_ticks_usec() - started) / 1000.0)
		var runtime: Dictionary = ext.get_runtime_thread_report()
		if String(runtime.get("simulation_host_state", "")) == "FAULTED":
			return {"fatal": true, "fatal_reason": runtime.get("fault_code", "worker_fault")}
		if int(runtime.get("simulation_committed_day", -1)) == day:
			var report: Dictionary = ext.get_economy_report()
			if not report.get("report_boundary_pending", false) and int(report.get("last_completed_sample_day", -1)) == day:
				report["done"] = true
				if day == 15:
					clock.pause(true)
					for frame in 3:
						host._process(0.0)
						await process_frame
					_expect("pause holds the committed date", ext.get_runtime_thread_report().get("simulation_committed_day", -1) == day)
					clock.set_speed(50.0)
					clock.pause(false)
				if day == _observation_days():
					_expect("worker never invokes full inline days", _reference_inline or host._runtime_native_daily_inline_days == 0)
					print("MOBILE_EXECUTION=" + JSON.stringify({"platform": _platform, "inline": _reference_inline,
						"day_calls_ms": _day_calls_ms, "service_calls_ms": _service_calls_ms}))
				return report
		await process_frame
	return {"fatal": true, "fatal_reason": "mobile_day_did_not_commit"}
