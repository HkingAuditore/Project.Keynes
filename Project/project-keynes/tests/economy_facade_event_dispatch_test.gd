extends SceneTree

const EconomyFacadeScript = preload("res://scripts/economy/economy_facade.gd")

class FakeProfile extends RefCounted:
	var economy_trace_poll_max_events: int = 4096


class FakeWorldExt extends RefCounted:
	var poll_calls: int = 0
	var ack_calls: int = 0
	var last_acked: int = 0

	func poll_economy_events(_opts: Dictionary) -> Dictionary:
		poll_calls += 1
		return {"ok": true, "count": 2, "last_event_id": 44}

	func ack_economy_events(_consumer_id: StringName, up_to_event_id: int) -> Dictionary:
		ack_calls += 1
		last_acked = up_to_event_id
		return {"ok": true, "acked_event_id": up_to_event_id}


var failures := 0
var available_count := 0
var received_count := 0


func _init() -> void:
	var facade = EconomyFacadeScript.new()
	var ext := FakeWorldExt.new()
	facade._configured = true
	facade._world_ext = ext
	facade._profile = FakeProfile.new()

	facade.economy_event_batch_available.connect(func(_meta: Dictionary) -> void:
		available_count += 1)
	var skipped: Dictionary = facade.dispatch_committed_events({
		"economy_event_batch_published": true,
		"economy_event_newest_id": 42,
	})
	_expect("availability signal remains eager", available_count == 1)
	_expect("unused detail signal advances cursor without materializing arrays",
		not bool(skipped.get("materialized", true))
		and ext.poll_calls == 0 and ext.ack_calls == 1 and ext.last_acked == 42)

	facade.economy_event_batch.connect(func(batch: Dictionary) -> void:
		received_count += int(batch.get("count", 0)))
	var materialized: Dictionary = facade.dispatch_committed_events({
		"economy_event_batch_published": true,
		"economy_event_newest_id": 44,
	})
	_expect("connected detail consumer keeps the packed poll and ack path",
		bool(materialized.get("materialized", false))
		and int(materialized.get("count", 0)) == 2
		and ext.poll_calls == 1 and ext.ack_calls == 2
		and ext.last_acked == 44 and received_count == 2)

	print("=== economy facade event dispatch %s ===" % [
		"PASS" if failures == 0 else "FAIL"])
	quit(0 if failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1
