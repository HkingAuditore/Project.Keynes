extends SceneTree


class FaultedGenerator extends MapGenerator:
	func get_runtime_thread_report() -> Dictionary:
		return {"simulation_host_state": "FAULTED",
			"environment_ring_pending": 4, "worker_day_inflight": 1,
			"fault_code": "money_conservation_failed"}


class RuntimeHostStub extends WorldRuntimeHost:
	var test_generator: MapGenerator

	func generator() -> MapGenerator:
		return test_generator


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var generator := FaultedGenerator.new()
	var host := RuntimeHostStub.new()
	host.test_generator = generator
	var clock := WorldClock.new()
	var save = root.get_node("GameSave")
	save.set("_runtime_host", host)
	save.set("_world_clock", clock)
	var boundary: Dictionary = save._can_save()
	var passed := not bool(boundary.get("ok", true)) \
		and String(boundary.get("code", "")) == "worker_faulted" \
		and String(boundary.get("message", "")).contains("money_conservation_failed")
	print("[%s] faulted worker rejects save with its cause before waiting on residual inputs: %s" % [
		"PASS" if passed else "FAIL", JSON.stringify(boundary)])
	save.set("_runtime_host", null)
	save.set("_world_clock", null)
	clock.free()
	host.free()
	quit(0 if passed else 1)
