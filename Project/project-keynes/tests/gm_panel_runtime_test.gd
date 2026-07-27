extends SceneTree

class FakeRuntime:
	extends Node

	var snapshot_calls := 0
	var command_calls := 0
	var toggle_state := false

	func get_gm_capabilities() -> Dictionary:
		return {
			"commands": [
				{"id": "time.speed", "destructive": false, "args": [
					{"name": "value", "type": "float", "required": true,
						"choices": PackedFloat32Array([1.0, 2.0, 5.0])}]},
				{"id": "country.rename", "destructive": true, "args": [
					{"name": "country_handle", "type": "int", "required": true},
					{"name": "name", "type": "string", "required": true}]},
			],
			"toggles": [{"id": "simulation.paused", "label": "暂停模拟", "group": "模拟"}],
		}

	func get_gm_snapshot(section: String, _context: Dictionary = {}) -> Dictionary:
		snapshot_calls += 1
		if section == "selected":
			return {"ok": false, "message": "尚未选中地块。"}
		return {"ok": true, "revision": snapshot_calls, "data": {
			"world": {"ready": true, "seed": 7, "width": 10, "height": 8, "cells": 80},
			"clock": {"day_index": 12, "year": 1, "month": 1, "day": 13,
				"paused": false, "speed": 1.0},
			"runtime": {"fast_tick": snapshot_calls, "last_tick_ms": 1},
		}}

	func execute_gm_command(command_id: String, _args: Dictionary) -> Dictionary:
		command_calls += 1
		if command_id == "time.speed":
			return {"ok": false, "message": "测试错误"}
		return {"ok": true, "message": "已排队", "queued": true, "effective_day": 13}

	func get_gm_toggle_state(_toggle_id: String) -> Dictionary:
		return {"ok": true, "enabled": toggle_state}

	func set_gm_toggle(_toggle_id: String, enabled: bool) -> Dictionary:
		# Deliberately reject the requested state so the panel must read truth back.
		toggle_state = not enabled
		return {"ok": true, "enabled": toggle_state, "message": "已回读"}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var runtime := FakeRuntime.new()
	root.add_child(runtime)
	var console := DebugConsole.new()
	console.console_mode = DebugConsole.ConsoleMode.PLAYER_GM
	root.add_child(console)
	console.set_main(runtime)
	console.open_panel()
	await process_frame
	var failures := PackedStringArray()

	var calls_when_open := runtime.snapshot_calls
	await create_timer(0.62).timeout
	_expect(runtime.snapshot_calls > calls_when_open, "visible 2Hz refresh", failures)
	console.close_panel()
	await create_timer(0.25).timeout
	var calls_when_hidden := runtime.snapshot_calls
	await create_timer(0.62).timeout
	_expect(runtime.snapshot_calls == calls_when_hidden, "hidden polling stopped", failures)

	console.open_panel()
	await process_frame
	console.call("_on_gm_toggle_changed", true, "simulation.paused")
	var toggle: CheckBox = (console.get("_gm_toggle_buttons") as Dictionary).get("simulation.paused")
	_expect(toggle != null and not toggle.button_pressed, "toggle authoritative readback", failures)

	var input: LineEdit = console.get("_gm_command_input")
	input.text = "time.speed value=2"
	console.call("_submit_gm_command")
	var output: RichTextLabel = console.get("_gm_command_output")
	_expect(output.text.contains("测试错误"), "runtime error surfaced", failures)

	input.text = "country.rename country_handle=3 name=North"
	console.call("_submit_gm_command")
	var before_confirm := runtime.command_calls
	_expect(not (console.get("_gm_pending_command") as Dictionary).is_empty(),
		"destructive command pending confirmation", failures)
	_expect(runtime.command_calls == before_confirm, "no execution before confirmation", failures)
	console.call("_execute_pending_gm_command")
	_expect(runtime.command_calls == before_confirm + 1, "execution after confirmation", failures)

	for failure in failures:
		push_error("[gm-panel-runtime] FAIL: %s" % failure)
	print("[gm-panel-runtime] %s" % ("PASS" if failures.is_empty() else "FAIL"))
	console.queue_free()
	runtime.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, label: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(label)
