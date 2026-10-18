extends SceneTree

func _init() -> void:
	var loaded := SaveRepository.new().load_slot("autosave")
	if not loaded.get("ok", false):
		print(JSON.stringify(loaded))
		quit(1)
		return
	var sections: Dictionary = loaded.section_bytes
	var header: Dictionary = loaded.header
	print("[tech-audit] header=", JSON.stringify(header))
	print("[tech-audit] player=", bytes_to_var(sections.player_context))
	var compiled := EconomyCatalog.compile_native_catalog()
	var ext := DCWorldExt.new()
	var facade := CountryFacade.new()
	var count := int(header.width) * int(header.height)
	ext.create_entities(count)
	print("[tech-audit] configure=", facade.configure(ext, count, int(header.seed), null, compiled))
	print("[tech-audit] restore=", facade.restore_bytes(sections.pkcn))
	var player: Dictionary = bytes_to_var(sections.player_context)
	var handle := int(player.get("player_country_handle", player.get("country_handle", 0)))
	if handle == 0:
		handle = int(ext.get_country_cell_summary(int(player.get("start_cell", 0))).get("country_handle", 0))
	print("[tech-audit] handle=", handle)
	var research: Dictionary = ext.get_country_research_snapshot(handle)
	var trigger_catalog = preload("res://scripts/trigger/trigger_catalog.gd").load_default()
	print("[tech-audit] trigger_config=", ext.configure_triggers(trigger_catalog.compile_native_catalog()))
	print("[tech-audit] trigger_restore=", ext.restore_trigger_state(sections.pktr))
	print("[tech-audit] trigger_report=", ext.get_trigger_report())
	var effect_catalog = preload("res://scripts/effect/effect_domain_catalog.gd").build()
	print("[tech-audit] effect_config=", ext.configure_effects(effect_catalog.compile_native_catalog()).get("ok", false))
	print("[tech-audit] effect_restore=", ext.restore_effect_state(sections.pkef).get("ok", false))
	print("[tech-audit] trigger_head=", ext.poll_trigger_effects(7, 8))
	print("[tech-audit] handoff=", ext.handoff_trigger_effects(512))
	var developments: Array = []
	for era in 11:
		developments.append(ext.get_development_progress(handle, era))
	research["research_signal_snapshot"] = ext.get_country_research_signal_snapshot(handle)
	var definitions := TechnologyCatalog.public_definitions(compiled)
	var workspace := preload("res://scenes/ui/technology_workspace.tscn").instantiate()
	root.add_child(workspace)
	workspace.set_model({"available": true, "research": research,
		"technology_definitions": definitions,
		"technology_eras": TechnologyCatalog.public_era_metadata(),
		"technology_domains": TechnologyCatalog.public_domain_metadata(),
		"research_signal_definitions": ResearchSignalCatalog.public_metadata()})
	var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	var totals := [0, 0, 0, 0, 0, 0]
	var blocked: Array = []
	for i in states.size():
		totals[states[i]] += 1
		if states[i] < 2:
			blocked.append({"id": definitions[i].id, "name": definitions[i].display_name,
				"state": states[i], "conditions": workspace._condition_items(i, states),
				"reveal": definitions[i].get("reveal_condition", {})})
	var report := {"day": header.day, "totals": totals, "research": research, "blocked": blocked, "development": developments, "trigger": ext.get_trigger_report()}
	var file := FileAccess.open("res://tmp/technology_save_audit.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	print("[tech-audit] totals=", totals)
	workspace.free()
	quit(0)




