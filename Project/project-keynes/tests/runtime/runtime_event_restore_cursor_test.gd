extends SceneTree

var checks := 0
var failures := 0
func expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[FAIL] " + label)

func _init() -> void:
	var world := DCWorldExt.new()
	# ACTIVE snapshots contain worker event IDs and an independent ingress ID.
	# This is the annual restore shape: 232 must not become worker ID 758 + 1.
	var snapshot := {"version": 4, "next_event_id": 232,
		"event_id": PackedInt64Array([758]), "tick": PackedInt64Array([365]),
		"type": PackedInt32Array([11]), "source": PackedInt32Array([2]),
		"effect_idempotency_keys": PackedInt64Array(),
		"effect_request_ids": PackedInt64Array(), "effect_event_ids": PackedInt64Array()}
	var restored: Dictionary = world.restore_gameplay_event_journal(snapshot)
	expect("journal restores", bool(restored.get("ok", false)))
	var after: Dictionary = world.snapshot_gameplay_event_journal({})
	expect("saved ingress cursor is authoritative", int(after.next_event_id) == 232)
	expect("worker event identity remains intact", after.event_id == PackedInt64Array([758]))
	world.publish_gameplay_events({"count": 1, "type_scalar": 11, "tick_scalar": 366})
	after = world.snapshot_gameplay_event_journal({})
	expect("next ingress increments exactly once", int(after.next_event_id) == 233)
	print("event restore cursor: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
