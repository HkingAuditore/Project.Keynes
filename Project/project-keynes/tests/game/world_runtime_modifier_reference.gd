extends RefCounted
# Frozen S14 entry implementation; do not update alongside the adapter.
var _runtime_ready_for_ticks := false
var _generator: Object
var _modifier_worker_snapshot_generation := 0
var trace: Array = []
var mask := 0
func _runtime_control_state() -> Dictionary:
	trace.append("control")
	return {"authoritative_domain_mask": mask}

func _consume_modifier_worker_snapshot_if_authoritative() -> void:
	if not _runtime_ready_for_ticks or _generator == null:
		return
	if not _generator.has_method("apply_runtime_modifier_snapshot"):
		return
	var report := _runtime_control_state()
	var granted_mask := int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x040) == 0:
		return
	var applied: Dictionary = _generator.apply_runtime_modifier_snapshot(
		_modifier_worker_snapshot_generation)
	if not bool(applied.get("ok", false)) or not bool(applied.get("applied", false)):
		return
	var generation := int(applied.get("generation", 0))
	if generation <= _modifier_worker_snapshot_generation:
		return
	_modifier_worker_snapshot_generation = generation

