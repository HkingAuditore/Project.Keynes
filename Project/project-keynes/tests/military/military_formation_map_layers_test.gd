extends SceneTree

## Manager-level checks for late player binding and fail-closed snapshots.

const LAYERS_SCRIPT := preload("res://scripts/rendering/military_map_layers.gd")
const FEED_SCRIPT := preload("res://scripts/rendering/military_render_feed.gd")

var _failures := PackedStringArray()


class FakeHost:
	var slot_value := 3

	func player_country_slot() -> int:
		return slot_value


class FakeExt:
	var fail := true

	func get_military_render_snapshot(_after_revision: int) -> Dictionary:
		if fail:
			return {"ok": false, "reason": "military_not_configured"}
		return {
			"ok": true,
			"revision": 1,
			"armies": {},
			"engagements": {},
			"convoys": {},
			"controller_cells": PackedInt32Array(),
			"controller_slots": PackedInt32Array(),
			"front_edges": PackedInt32Array(),
			"front_progress": PackedByteArray(),
		}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager = LAYERS_SCRIPT.new()
	get_root().add_child(manager)
	await process_frame
	manager._ensure_layers()
	manager._feed = FEED_SCRIPT.new()

	var host := FakeHost.new()
	manager._host = host
	manager._player_slot = -1
	_expect(manager._refresh_player_slot_binding(),
		"initial player slot binding reports a change")
	_expect(manager._player_slot == 3, "manager adopts the late player slot")
	_expect(manager.token_layer._player_slot == 3,
		"token layer receives the late player slot")
	_expect(manager.route_layer._player_slot == 3,
		"route layer receives the late player slot")

	host.slot_value = 4
	var ext := FakeExt.new()
	manager._ext = ext
	manager.token_layer._last_signature = 123
	manager.battle_layer._count = 1
	manager.route_layer._route = PackedInt32Array([1, 2])
	manager.route_layer._sync_visibility()
	manager._poll()
	_expect(manager._player_slot == 4,
		"poll detects a player-slot change after configuration")
	_expect(manager.token_layer._player_slot == 4,
		"poll propagates the changed player slot before rendering")

	_expect(manager._feed_unavailable,
		"failed snapshot enters the unavailable state")
	_expect(manager.token_layer._last_signature == -1,
		"failed snapshot invalidates stale army tokens")
	_expect(manager.battle_layer._count == 0,
		"failed snapshot clears stale battle rings")
	_expect(manager.route_layer._route.is_empty(),
		"failed snapshot clears stale route geometry")
	for layer in manager._all_layers():
		if layer != null and layer.has_method("set_enabled"):
			_expect(not layer.visible,
				"%s is hidden while the snapshot is unavailable" % layer.name)

	ext.fail = false
	manager._poll()
	_expect(not manager._feed_unavailable,
		"successful snapshot clears the unavailable state")
	_expect(manager.token_layer._enabled,
		"successful snapshot re-enables the token layer")
	_expect(manager.route_layer._enabled,
		"successful snapshot re-enables the route layer")

	manager.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	print("=== military formation map layers test: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
