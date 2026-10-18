extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1280, 720)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tmp/technology_save_audit.json"))
	var research: Dictionary = report.research
	for key in ["technology_states", "weights_bp", "queue_offsets", "queue_technology_indices"]:
		research[key] = PackedInt32Array(research.get(key, []))
	research.technology_progress = PackedInt64Array(research.get("technology_progress", []))
	var signals: Dictionary = research.research_signal_snapshot
	for key in ["signal_ids", "counts", "first_cells"]:
		signals[key] = PackedInt32Array(signals.get(key, []))
	signals.first_days = PackedInt64Array(signals.get("first_days", []))
	var definitions := TechnologyCatalog.public_definitions()
	var host := Panel.new()
	host.theme = load("res://assets/themes/player_session_theme.tres")
	root.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var workspace := preload("res://scenes/ui/technology_workspace.tscn").instantiate()
	host.add_child(workspace)
	workspace.set_model({"research": research, "technology_definitions": definitions,
		"technology_eras": TechnologyCatalog.public_era_metadata(),
		"technology_domains": TechnologyCatalog.public_domain_metadata(),
		"technology_lanes": TechnologyCatalog.public_lane_metadata(),
		"technology_visual_edges": TechnologyCatalog.public_visual_edges(),
		"research_signal_definitions": ResearchSignalCatalog.public_metadata()})
	var selected := -1
	for i in definitions.size():
		if definitions[i].id == "tech.irrigation":
			selected = i
	workspace._set_mode(1)
	workspace._on_tree_selected(selected)
	workspace._set_detail_open(true)
	for frame in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://tmp/technology_unknown_conditions.png")
	quit(0)
