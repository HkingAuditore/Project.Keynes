extends SceneTree


func _init() -> void:
	var commands := [
		{"id": "time.speed", "args": [{"name": "value", "type": "float", "required": true,
			"choices": PackedFloat32Array([1.0, 2.0, 5.0])}]},
		{"id": "country.rename", "destructive": true, "args": [
			{"name": "country_handle", "type": "int", "required": true},
			{"name": "name", "type": "string", "required": true}]},
	]
	var failures := PackedStringArray()

	var quoted := GMPanelViewModel.parse_command(
		"country.rename country_handle=7 name=\"New Republic\"")
	_expect(bool(quoted.get("ok", false)) and quoted.get("args", {}).get("name") == "New Republic",
		"quoted string", failures)
	_expect(not bool(GMPanelViewModel.parse_command("country.rename name='open").get("ok", false)),
		"unterminated quote", failures)
	_expect(not bool(GMPanelViewModel.parse_command("time.speed value=2 value=5").get("ok", false)),
		"duplicate argument", failures)
	_expect(not bool(GMPanelViewModel.validate_command(
		GMPanelViewModel.parse_command("country.rename country_handle=7"), commands).get("ok", false)),
		"missing argument", failures)
	_expect(not bool(GMPanelViewModel.validate_command(
		GMPanelViewModel.parse_command("time.speed value=10"), commands).get("ok", false)),
		"enum range", failures)
	_expect(not bool(GMPanelViewModel.validate_command(
		GMPanelViewModel.parse_command("unknown.run"), commands).get("ok", false)),
		"unknown command", failures)

	var command_completion := GMPanelViewModel.command_suggestions("time.s", commands)
	_expect(command_completion.has("time.speed"), "command completion", failures)
	var value_completion := GMPanelViewModel.command_suggestions("time.speed value=", commands)
	_expect(value_completion.has("value=5.0"), "choice completion", failures)

	var history := []
	history = GMPanelViewModel.push_history(history, "time.speed value=2", 2)
	history = GMPanelViewModel.push_history(history, "time.speed value=2", 2)
	history = GMPanelViewModel.push_history(history, "time.speed value=5", 2)
	_expect(history.size() == 2 and GMPanelViewModel.history_entry(history, 0) == "time.speed value=2",
		"bounded unique history", failures)

	var overview := GMPanelViewModel.format_snapshot("overview", {
		"ok": true,
		"data": {
			"world": {"ready": true, "seed": 1, "width": 2, "height": 2, "cells": 4},
			"clock": {"day_index": 2862, "year": 0, "month": 11, "day": 0,
				"paused": false, "speed": 50.0},
			"runtime": {"fast_tick": 2862, "last_tick_ms": 10},
			"economy": {
				"accuracy_candidate_top_k": 2,
				"accuracy_choice_temperature_q16": 983,
				"age_days": 0,
				"approximation_decisions": 0,
				"current_day": 1371,
				"epoch_active": false,
				"epoch_id": 1361,
				"fatal": true,
				"fatal_reason": "goods_conservation_failed",
				"goods_error": 1,
				"last_completed_sample_day": 1370,
				"money_error": 0,
				"newest_state_day": 1371,
				"population_error": 0,
				"stage": "fatal",
			},
		},
	})
	var economy_rows := _section_rows(overview, "经济运行时")
	_expect(not economy_rows.is_empty() and String(economy_rows[0].get("label", "")) == "状态"
			and String(economy_rows[0].get("value", "")).begins_with("已暂停"),
		"economy fatal status first", failures)
	_expect(_row_value(economy_rows, "fatal") == "true", "economy fatal pinned", failures)
	_expect(_row_value(economy_rows, "fatal_reason") == "goods_conservation_failed",
		"economy fatal_reason pinned", failures)
	_expect(_row_value(economy_rows, "accuracy_candidate_top_k") == "",
		"accuracy keys do not hide fatal", failures)

	for failure in failures:
		push_error("[gm-view-model] FAIL: %s" % failure)
	print("[gm-view-model] %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _section_rows(sections: Array, title: String) -> Array:
	for raw in sections:
		var section: Dictionary = raw
		if String(section.get("title", "")) == title:
			return section.get("rows", [])
	return []


func _row_value(rows: Array, label: String) -> String:
	for raw in rows:
		var row: Dictionary = raw
		if String(row.get("label", "")) == label:
			return String(row.get("value", ""))
	return ""


func _expect(condition: bool, label: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(label)
