extends "res://scripts/game/game_save_coordinator.gd"
# Loaded after autoloads initialize. Only boundary observations are simulated.
var observations := 0
var terminal := false
func _session_active(_generation: int) -> bool:
	return true
func _can_save() -> Dictionary:
	observations += 1
	if terminal: return {"ok": false, "code": "save_runtime_fault"}
	return {"ok": observations > 3, "code": "save_requires_committed_boundary"}
func wait_boundary() -> Dictionary:
	return await _wait_for_safe_boundary()
