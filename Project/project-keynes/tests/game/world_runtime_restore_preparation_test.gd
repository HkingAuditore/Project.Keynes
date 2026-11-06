extends SceneTree
const Adapter = preload("res://scripts/game/world_runtime_restore_preparation.gd")
const Reference = preload("res://tests/game/world_runtime_restore_reference.gd")
var checks := 0
var failures := 0
class Probe extends RefCounted:
	var calls: Array = []
	var paused := false
	var result := {"ok": true}
	func _runtime_climate_catalog_hash_for_map(map): calls.append(["catalog", map])
	func restore_prepared_game(_host):
		calls.append("restore")
		return result
	func restore(): return restore_prepared_game(null)
	func pause(value):
		calls.append(["pause", value])
		paused = value
	func emit_failure(a,b,c,d): calls.append([a,b,c,d])
	func failure():
		calls.append("failure")
		return {"ok": false, "code": "cancelled"}
func _init(): call_deferred("run")
func run():
	for empty in [true, false]:
		for paused in [true, false]:
			var left := Probe.new()
			var right := Probe.new()
			left.paused = paused
			right.paused = paused
			var old := Reference.new()
			old._pending_load_bundle = {} if empty else {"slot": "manual_3"}
			old._generator = left
			old._current_map = 7
			old._world_clock = left
			old._session_prepare_options = {"clock_was_paused": not paused}
			old.service = left
			old.emit_failure = left.emit_failure
			old.failure = left.failure
			var bundle := old._pending_load_bundle.duplicate(true)
			var options := old._session_prepare_options.duplicate(true)
			var expected: Dictionary = old._prepare_world_restore()
			var actual: Dictionary = Adapter.prepare(bundle, right, 7, right.restore,
				right, options, right.emit_failure, right.failure)
			check(expected == actual, "return")
			check(left.calls == right.calls, "catalog/restore/pause order")
			check(bundle == old._pending_load_bundle, "bundle consume")
			check(options == old._session_prepare_options, "clock restore")
	print("restore preparation: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
func check(ok: bool, label: String):
	checks += 1
	if not ok:
		failures += 1
		push_error(label)
