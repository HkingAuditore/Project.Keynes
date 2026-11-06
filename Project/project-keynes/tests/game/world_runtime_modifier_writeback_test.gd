extends SceneTree
const Previous = preload("res://tests/game/world_runtime_modifier_reference.gd")
const Adapter = preload("res://scripts/game/world_runtime_modifier_writeback.gd")
var checks := 0
var failures := 0

class Generator extends MapGenerator:
	var trace: Array = []
	var result: Dictionary = {}
	func apply_runtime_modifier_snapshot(generation: int) -> Dictionary:
		trace.append(["consume", generation])
		return result

class Current extends WorldRuntimeHost:
	var trace: Array = []
	var mask := 0
	func _runtime_control_state() -> Dictionary:
		trace.append("control")
		return {"authoritative_domain_mask": mask}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var old := Previous.new()
	var current := Current.new()
	var generator := Generator.new()
	for ready in [false, true]:
		for mask in [0, 0x040, 0xFFF]:
			for result in [{}, {"ok": false}, {"ok": true, "applied": false},
					{"ok": true, "applied": true, "generation": 3},
					{"ok": true, "applied": true, "generation": 4},
					{"ok": true, "applied": true, "generation": 9}]:
				generator.result = result
				old._generator = generator
				current._generator = generator
				old._runtime_ready_for_ticks = ready
				current._runtime_ready_for_ticks = ready
				old.mask = mask
				current.mask = mask
				old._modifier_worker_snapshot_generation = 4
				current._modifier_worker_snapshot_generation = 4
				old.trace = []
				generator.trace = old.trace
				old._consume_modifier_worker_snapshot_if_authoritative()
				current.trace = []
				generator.trace = current.trace
				current._consume_modifier_worker_snapshot_if_authoritative()
				_expect("generation equals frozen implementation", old._modifier_worker_snapshot_generation == current._modifier_worker_snapshot_generation)
				_expect("control/consume order equals frozen implementation; no added ACK", old.trace == current.trace)
				current._consume_modifier_worker_snapshot_if_authoritative()
				_expect("repeated consume cannot regress cursor", current._modifier_worker_snapshot_generation >= 4)
	# Missing API and null owner stop before requesting control state.
	var missing := RefCounted.new()
	for owner in [null, missing]:
		current.trace = []
		_expect("missing owner/API preserves cursor", Adapter.consume(true, owner, current._runtime_control_state, 7) == 7)
		_expect("missing owner/API has no calls", current.trace.is_empty())
	current._generator = null
	old._generator = null
	generator = null
	current.free()
	print("modifier writeback: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _expect(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
		print("[FAIL] " + label)
