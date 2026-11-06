extends RefCounted

# Replay input: measured machine time must not choose a different settlement day.
# Zero injected cost uses the existing cold-work estimate; production is untouched.
static func install(ext: Object) -> bool:
	var result: Dictionary = ext.inject_economy_cadence_timing(0.0, 0.0, 0.0)
	return bool(result.get("ok", false)) and bool(result.get("cadence_timing_injected", false))
