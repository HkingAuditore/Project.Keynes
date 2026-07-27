extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := WorldRuntimeHost.new()
	var clock := WorldClock.new()
	root.add_child(clock)
	root.add_child(host)
	host.set("_world_clock", clock)
	var failures := PackedStringArray()
	_expect(host.execute_gm_command("unknown.run", {}).get("code") == "unknown_command",
		"unknown command", failures)
	_expect(host.execute_gm_command("time.speed", {}).get("code") == "missing_argument",
		"missing argument", failures)
	_expect(host.execute_gm_command("time.speed", {"value": "3"}).get("code") == "invalid_argument",
		"speed whitelist", failures)
	var speed := host.execute_gm_command("time.speed", {"value": "5"})
	_expect(bool(speed.get("ok", false)) and is_equal_approx(clock.speed_multiplier, 5.0),
		"speed routing", failures)
	var pause := host.execute_gm_command("time.pause", {"state": "on"})
	_expect(bool(pause.get("ok", false)) and clock.paused, "pause routing", failures)
	_expect(host.execute_gm_command("economy.add_population", {
		"cohort_handle": "1", "amount": "10"}).get("code") == "world_not_ready",
		"world readiness boundary", failures)
	var capabilities := host.get_gm_capabilities()
	var fog_toggle_found := false
	for toggle in capabilities.get("toggles", []):
		if String(toggle.get("id", "")) == "visual.fog_of_war":
			fog_toggle_found = true
			break
	_expect(fog_toggle_found, "fog toggle capability", failures)
	var fog_toggle := host.set_gm_toggle("visual.fog_of_war", false)
	_expect(bool(fog_toggle.get("ok", false)) and not bool(fog_toggle.get("enabled", true)),
		"fog toggle authoritative readback", failures)
	_expect(GameUIManager.gm_available_for_build(true, false), "debug build entry", failures)
	_expect(GameUIManager.gm_available_for_build(false, true), "editor entry", failures)
	_expect(not GameUIManager.gm_available_for_build(false, false), "release entry hidden", failures)
	for failure in failures:
		push_error("[gm-runtime-host] FAIL: %s" % failure)
	print("[gm-runtime-host] %s" % ("PASS" if failures.is_empty() else "FAIL"))
	host.queue_free()
	clock.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, label: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(label)
