extends SceneTree

const WorkspaceScene := preload("res://scenes/ui/technology_workspace.tscn")
const CountryViewModelScript = preload("res://scripts/ui/country_view_model.gd")

var _failures := 0


func _init() -> void:
	get_root().size = Vector2i(1280, 720)
	var workspace := WorkspaceScene.instantiate() as Control
	get_root().add_child(workspace)
	var definitions := _definitions()
	var research_states := PackedInt32Array([5, 2])
	workspace.set_model(_model(definitions, research_states))
	await process_frame
	var states: PackedInt32Array = workspace._presentation_states(research_states)
	_expect("application is presented as locked when support tech is unfinished",
		states == PackedInt32Array([5, 2, 2]))
	_expect("application never creates a research queue row",
		_queue_row_count(workspace) == 0)
	var conditions: Array = workspace._application_condition_items(
		definitions[2], states)
	_expect("application conditions distinguish primary and supporting tech",
		_contains(conditions, "主科技") and _contains(conditions, "支撑科技"))
	_expect("application conditions distinguish input, resource, and tile gates",
		_contains(conditions, "投入商品") and _contains(conditions, "自然资源") \
		and _contains(conditions, "地块条件"))

	research_states[1] = 0
	states = workspace._presentation_states(research_states)
	_expect("hidden required tech keeps the application hidden", states[2] == 0)
	research_states[1] = 5
	states = workspace._presentation_states(research_states)
	_expect("all required techs derive the application as enabled", states[2] == 5)
	_expect("derived application state never expands native research storage",
		research_states.size() == 2)

	var detail = workspace.get("_detail")
	detail.show_technology(2, definitions[2], 5, 0.0, Color.WHITE,
		"石器时代", "农业", {"condition_items": conditions})
	_expect("application detail has no research gauge or queue action",
		not (detail.get("_gauge") as Control).visible \
		and not (detail.get("_action") as Control).visible)
	var decorated: Array = CountryViewModelScript._application_definitions([{
		"id": "app.wild_tuber_patch", "display_name": "野生块茎采集地",
		"era_id": "stone", "domain_id": "agriculture",
		"industry_chain_id": "branch.tuber_highland",
		"required_technology_ids": PackedStringArray(["tech.primary", "tech.support"]),
		"building_ids": PackedStringArray(["wild_tuber_patch"]),
	}], [{"id": "branch.tuber_highland", "display_name": "块茎与高地农业"}])
	_expect("country view model decorates application buildings with industry metadata",
		decorated.size() == 1 and not (decorated[0] as Dictionary).get(
			"content_effects", []).is_empty() \
		and String((decorated[0] as Dictionary).get(
			"industry_chain_display_name", "")) == "块茎与高地农业")
	workspace.queue_free()
	print("technology application UI: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)


func _definitions() -> Array:
	return [
		{"id": "tech.primary", "display_name": "块茎繁育", "era_id": "stone",
			"domain_id": "agriculture", "layout_lane": "agriculture",
			"cost_points": 10, "prerequisite_ids": PackedStringArray()},
		{"id": "tech.support", "display_name": "雨养田体系", "era_id": "stone",
			"domain_id": "agriculture", "layout_lane": "agriculture",
			"cost_points": 10, "prerequisite_ids": PackedStringArray()},
		{"id": "app.tuber_garden", "display_name": "家户块茎圃", "era_id": "stone",
			"domain_id": "agriculture", "layout_lane": "agriculture",
			"anchor_kind": "application", "is_application": true,
			"required_technology_ids": PackedStringArray(["tech.primary", "tech.support"]),
			"primary_technology_id": "tech.primary", "cost_points": 0,
			"progression_step": 2,
			"maturity_display_names": PackedStringArray(["家户试作"]),
			"required_input_good_ids": [{"id": "seed", "display_name": "种薯"}],
			"required_resource_ids": [{"id": "soil", "display_name": "可耕地"}],
			"required_tile_condition_ids": [{"id": "dry", "display_name": "旱地"}]},
	]


func _model(definitions: Array, states: PackedInt32Array) -> Dictionary:
	return {
		"technology_definitions": definitions,
		"technology_research_definition_count": 2,
		"technology_eras": [{"id": "stone", "display_name": "石器时代"}],
		"technology_domains": [
			{"id": "agriculture", "display_name": "农业", "accent": Color.GREEN},
			{"id": "engineering", "display_name": "工程", "accent": Color.ORANGE},
			{"id": "science", "display_name": "科学", "accent": Color.CYAN},
			{"id": "society", "display_name": "社会", "accent": Color.MAGENTA},
		],
		"technology_visual_edges": [
			{"from": "tech.primary", "to": "app.tuber_garden", "kind": "application"},
			{"from": "tech.support", "to": "app.tuber_garden", "kind": "application"},
		],
		"research_signal_definitions": [],
		"research": {
			"technology_states": states,
			"technology_progress": PackedInt64Array([0, 0]),
			"domain_weights_bp": PackedInt32Array([2500, 2500, 2500, 2500]),
			"queue_offsets": PackedInt32Array([0, 0, 0, 0, 0]),
			"queue_technology_indices": PackedInt32Array(),
		},
	}


func _queue_row_count(workspace: Control) -> int:
	var count := 0
	for rows in workspace.get("_queue_rows") as Array:
		count += (rows as Array).size()
	return count


func _contains(items: Array, fragment: String) -> bool:
	for value in items:
		if String((value as Dictionary).get("text", "")).contains(fragment):
			return true
	return false


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
