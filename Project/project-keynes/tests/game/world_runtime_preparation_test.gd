extends SceneTree
const Adapter = preload("res://scripts/game/world_runtime_preparation.gd")
const Reference = preload("res://tests/game/world_runtime_preparation_reference.gd")
var checks := 0
var failures := 0

class Steps extends RefCounted:
	var calls: Array = []
	var tree: SceneTree
	var cancel_at := ""
	var active := true
	func bind_renderer(area):
		calls.append(["bind", area])
		await tree.process_frame
		if cancel_at == "bind": active = false
	func next_frame():
		calls.append("frame")
		await tree.process_frame
		if cancel_at == "frame": active = false
	func is_active(): return active
	func failure(): return {"ok": false, "code": "session_cancelled"}
	func progress(step, enabled): calls.append(["progress", step, enabled])
	func loading(step): calls.append(["loading", step])
	func defer_catalog(): calls.append("defer")
	func refresh():
		calls.append("catalog")
		return {"ok": true}

class Generator extends RefCounted:
	var calls: Array = []
	var stop := {"ok": true, "pending": true}
	var reports: Array = []
	func request_runtime_stop():
		calls.append("stop")
		return stop
	func get_runtime_thread_report():
		calls.append("report")
		return reports.pop_front()
	func frame(): calls.append("frame")

func _init(): call_deferred("run")
func run():
	for cancellation in ["", "bind", "frame"]:
		var left := Steps.new()
		var right := Steps.new()
		left.tree = self
		right.tree = self
		left.cancel_at = cancellation
		right.cancel_at = cancellation
		var old := Reference.new()
		old._session_frames = left
		old.bind_renderer = left.bind_renderer
		old.is_active = left.is_active
		old.failure = left.failure
		old.advance_progress = left.progress
		old.loading_step = left.loading
		old.defer_catalog = left.defer_catalog
		old.refresh_catalog = left.refresh
		var expected: Dictionary = await old._prepare_world_presentation()
		var actual: Dictionary = await Adapter.prepare_presentation(Rect2(), right.bind_renderer,
			right.is_active, right.failure, right, right.progress, right.loading,
			right.defer_catalog, right.refresh)
		check("prepare result " + cancellation, expected == actual)
		check("prepare ordered callbacks " + cancellation, left.calls == right.calls)
	for case in [
		{"stop": {"ok": false, "code": "rejected"}, "reports": []},
		{"stop": {"ok": true}, "reports": []},
		{"stop": {"ok": true, "pending": true}, "reports": [{}]},
		{"stop": {"ok": true, "pending": true}, "reports": [
			{"simulation_executor_exited": false, "simulation_host_state": "FAULTED"},
			{"simulation_executor_exited": false}, {"simulation_executor_exited": true}]}]:
		var left := Generator.new()
		var right := Generator.new()
		for generator in [left, right]:
			generator.stop = case.stop.duplicate(true)
			generator.reports = case.reports.duplicate(true)
		var old := Reference.new()
		old._generator = left
		old.next_frame = left.frame
		var expected: Dictionary = await old._stop_previous_runtime_worker()
		var actual: Dictionary = await Adapter.stop_worker(right, right.frame)
		check("stop result", expected == actual)
		check("stop/exit/frame ordering", left.calls == right.calls)
	var host := WorldRuntimeHost.new()
	check("unbound host stop needs no tree", (await host._stop_previous_runtime_worker()) == {"ok": true})
	host.free()
	print("host preparation: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
func check(label: String, ok: bool):
	checks += 1
	if not ok:
		failures += 1
		push_error(label)
