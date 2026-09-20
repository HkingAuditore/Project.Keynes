extends SceneTree

class ControllerStub extends RefCounted:
	func get_family_expeditions(_offset: int, _limit: int) -> Dictionary:
		return {"ok": true, "total": 2, "has_more": false,
			"expedition_handles": PackedInt64Array([101, 102]),
			"family_handles": PackedInt64Array([11, 12]),
			"target_cells": PackedInt32Array([2, 3]),
			"states": PackedInt32Array([4, 1]),
			"populations": PackedInt64Array([3, 5])}

	func get_family_colonization_quotes(_target: int, _family: int,
			_source: int, _offset: int, _limit: int) -> Dictionary:
		return {"ok": true, "total": 0}


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var panel = load("res://scenes/ui/colonization_planner_panel.tscn").instantiate()
	root.add_child(panel)
	panel.set_player_controller(ControllerStub.new())
	panel.open_target(2)
	var passed: bool = panel._current_tab == "expeditions" \
		and panel._expedition_row_refs.size() == 1 \
		and panel._expedition_row_refs.has(101)
	print("[%s] reopening a preparing target shows its own expedition" % ("PASS" if passed else "FAIL"))
	panel.open_target(2, 12)
	var family_scope: bool = panel._current_tab == "quotes"
	print("[%s] family context excludes other families' expeditions" % ("PASS" if family_scope else "FAIL"))
	panel.open_target(4)
	var empty_target: bool = panel._current_tab == "quotes"
	print("[%s] a new target opens dispatch quotes" % ("PASS" if empty_target else "FAIL"))
	panel.queue_free()
	await process_frame
	quit(0 if passed and family_scope and empty_target else 1)
