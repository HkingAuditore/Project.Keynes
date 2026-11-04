extends SceneTree

const Session = preload("res://scripts/game/world_session.gd")
const Module = preload("res://scripts/game/runtime_session_module.gd")

class ResourceModule extends RefCounted:
	signal continue_prepare
	signal continue_release
	var id: String
	var log: Array
	var wait_prepare := false
	var wait_release := false
	var reject := false
	var release_fails := false
	var canceled := false
	var allocated := false
	func _init(name: String, events: Array) -> void:
		id = name
		log = events
	func entry(after: PackedStringArray = PackedStringArray()) -> Dictionary:
		return Module.new().configure(id, after, PackedStringArray([id]),
			prepare, cancel, release).descriptor()
	func prepare() -> Dictionary:
		log.append("prepare:" + id)
		allocated = true
		if wait_prepare:
			await continue_prepare
		return {"ok": not reject and not canceled, "code": "fixture_rejected"}
	func cancel() -> void:
		log.append("cancel:" + id)
		canceled = true
		continue_prepare.emit()
	func release() -> Dictionary:
		log.append("release:" + id)
		if wait_release:
			await continue_release
		if release_fails:
			return {"ok": false, "code": "fixture_release_pending"}
		allocated = false
		return {"ok": true}

var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var events: Array = []
	var data := ResourceModule.new("data", events)
	var worker := ResourceModule.new("worker", events)
	var session := Session.new()
	_expect("dependency graph accepts reverse declaration", session.configure([
		worker.entry(PackedStringArray(["data"])), data.entry()]).ok)
	_expect("session prepares all dependencies", (await session.prepare()).ok)
	_expect("data prepared before consumer", events == ["prepare:data", "prepare:worker"])
	_expect("ready admits work", session.accepts_work())
	_expect("composition locks once preparation starts", not session.configure([data.entry()]).ok)
	session.set_running(true)
	_expect("capture enters SAVING", session.begin_capture().ok and session.report().state == "SAVING")
	_expect("no new work while capturing", not session.accepts_work())
	session.end_capture()
	_expect("capture restores running state", session.report().state == "RUNNING")
	worker.wait_release = true
	var closed: Array = []
	_close(session, closed)
	_expect("close immediately rejects stale continuations", not session.is_current(session.generation))
	_expect("close stays pending while worker owns resources", closed.is_empty() and worker.allocated and data.allocated)
	_close(session, closed)
	_expect("concurrent closes share the same release", events.count("release:worker") == 1)
	worker.continue_release.emit()
	_expect("both close callers observe completion", closed.size() == 2 and closed[0].ok and closed[1].ok)
	_expect("release reverses dependency order", events.slice(2) == [
		"cancel:worker", "cancel:data", "release:worker", "release:data"])
	_expect("closed proves resource release", session.report().state == "CLOSED" and not data.allocated and not worker.allocated)
	var count := events.size()
	_expect("close is idempotent", (await session.close()).ok and events.size() == count)
	session.end_capture()
	session.set_running(true)
	_expect("late capture and clock callbacks cannot reopen closed session", not session.accepts_work())

	events = []
	var pending := ResourceModule.new("pending", events)
	pending.wait_prepare = true
	var later := ResourceModule.new("later", events)
	var loading := Session.new()
	loading.configure([pending.entry(), later.entry(PackedStringArray(["pending"]))])
	var prepared: Array = []
	_prepare(loading, prepared)
	_expect("loading allocated partial resources", pending.allocated and prepared.is_empty())
	_expect("loading cancellation closes normally", (await loading.close()).ok)
	_expect("cancel wakes suspended preparation", prepared.size() == 1 and prepared[0].code == "session_cancelled")
	_expect("later module never runs", not later.allocated and not events.has("prepare:later"))
	_expect("partial module is released", not pending.allocated)
	_expect("replacement world has another generation", loading.generation != session.generation)
	_expect("old token rejected by replacement", not loading.is_current(session.generation))

	events = []
	var failing := ResourceModule.new("failing", events)
	failing.reject = true
	var failed := Session.new()
	failed.configure([failing.entry(), later.entry(PackedStringArray(["failing"]))])
	_expect("prepare failure remains explicit", not (await failed.prepare()).ok and failed.report().state == "FAULTED")
	_expect("failed prepare cannot admit new work", not failed.accepts_work())
	failing.release_fails = true
	_expect("failed release is not reported closed", not (await failed.close()).ok and failed.report().state == "FAULTED")
	_expect("failed release retains resource ownership", failing.allocated)
	failing.release_fails = false
	_expect("release can be retried without recanceling", (await failed.close()).ok and events.count("cancel:failing") == 1)
	_expect("failed preparation resource eventually released", not failing.allocated)
	print("world session: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _prepare(session, results: Array) -> void:
	results.append(await session.prepare())

func _close(session, results: Array) -> void:
	results.append(await session.close())

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)
