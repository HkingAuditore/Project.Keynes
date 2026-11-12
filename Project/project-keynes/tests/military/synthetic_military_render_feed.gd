extends "res://scripts/rendering/military_render_feed.gd"

## Read-only fixture feed for map-integration screenshots and visual QA.
## The production host poll still runs, but this override prevents a native DLL
## snapshot from replacing the synthetic rows.

var _fixture_snapshot: Dictionary = {}


func set_snapshot(snapshot: Dictionary) -> void:
	_fixture_snapshot = snapshot
	apply_synthetic(_fixture_snapshot, int(revision))


func poll(_ext, _after_revision: int, player_slot_value: int) -> void:
	player_slot = player_slot_value
	if _fixture_snapshot.is_empty():
		ok = false
		return
	apply_synthetic(_fixture_snapshot, int(revision))
