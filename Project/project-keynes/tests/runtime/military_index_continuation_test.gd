extends SceneTree

class Facade extends RefCounted:
	func is_configured() -> bool: return true
	func poll_events(after: int, _limit: int) -> Array:
		return [{"id": 1, "type": 40, "day": 21}] if after < 1 else []
class Bus extends RefCounted:
	var count := 0
	func publish_events_batch(batch: Dictionary) -> void: count += int(batch.count)

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var ext := DCWorldExt.new()
	var result: Dictionary = ext.runtime_military_self_test()
	print("MILITARY_INDEX_SELF_TEST=" + JSON.stringify(result))
	ext = null
	var script = load("res://scripts/simulation/systems/military_daily_system.gd")
	var facade := Facade.new()
	var first_bus := Bus.new()
	var original = script.new(facade, null, null, first_bus)
	var reason := String(result.get("reason", ""))
	var ok := bool(result.get("ok", false)) and reason.contains("index heads next inactive payload and free-slot order match field by field") and reason.contains("PKMI v1 explicitly refused") and reason.contains("cyclic index rejected without modifying live state")
	ok = original.forward_military_events() == 1 and first_bus.count == 1 and ok
	var saved: PackedInt64Array = original.capture_event_progress()
	var second_bus := Bus.new()
	var restored = script.new(facade, null, null, second_bus)
	ok = restored.restore_event_progress(saved) and ok
	ok = restored.capture_event_progress() == saved and ok
	ok = restored.forward_military_events() == 0 and second_bus.count == 0 and ok
	ok = not restored.restore_event_progress(PackedInt64Array([-1, -1, 0])) and ok
	ok = restored.capture_event_progress() == saved and ok
	var cold_facade = load("res://scripts/military/military_facade.gd").new()
	ok = cold_facade.restore_pending_event_progress(saved) and ok
	var late_job = script.new(cold_facade)
	ok = late_job.capture_event_progress() == saved and cold_facade.take_restored_event_progress().is_empty() and ok
	var adapter = load("res://scripts/game/save_modules/country_state.gd").new()
	var bad: Dictionary = adapter._restore_military_provider({"pkmi": PackedByteArray([1, 2, 3])}, {"military": facade})
	ok = not bool(bad.get("ok", true)) and String(bad.get("code", "")) == "military_forwarder_version_mismatch" and ok
	print("MILITARY_EVENT_CURSOR: old war forwarded once, restore exact, no duplicate, invalid rejected: " + str(ok))
	quit(0 if ok else 1)
