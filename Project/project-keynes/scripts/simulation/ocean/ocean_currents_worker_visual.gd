extends RefCounted


static func matches_map(commit: Dictionary, map_id: int, cells: int, size: Vector2i) -> bool:
	return int(commit.get("map_instance_id", 0)) == map_id and cells > 0 \
			and int(commit.get("cell_count", 0)) == cells and size.x > 0 and size.y > 0


static func commit_ready(commit: Dictionary) -> bool:
	return bool(commit.get("ready", false)) and bool(commit.get("ok", false)) \
			and int(commit.get("committed_day", -1)) >= 0 \
			and int(commit.get("input_generation", 0)) > 0 and int(commit.get("generation", 0)) > 0


static func same_commit(view: Dictionary, commit: Dictionary) -> bool:
	if not bool(view.get("ready", false)) or not bool(view.get("ok", false)) \
			or not bool(view.get("authoritative", false)):
		return false
	for key in ["map_instance_id", "cell_count", "committed_day", "input_generation", "generation"]:
		if not commit.has(key) or view.get(key) != commit[key]:
			return false
	return true


static func report(commit: Dictionary, elapsed_ms: float, visual_error: String) -> Dictionary:
	return {
		"work_done": 0, "progress_ratio": 1.0, "elapsed_ms": elapsed_ms,
		"stage_name": "worker_physics_committed", "path": "worker_snapshot",
		"committed_day": commit.get("committed_day", -1),
		"input_generation": commit.get("input_generation", 0),
		"physics_authoritative": true,
		"raster_fallback_reason": visual_error,
	}
