extends RefCounted

const Wait = preload("res://tests/ideology/ideology_worker_wait_helper.gd")

# STOPPED is published before the worker's return signal. Start requires both.
static func stopped(ext: Object, timeout_ms: int) -> bool:
	return Wait.wait_until(func() -> bool:
		var report: Dictionary = ext.get_runtime_thread_report()
		return String(report.get("simulation_host_state", "")) == "STOPPED" \
			and bool(report.get("simulation_executor_exited", false)), timeout_ms)

# A host tick D captures D-1; never wait for an unpublished next input day.
static func committed(w: Dictionary, timeout_ms: int, service: Callable) -> bool:
	var ext: Object = w["ext"]
	var target := maxi(0, int(w["tick"]) - 1)
	Wait.wait_until(func() -> bool:
		var report: Dictionary = ext.get_runtime_thread_report()
		return int(report.get("simulation_committed_day", -1)) >= target \
			or String(report.get("simulation_host_state", "")) in ["STOPPED", "FAULTED"],
		timeout_ms, func() -> void:
			w["host"]._process(0.0)
			service.call())
	return int(ext.get_runtime_thread_report().get("simulation_committed_day", -1)) >= target
