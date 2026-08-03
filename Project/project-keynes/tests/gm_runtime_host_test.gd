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
	var click_claim_toggle_found := false
	var atlas_toggle_found := false
	var autosave_toggle_found := false
	var river_probe_command_found := false
	for toggle in capabilities.get("toggles", []):
		if String(toggle.get("id", "")) == "visual.fog_of_war":
			fog_toggle_found = true
		if String(toggle.get("id", "")) == "simulation.click_claim_territory":
			click_claim_toggle_found = true
		if String(toggle.get("id", "")) == "diagnostics.dynamic_visual_atlas_upload":
			atlas_toggle_found = true
		if String(toggle.get("id", "")) == "system.autosave":
			autosave_toggle_found = true
	for command in capabilities.get("commands", []):
		if String(command.get("id", "")) == "diagnostics.dump_atlas_river_probe":
			river_probe_command_found = true
	_expect(fog_toggle_found, "fog toggle capability", failures)
	_expect(click_claim_toggle_found, "click claim toggle capability", failures)
	_expect(atlas_toggle_found, "dynamic atlas toggle capability", failures)
	_expect(autosave_toggle_found, "autosave toggle capability", failures)
	_expect(river_probe_command_found, "river probe command capability", failures)
	_expect(host.execute_gm_command("diagnostics.dump_atlas_river_probe", {}).get("code") == "baker_unavailable",
		"river probe command readiness boundary", failures)
	_expect(host.set_gm_toggle("simulation.click_claim_territory", true).get("code") == "world_not_ready",
		"click claim world readiness boundary", failures)
	var fog_toggle := host.set_gm_toggle("visual.fog_of_war", false)
	_expect(bool(fog_toggle.get("ok", false)) and not bool(fog_toggle.get("enabled", true)),
		"fog toggle authoritative readback", failures)
	Engine.remove_meta(&"force_disable_dva_upload")
	var atlas_off := host.set_gm_toggle("diagnostics.dynamic_visual_atlas_upload", false)
	_expect(bool(atlas_off.get("ok", false)) and not bool(atlas_off.get("enabled", true))
		and bool(Engine.get_meta(&"force_disable_dva_upload", false)),
		"dynamic atlas GM disable", failures)
	var atlas_on := host.set_gm_toggle("diagnostics.dynamic_visual_atlas_upload", true)
	_expect(bool(atlas_on.get("ok", false)) and bool(atlas_on.get("enabled", false))
		and not bool(Engine.get_meta(&"force_disable_dva_upload", true)),
		"dynamic atlas GM enable", failures)
	Engine.remove_meta(&"force_disable_dva_upload")
	var game_save := root.get_node_or_null("GameSave")
	var game_settings := root.get_node_or_null("GameSettings")
	_expect(game_save != null and game_settings != null,
		"save/settings autoloads available", failures)
	if game_save != null and game_settings != null:
		var autosave_off := host.set_gm_toggle("system.autosave", false)
		_expect(bool(autosave_off.get("ok", false)) and not bool(autosave_off.get("enabled", true))
			and not bool(game_save.call("is_autosave_enabled"))
			and not bool((game_settings.call("values") as Dictionary).get("autosave_enabled", true)),
			"autosave GM disable persists", failures)
		var autosave_state: Dictionary = host.get_gm_toggle_state("system.autosave")
		_expect(bool(autosave_state.get("ok", false)) and not bool(autosave_state.get("enabled", true)),
			"autosave toggle state readback", failures)
		var autosave_on := host.set_gm_toggle("system.autosave", true)
		_expect(bool(autosave_on.get("ok", false)) and bool(autosave_on.get("enabled", false))
			and bool(game_save.call("is_autosave_enabled"))
			and bool((game_settings.call("values") as Dictionary).get("autosave_enabled", false)),
			"autosave GM enable restores", failures)
		game_save.call("set_autosave_enabled", false)
		game_save.call("_on_year_changed", 5)
		_expect(int(game_save.get("_last_autosave_year")) == 5,
			"autosave disabled advances year marker without writing", failures)
		game_save.call("set_autosave_enabled", true)
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
