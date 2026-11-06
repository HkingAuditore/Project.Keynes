extends RefCounted

# Passive adapter: the host owns invocation order and the generation cursor.
# No retained resources, awaits, cross-domain ACKs or simulation advancement.
static func consume(ready: bool, generator: Object, control_state: Callable,
		after_generation: int) -> int:
	if not ready or generator == null:
		return after_generation
	if not generator.has_method("apply_runtime_modifier_snapshot"):
		return after_generation
	var report: Dictionary = control_state.call()
	var granted_mask := int(report.get("authoritative_domain_mask", 0))
	if (granted_mask & 0x040) == 0:
		return after_generation
	var applied: Dictionary = generator.apply_runtime_modifier_snapshot(after_generation)
	if not bool(applied.get("ok", false)) or not bool(applied.get("applied", false)):
		return after_generation
	var generation := int(applied.get("generation", 0))
	if generation <= after_generation:
		return after_generation
	return generation
