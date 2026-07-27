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

	for failure in failures:
		push_error("[gm-view-model] FAIL: %s" % failure)
	print("[gm-view-model] %s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, label: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(label)
