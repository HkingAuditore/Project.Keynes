extends SceneTree

class FakeRuntime:
	extends Node
	signal gm_toggle_changed(toggle_id: String, enabled: bool)
	var revision := 0
	var paused := false

	func get_gm_capabilities() -> Dictionary:
		return {
			"commands": [{"id": "time.speed", "label": "设置速度", "destructive": false,
				"args": [{"name": "value", "type": "float", "required": true,
					"choices": PackedFloat32Array([1.0, 2.0, 5.0, 10.0, 20.0, 50.0])}]}],
			"toggles": [
				{"id": "simulation.paused", "label": "暂停模拟", "group": "模拟"},
				{"id": "visual.day_night", "label": "昼夜循环", "group": "视觉"},
				{"id": "diagnostics.pk_log", "label": "PKLog", "group": "诊断"},
			],
		}

	func get_gm_snapshot(_section: String, _context: Dictionary = {}) -> Dictionary:
		revision += 1
		return {"ok": true, "revision": revision, "data": {
			"world": {"ready": true, "seed": 20260727, "width": 60, "height": 40, "cells": 2400},
			"clock": {"day_index": 384, "year": 2, "month": 1, "day": 20,
				"paused": paused, "speed": 50.0},
			"runtime": {"fast_tick": 384, "last_tick_ms": 4},
			"country": {"country_count": 3, "pending_commands": 0},
			"economy": {"population": 125000, "market_cycle_days": 5,
				"conservation_error": 0},
			"recorders": {},
		}}

	func get_gm_toggle_state(toggle_id: String) -> Dictionary:
		return {"ok": true, "enabled": paused if toggle_id == "simulation.paused" else true}

	func set_gm_toggle(toggle_id: String, enabled: bool) -> Dictionary:
		if toggle_id == "simulation.paused":
			paused = enabled
		gm_toggle_changed.emit(toggle_id, enabled)
		return {"ok": true, "enabled": enabled}

	func execute_gm_command(_id: String, _args: Dictionary) -> Dictionary:
		return {"ok": true, "message": "已执行"}

	func set_perf_recorder(_recorder: RefCounted) -> void:
		pass

	func set_tile_data_recorder(_recorder: RefCounted) -> void:
		pass

	func set_economy_data_recorder(_recorder: RefCounted) -> void:
		pass


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var width := 1280
	var height := 720
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("width="):
			width = int(arg.trim_prefix("width="))
		elif arg.begins_with("height="):
			height = int(arg.trim_prefix("height="))
		elif arg.begins_with("output="):
			output = arg.trim_prefix("output=")
	var viewport := SubViewport.new()
	viewport.size = Vector2i(width, height)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene_root := Control.new()
	viewport.add_child(scene_root)
	scene_root.position = Vector2.ZERO
	scene_root.size = Vector2(width, height)
	var background := ColorRect.new()
	background.color = Color(0.08, 0.12, 0.10)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scene_root.add_child(background)
	var runtime := FakeRuntime.new()
	scene_root.add_child(runtime)
	var inspector := PanelContainer.new()
	inspector.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	inspector.offset_left = -460.0
	inspector.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	inspector.offset_bottom = -UITokens.SPACE_SM
	var inspector_label := Label.new()
	inspector_label.text = "地块档案"
	inspector_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inspector.add_child(inspector_label)
	inspector.theme = UITokens.make_player_theme()
	scene_root.add_child(inspector)
	var panel := DebugConsole.new()
	panel.console_mode = DebugConsole.ConsoleMode.PLAYER_GM
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	var available := float(width) - 460.0 - UITokens.SPACE_MD * 3.0
	var panel_width := clampf(available, 300.0, 560.0)
	panel.offset_left = UITokens.SPACE_SM
	panel.offset_right = UITokens.SPACE_SM + panel_width
	panel.offset_top = PlayerTopBar.BAR_HEIGHT + UITokens.SPACE_SM
	panel.offset_bottom = -UITokens.SPACE_SM
	panel.theme = UITokens.make_player_theme()
	scene_root.add_child(panel)
	panel.set_main(runtime)
	panel.open_panel()
	await process_frame
	await process_frame
	var node_count := panel.get_child_count()
	await create_timer(0.62).timeout
	var no_rebuild := node_count == panel.get_child_count()
	var gm_rect := panel.get_global_rect()
	var inspector_rect := inspector.get_global_rect()
	var no_overlap := gm_rect.end.x <= inspector_rect.position.x + 0.5
	if output != "" and DisplayServer.get_name() != "headless":
		var image := viewport.get_texture().get_image()
		if not image.is_empty():
			image.save_png(output)
	print("[gm-visual] %dx%d gm=%s inspector=%s no_overlap=%s no_rebuild=%s" % [
		width, height, gm_rect, inspector_rect, no_overlap, no_rebuild])
	quit(0 if no_overlap and no_rebuild else 1)
