extends RefCounted

# Replay keeps timing diagnostics deterministic. Production settlement already
# follows fixed game-day periods; this injection does not choose those periods.
static func install(ext: Object) -> bool:
	var result: Dictionary = ext.inject_economy_cadence_timing(0.0, 0.0, 0.0)
	return bool(result.get("ok", false)) and bool(result.get("cadence_timing_injected", false))
