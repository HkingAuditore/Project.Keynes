extends SceneTree

class WaitingHost extends WorldRuntimeHost:
	var waiting := false
	func begin_state_capture() -> Dictionary:
		return {"ok": true}
	func annual_reports_waiting_for_year(_year: int) -> bool:
		return waiting

class HeldRepository extends RefCounted:
	var gate := Semaphore.new()
	var runs := 0
	func verify_slots_background(completion: Array) -> void:
		runs += 1
		gate.wait()
		completion.append([{"slot_id": "manual_1", "loadable": false, "integrity_checked": true}])

var verifications: Array = []

var failures := 0
var checks := 0
var save_result: Dictionary = {}

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	# Load after autoload registration: the coordinator uses GameSettings/GameFlow.
	var service = load("res://tests/game/fixtures/session_save_coordinator.gd").new()
	root.add_child(service)
	service._register_providers()
	var first := WorldClock.new()
	first.auto_start = false
	var second := WorldClock.new()
	second.auto_start = false
	root.add_child(first)
	root.add_child(second)
	first.set_process(false)
	second.set_process(false)
	var host := WaitingHost.new()
	service.bind_runtime(host, first, null)
	service._last_autosave_year = 10
	service.bind_runtime(host, second, null)
	second.year_changed.emit(1)
	await process_frame
	_expect("new game saves year one despite previous year ten", service.autosaves == ["year_1"])
	var generation: int = service._runtime_generation
	service.bind_runtime(host, second, null)
	_expect("rebinding the same session is idempotent", service._runtime_generation == generation)
	first.year_changed.emit(99)
	await process_frame
	_expect("old clock is disconnected", service.autosaves.size() == 1 and service._last_autosave_year == 1)
	second.year_changed.emit(2)
	service.bind_runtime(host, first, null)
	await process_frame
	_expect("deferred old-session autosave is cancelled", service.autosaves.size() == 1)
	host.waiting = true
	first.year_changed.emit(1)
	await process_frame
	service.bind_runtime(host, second, null)
	host.waiting = false
	await process_frame
	await process_frame
	_expect("autosave waiting for annual reports cannot cross sessions", service.autosaves.size() == 1)
	second.paused = true
	_start_manual_save(service)
	await process_frame
	first.paused = false
	first.speed_multiplier = 7.0
	service.bind_runtime(host, first, null)
	await process_frame
	await process_frame
	_expect("boundary wait is cancelled on session change", save_result.get("code") == "save_session_changed")
	_expect("cancelled save leaves new clock unchanged", not first.paused and first.speed_multiplier == 7.0)
	_expect("cancelled capture releases busy state", not service._busy)
	var clock_provider = _provider(service, "world_clock")
	var restored: Dictionary = clock_provider.restore_sections({"world_clock": {
		"schema": "WorldClock", "version": 1, "current_day": 365.0 * 8,
		"last_day": 365 * 8, "last_year": 8}}, service._provider_context(host, null, true, 1.0))
	_expect("loading aligns autosave marker with saved year", bool(restored.ok) and service._last_autosave_year == 8)
	first.free()
	_expect("scene exit releases runtime references", service._world_clock == null and service._runtime_host == null)
	var missing: Dictionary = await service.request_manual_save("manual_1")
	_expect("save outside a game returns an error safely", missing.get("code") == "save_runtime_missing")
	var repository := HeldRepository.new()
	service._repository = repository
	_verify_slots(service)
	_verify_slots(service)
	await process_frame
	repository.gate.post()
	while verifications.size() < 2:
		await process_frame
	_expect("concurrent menu requests share one verification job", repository.runs == 1)
	_expect("all waiters receive completed verification", bool(verifications[0][0].integrity_checked) and bool(verifications[1][0].integrity_checked))
	service.free()
	second.free()
	host.free()
	print("save session: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _verify_slots(service) -> void:
	verifications.append(await service.list_slots_verified())

func _start_manual_save(service) -> void:
	save_result = await service.request_manual_save("manual_1")

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)


func _provider(service, id: String):
	for provider in service._providers:
		if String(provider.provider_id()) == id:
			return provider
	return null
