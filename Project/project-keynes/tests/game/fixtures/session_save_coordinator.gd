extends "res://scripts/game/game_save_coordinator.gd"

var autosaves: Array[String] = []

func _ready() -> void:
	pass

func request_autosave(reason: String) -> Dictionary:
	autosaves.append(reason)
	return {"ok": true}

func _profile_save_window(_active: bool) -> void:
	pass

func _can_save() -> Dictionary:
	return {"ok": false, "code": "save_requires_committed_boundary"}
