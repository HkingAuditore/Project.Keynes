extends SceneTree

const WorkspaceScene := preload("res://scenes/ui/technology_workspace.tscn")
const DialScene := preload("res://scenes/ui/research_weight_dial.tscn")
const DialScript = preload("res://scripts/ui/components/research_weight_dial.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const TechnologyTreeLayoutScript = preload("res://scripts/ui/technology_tree_layout.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

var _failures := 0


func _init() -> void:
	var initialization_started := Time.get_ticks_usec()
	var compiled: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	_expect("technology catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var definitions: Array = TechnologyCatalogScript.public_definitions(compiled)
	var eras: Array = TechnologyCatalogScript.public_era_metadata()
	var domains: Array = TechnologyCatalogScript.public_domain_metadata()
	var visual_edges: Array = TechnologyCatalogScript.public_visual_edges()
	var baked_layout: Dictionary = TechnologyTreeLayoutScript.build(
		definitions, eras, domains, visual_edges)
	var initialization_ms := float(Time.get_ticks_usec() - initialization_started) / 1000.0
	print("  [info] catalog compile + public metadata + layout %.3fms" % initialization_ms)
	_expect("technology layout compiles", bool(baked_layout.get("ok", false)))
	_expect("debug catalog compile and layout stay below 250ms", initialization_ms <= 250.0)
	_expect("era metadata carries display names", eras.size() == 11 \
		and String((eras[0] as Dictionary).get("display_name", "")) == "石器时代")
	_expect("domain metadata carries four accents", domains.size() == 4)

	get_root().size = Vector2i(1280, 720)
	var host := Control.new()
	host.size = Vector2(1240.0, 600.0)
	get_root().add_child(host)
	var workspace := WorkspaceScene.instantiate() as Control
	host.add_child(workspace)
	workspace.set_model(_model(definitions, eras, domains))
	await process_frame
	await process_frame
	# CountryPanel opens with a shell and hydrates the section on a deferred
	# frame.  The first research refresh must bootstrap the static catalog; a
	# state-only patch would leave the center canvas empty in the player build.
	var deferred_workspace := WorkspaceScene.instantiate() as Control
	host.add_child(deferred_workspace)
	deferred_workspace.set_model({"available": false, "reason": "loading"})
	deferred_workspace.refresh_research(_model(definitions, eras, domains))
	var deferred_tree: Control = deferred_workspace.tree_view()
	_expect("deferred research refresh bootstraps technology catalog",
		deferred_tree != null and deferred_tree.visibility_report().get("total", 0) == definitions.size())
	deferred_workspace.queue_free()
	var stable_visibility: Dictionary = workspace.tree_view().visibility_report()
	workspace.refresh_research({"available": false, "reason": "country snapshot pending"})
	_expect("invalid research refresh preserves the visible technology tree",
		workspace.tree_view().visibility_report() == stable_visibility)
	var maize := (compiled.technology_ids as PackedStringArray).find(
		"tech.maize_identification")
	_expect("technology presentation is fully Chinese",
		String((definitions[maize] as Dictionary).get("display_name", "")) == "玉米辨识"
		and not String((definitions[maize] as Dictionary).get("effect_summary", "")).is_empty()
		and not String((definitions[maize] as Dictionary).get("effect_summary", "")).contains(
			"大田作物农业")
		and String(((definitions[maize] as Dictionary).get(
			"route_display_names", PackedStringArray()) as PackedStringArray)[0])
			== "作物 · 玉米")
	var condition_states: PackedInt32Array = (
		workspace.get("_research").technology_states as PackedInt32Array).duplicate()
	condition_states[(compiled.technology_ids as PackedStringArray).find(
		"tech.natural_observation")] = 5
	condition_states[maize] = 2
	var condition_items: Array = workspace._condition_items(
		maize, condition_states)
	_expect("revealed technology conditions expose discovered evidence",
		_items_contain(condition_items, "玉米") and
		_items_contain(condition_items, "地块 7"))
	var plantation := (compiled.technology_ids as PackedStringArray).find(
		"tech.estate_plantation_management")
	condition_states[plantation] = 2
	var route_items: Array = workspace._condition_items(plantation, condition_states)
	_expect("technology detail explains independent research routes",
		_items_contain(route_items, "研究条件 · 土地制度路线") and
		not _items_contain(route_items, "替代研究条件"))
	var development_title := workspace.get_node(
		"Root/Main/PolicyPanel/Scroll/Body/DevelopmentTitle") as Label
	var development_list := workspace.get_node(
		"Root/Main/PolicyPanel/Scroll/Body/DevelopmentList") as VBoxContainer
	_expect("development board shows only current-era neutral objectives",
		development_title.visible and development_list.visible and
		development_list.get_child_count() == 1 and
		not development_title.text.contains("科技"))
	var tree: Control = workspace.tree_view()
	_expect("tree view exists", tree != null)
	if tree == null:
		_finish()
		return
	_expect("tree view draws itself instead of spawning nodes",
		tree.get_child_count() == 0)

	var layout: Dictionary = tree.layout_report()
	_audit_layout(layout, definitions)
	_audit_fog(tree, layout)
	_audit_dial()
	await _audit_fit(workspace, tree)
	_audit_refresh(workspace, tree, definitions, eras, domains)
	_audit_navigation(workspace, tree, definitions)
	_finish()


func _model(definitions: Array, eras: Array, domains: Array) -> Dictionary:
	var signal_definitions: Array = ResearchSignalCatalogScript.public_metadata()
	var maize_signal_id := -1
	for index in range(signal_definitions.size()):
		if String((signal_definitions[index] as Dictionary).get("id", "")) == "bio.maize":
			maize_signal_id = index
			break
	assert(maize_signal_id >= 0)
	var states := PackedInt32Array()
	var progress := PackedInt64Array()
	states.resize(definitions.size())
	progress.resize(definitions.size())
	for index in range(4):
		states[index] = 5
	for index in range(4, 8):
		states[index] = 2
	states[4] = 3
	progress[4] = 500 * 1000
	var population_objective: Dictionary = {}
	for definition in DevelopmentAchievementCatalogScript.definitions():
		if String(definition.get("signal_id", "")) == "development.population.100_90d":
			population_objective = definition.duplicate(true)
			break
	return {
		"country_handle": 0,
		"technology_definitions": definitions,
		"technology_eras": eras,
		"technology_domains": domains,
		"technology_visual_edges": TechnologyCatalogScript.public_visual_edges(),
		"technology_lanes": TechnologyCatalogScript.public_lane_metadata(),
		"research_signal_definitions": signal_definitions,
		"development": {
			"ok": true,
			"era_id": "stone",
			"objectives": [population_objective],
			"progress_by_signal": {
				"development.population.100_90d": {
					"current_value": 80,
					"qualifier_threshold": 100,
					"consecutive_days": 45,
					"target_days": 90,
					"completed": 0,
				},
			},
		},
		"research": {
			"technology_states": states,
			"technology_progress": progress,
			"domain_weights_bp": PackedInt32Array([2500, 2500, 2500, 2500]),
			"queue_offsets": PackedInt32Array([0, 1, 1, 1, 1]),
			"queue_technology_indices": PackedInt32Array([4]),
			"auto_purchase_enabled": true,
			"daily_procurement_budget": 10000000,
			"technology_points_stock": 10000,
			"country_cash": 500000000,
			"last_research_day": 12,
			"research_signal_snapshot": {
				"ok": true,
				"signal_ids": PackedInt32Array([maize_signal_id]),
				"counts": PackedInt32Array([1]),
				"first_days": PackedInt64Array([4]),
				"last_days": PackedInt64Array([12]),
				"first_cells": PackedInt32Array([7]),
			},
		},
	}


func _items_contain(items: Array, fragment: String) -> bool:
	for item in items:
		if String((item as Dictionary).get("text", "")).contains(fragment):
			return true
	return false


func _audit_layout(layout: Dictionary, definitions: Array) -> void:
	var nodes: Array = layout.get("nodes", [])
	var bands: Array = layout.get("bands", [])
	_expect("layout covers the whole catalog", nodes.size() == definitions.size())
	_expect("layout bands one per era", bands.size() == 11)
	var descending := true
	for edge in layout.get("edges", []) as Array:
		var data: Dictionary = edge
		if String(data.get("kind", "hard")) != "hard":
			continue
		var parent: Rect2 = (nodes[int(data.from)] as Dictionary).rect
		var child: Rect2 = (nodes[int(data.to)] as Dictionary).rect
		if child.position.y <= parent.position.y:
			descending = false
			break
	_expect("every hard dependency edge points strictly downwards", descending)
	var ordered := true
	for index in range(bands.size() - 1):
		var current: Dictionary = bands[index]
		var following: Dictionary = bands[index + 1]
		if float(current.bottom) > float(following.top):
			ordered = false
			break
	_expect("era bands never overlap or invert", ordered)
	var milestones_centred := true
	var milestones_last := true
	for index in range(nodes.size()):
		var node: Dictionary = nodes[index]
		if not bool(node.is_milestone):
			continue
		var rect: Rect2 = node.rect
		if absf(rect.position.x + rect.size.x * 0.5) > 0.5:
			milestones_centred = false
		var rows: Array = (bands[int(node.era_index)] as Dictionary).rows
		if int(node.layer) != rows.size() - 1:
			milestones_last = false
	_expect("era milestones are horizontally centred", milestones_centred)
	_expect("era milestones terminate their band", milestones_last)


func _audit_fog(tree: Control, layout: Dictionary) -> void:
	var report: Dictionary = tree.visibility_report()
	var parents: Array = layout.get("parents", [])
	_expect("only eight technologies are known at the start",
		int(report.known) == 8)
	_expect("fog keeps the visible set far below the catalog size",
		int(report.visible) < int(report.total) / 3
		and int(report.visible) > int(report.known))
	_expect("fog hides later eras entirely",
		int(report.visible_bands) < int(report.total_bands))
	var states: PackedInt32Array = tree.get("_states")
	var visible: PackedByteArray = tree.get("_visible_nodes")
	var consistent := true
	for index in range(visible.size()):
		var reachable := TechnologyTreeView.presents_state(int(states[index]))
		if not reachable:
			for parent in parents[index]:
				if TechnologyTreeView.presents_state(int(states[int(parent)])):
					reachable = true
					break
		if (visible[index] != 0) != reachable:
			consistent = false
			break
	_expect("visible set is exactly researchable nodes plus their unknown frontier", consistent)
	var locked := -1
	for index in range(states.size()):
		if int(states[index]) != 0:
			continue
		if bool((tree.get("_definitions")[index] as Dictionary).get("is_milestone", false)):
			continue
		var parent_presented := false
		for parent in parents[index]:
			if TechnologyTreeView.presents_state(int(states[int(parent)])):
				parent_presented = true
				break
		if parent_presented:
			locked = index
			break
	_expect("the opening frontier has a child that can be locked for the fog check", locked >= 0)
	if locked >= 0:
		var locked_name := String((tree.get("_definitions")[locked] as Dictionary).get(
			"display_name", ""))
		states[locked] = 1
		tree.patch_states(states, tree.get("_progress"))
		var known_nodes: PackedByteArray = tree.get("_known_nodes")
		var visible_nodes: PackedByteArray = tree.get("_visible_nodes")
		_expect("revealed-but-locked nodes stay unnamed", int(known_nodes[locked]) == 0)
		_expect("revealed-but-locked nodes remain unknown frontier",
			int(visible_nodes[locked]) != 0)
		_expect("tooltip does not leak locked technology names",
			not String(tree._tooltip_for(locked)).contains(locked_name))
		states[locked] = 0
		tree.patch_states(states, tree.get("_progress"))


func _audit_dial() -> void:
	var dial := DialScene.instantiate() as Control
	get_root().add_child(dial)
	dial.size = Vector2(200.0, 226.0)
	var centre := dial.size * 0.5
	var radius: float = dial._radius()
	_expect("the dial ring is large enough to aim at", radius >= 68.0)
	var commits: Array = []
	dial.weights_committed.connect(func(weights: PackedInt32Array) -> void:
		commits.append(weights)
	)
	# At the 25% baseline a linear radius would stack all four handles on the
	# centre pip, which is what made the dial so easy to mis-grab.
	dial.set_weights(PackedInt32Array([2500, 2500, 2500, 2500]))
	var balanced_reach: float = (dial._handle_position(0) - centre).length()
	_expect("balanced weights push the handles out to the balance ring",
		balanced_reach >= radius * 0.45)
	_expect("balanced handles clear the centre dead zone",
		balanced_reach > float(DialScript.CENTRE_RADIUS) + 8.0)
	var normalised := true
	var non_negative := true
	for sample in [
		{"domain": 0, "grab": Vector2(0.0, -40.0), "drop": Vector2(0.0, -radius)},
		{"domain": 1, "grab": Vector2(radius * 0.9, 0.0), "drop": Vector2(6.0, 0.0)},
		{"domain": 2, "grab": Vector2(20.0, 34.0), "drop": Vector2(0.0, radius * 0.72)},
		{"domain": 3, "grab": Vector2(-30.0, 0.0), "drop": Vector2(-400.0, 0.0)},
		{"domain": 0, "grab": Vector2(0.0, -30.0), "drop": Vector2(0.0, -radius * 0.95)},
	]:
		dial.set_weights(PackedInt32Array([4000, 3000, 2000, 1000]))
		_press(dial, centre + (sample.grab as Vector2))
		_expect("pressing along an arm grabs that domain",
			dial.get("_dragging") == int(sample.domain))
		_move(dial, centre + (sample.drop as Vector2))
		_release(dial, centre + (sample.drop as Vector2))
		var weights: PackedInt32Array = dial.weights_bp()
		var total := 0
		for weight in weights:
			total += int(weight)
			if int(weight) < 0:
				non_negative = false
		if total != 10000:
			normalised = false
	_expect("dragging any axis keeps the weights summing to 10000", normalised)
	_expect("normalisation never produces negative weights", non_negative)
	_expect("every drag commits exactly once", commits.size() == 5)
	# Mis-touch guards: the centre disc and the diagonal gaps own no axis, and a
	# press that never moves must not send a command.
	_press(dial, centre + Vector2(6.0, -8.0))
	_expect("the centre disc grabs no axis", dial.get("_dragging") == -1)
	_release(dial, centre)
	_press(dial, centre + Vector2(radius * 0.6, radius * 0.6))
	_expect("the diagonal gap between two arms grabs nothing",
		dial.get("_dragging") == -1)
	_release(dial, centre)
	_press(dial, centre + Vector2(-radius - 60.0, 0.0))
	_expect("pressing well outside the ring grabs nothing",
		dial.get("_dragging") == -1)
	_release(dial, centre)
	var before: PackedInt32Array = dial.weights_bp()
	var quiet := commits.size()
	_press(dial, centre + Vector2(0.0, -radius * 0.7))
	_release(dial, centre + Vector2(0.0, -radius * 0.7))
	_expect("a press without movement changes nothing", dial.weights_bp() == before)
	_expect("a press without movement sends no command", commits.size() == quiet)
	# A sloppy aim still lands on the intended arm.
	_press(dial, centre + Vector2(20.0, -radius * 0.8))
	_expect("aiming 20px off an arm still grabs it", dial.get("_dragging") == 0)
	_release(dial, centre + Vector2(20.0, -radius * 0.8))
	dial.set_weights(PackedInt32Array([10000, 0, 0, 0]))
	_expect("snapshot weights round-trip",
		dial.weights_bp() == PackedInt32Array([10000, 0, 0, 0]))
	dial.queue_free()


func _press(control: Control, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = position
	control._gui_input(event)


func _release(control: Control, position: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	event.position = position
	control._gui_input(event)


func _move(control: Control, position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	control._gui_input(event)


# 1280x720 is the supported floor: policy and detail are permanent columns,
# and the tree keeps the remaining centre canvas.
func _audit_fit(workspace: Control, tree: Control) -> void:
	var frame := Rect2(Vector2.ZERO, workspace.size)
	var policy := workspace.get("_policy_panel") as Control
	var detail := workspace.get("_detail_host") as Control
	var columns := {"policy": policy, "tree": tree, "detail": detail}
	var contained := true
	for key in columns:
		var column := columns[key] as Control
		var rect := Rect2(column.global_position - workspace.global_position, column.size)
		print("  [info] %s column %.0f x %.0f at %.0f" % [key, rect.size.x, rect.size.y,
			rect.position.x])
		if not frame.grow(1.0).encloses(rect) or column == tree and rect.size.x <= 0.0:
			contained = false
	_expect("every research column stays inside 1280x720", contained)
	_expect("research policy and detail are permanent working columns",
		tree.offset_left == TechnologyWorkspace.POLICY_WIDTH \
		and tree.offset_right == -TechnologyWorkspace.DETAIL_WIDTH
		and policy.visible and detail.visible
		and policy.size.x == TechnologyWorkspace.POLICY_WIDTH)
	workspace._set_policy_open(false)
	await process_frame
	_expect("policy close requests cannot hide the permanent left column",
		policy.visible and tree.offset_left == TechnologyWorkspace.POLICY_WIDTH)
	workspace._set_detail_open(false)
	await process_frame
	_expect("detail close requests cannot hide the permanent right column",
		detail.visible and policy.visible \
		and tree.offset_right == -TechnologyWorkspace.DETAIL_WIDTH
		and tree.offset_left == TechnologyWorkspace.POLICY_WIDTH)
	var detail_card := workspace.get("_detail") as Control
	var detail_scroll := detail_card.get_node("Column/Scroll") as ScrollContainer
	var detail_body := detail_card.get_node("Column/Scroll/Body") as Control
	var relation_label_scene := preload("res://scenes/ui/technology_relation_row.tscn")
	var relation_row := relation_label_scene.instantiate() as HBoxContainer
	detail_body.add_child(relation_row)
	await process_frame
	var relation_label := relation_row.get_node("Label") as Label
	_expect("detail body and relation rows fit the drawer width",
		detail_scroll.size.x <= detail_card.size.x + 1.0
		and detail_body.size.x <= detail_scroll.size.x + 1.0
		and relation_row.size.x <= detail_body.size.x + 1.0
		and relation_label.autowrap_mode != TextServer.AUTOWRAP_OFF)
	relation_row.queue_free()
	workspace.set_compact(true)
	await process_frame
	print("  [info] compact tree width %.0f" % tree.size.x)
	_expect("compact mode still leaves the tree over 420px wide", tree.size.x >= 420.0)
	_expect("compact mode turns side columns into optional drawers",
		tree.offset_left == TechnologyWorkspace.COMPACT_RAIL_WIDTH \
		and tree.offset_right == -TechnologyWorkspace.COMPACT_RAIL_WIDTH
		and not policy.visible and not detail.visible)
	workspace.set_compact(false)
	await process_frame


func _audit_refresh(workspace: Control, tree: Control, definitions: Array,
		eras: Array, domains: Array) -> void:
	var before_layout: Dictionary = tree.layout_report()
	var before: Rect2 = (before_layout.get("content_rect", Rect2()) as Rect2)
	var before_nodes := (before_layout.get("nodes", []) as Array).size()
	var before_edges := (before_layout.get("edges", []) as Array).size()
	var rows: Array = workspace.get("_queue_rows")
	_expect("queued technology renders one row",
		rows.size() == 4 and (rows[0] as Array).size() == 1)
	if rows.is_empty() or (rows[0] as Array).is_empty():
		return
	var row_id := ((rows[0] as Array)[0] as Node).get_instance_id()
	workspace.refresh_research(_model(definitions, eras, domains))
	var after: Rect2 = (tree.layout_report().get("content_rect", Rect2()) as Rect2)
	_expect("daily refresh keeps the baked geometry", before == after)
	var refreshed: Array = workspace.get("_queue_rows")
	_expect("daily refresh reuses queue rows instead of rebuilding them",
		((refreshed[0] as Array)[0] as Node).get_instance_id() == row_id)
	_expect("tree view still owns no child nodes", tree.get_child_count() == 0)
	var user_offset: Vector2 = tree.get("_offset") + Vector2(-8.0, -8.0)
	tree.set("_offset", user_offset)
	tree.call("_clamp_offset")
	user_offset = tree.get("_offset")
	tree.call("_rebuild_focus", false)
	await process_frame
	var restored_offset: Vector2 = tree.get("_offset")
	_expect("research state refresh preserves the user's atlas viewport",
		restored_offset.distance_to(user_offset) < 0.1)
	var refresh_samples := PackedFloat64Array()
	var steady_model := _model(definitions, eras, domains)
	for iteration in range(1000):
		var started := Time.get_ticks_usec()
		workspace.refresh_research(steady_model)
		refresh_samples.append(float(Time.get_ticks_usec() - started) / 1000.0)
	refresh_samples.sort()
	var p95_index := mini(refresh_samples.size() - 1,
		int(ceil(refresh_samples.size() * 0.95)) - 1)
	var refresh_p95 := refresh_samples[p95_index]
	var final_layout: Dictionary = tree.layout_report()
	print("  [info] 1000 steady refreshes p95 %.3fms" % refresh_p95)
	_expect("1000 refreshes keep node and edge cache sizes stable",
		(final_layout.get("nodes", []) as Array).size() == before_nodes and
		(final_layout.get("edges", []) as Array).size() == before_edges)
	_expect("1000 refreshes preserve baked geometry",
		(final_layout.get("content_rect", Rect2()) as Rect2) == before)
	_expect("1000 refreshes allocate no tree child nodes", tree.get_child_count() == 0)
	_expect("steady technology refresh p95 stays below 1ms", refresh_p95 <= 1.0)


# Focus mode keeps a four-domain atlas inside the centre canvas; overview
# carries the full-network orientation without exposing undiscovered eras.
func _audit_navigation(workspace: Control, tree: Control, definitions: Array) -> void:
	_expect("the tree view exposes no zoom state at all", tree.get("_zoom") == null)
	var initial_nav: Dictionary = workspace.navigation_report()
	_expect("queued research determines the opening focus",
		String(initial_nav.domain) == String((definitions[4] as Dictionary).get("domain_id", ""))
		and int(initial_nav.era) == 0)
	_expect("the toolbar no longer splits the tree by domain tabs",
		workspace.get_node_or_null("Root/Toolbar/Row/DomainTabs") == null)
	var initial_focus: Dictionary = tree.focus_report()
	_expect("focus view contains at most three era bands",
		(initial_focus.get("bands", []) as Array).size() <= 3)
	_expect("focus view exposes four domain lanes on one map",
		(initial_focus.get("lanes", []) as Array).size() == 4)
	var has_milestone := false
	for node_value in initial_focus.get("nodes", []) as Array:
		var node: Dictionary = node_value
		if bool(node.get("is_milestone", false)):
			has_milestone = true
	_expect("focus view includes the era milestone gate", has_milestone)
	var states := PackedInt32Array()
	var progress := PackedInt64Array()
	states.resize(definitions.size())
	progress.resize(definitions.size())
	states.fill(5)
	tree.patch_states(states, progress)
	var full_focus: Dictionary = tree.focus_report()
	var canvas := tree.size
	var bounds: Rect2 = full_focus.get("content_rect", Rect2())
	_expect("full reveal keeps the atlas to a three-era bounded set",
		(full_focus.get("nodes", []) as Array).size() <= 280)
	_expect("focus geometry fills the centre canvas without horizontal overflow",
		bounds.size.x <= canvas.x + 1.0 and bounds.size.x >= canvas.x * 0.92)
	var overflow := false
	var split_column := false
	var focus_has_milestone := false
	var domains_seen := {}
	var xs_by_domain := {}
	for node_value in full_focus.get("nodes", []) as Array:
		var node: Dictionary = node_value
		var rect: Rect2 = node.rect
		if not bounds.grow(1.0).encloses(rect):
			overflow = true
		if bool(node.get("is_milestone", false)):
			focus_has_milestone = true
			continue
		var domain := int(node.get("domain", -1))
		domains_seen[domain] = true
		var x := rect.position.x
		if xs_by_domain.has(domain) and absf(float(xs_by_domain[domain]) - x) > 1.0:
			split_column = true
		xs_by_domain[domain] = x
	_expect("every focus node stays inside the canvas-fitted bounds", not overflow)
	_expect("full reveal still shows era milestones in the focused window",
		focus_has_milestone)
	_expect("focus view keeps all four research domains on one map",
		domains_seen.size() == 4)
	_expect("each research domain occupies a single vertical lane", not split_column)
	workspace._set_mode(1)
	var overview: Control = workspace.overview_view()
	overview.patch_states(states)
	var full_overview: Dictionary = overview.overview_report()
	_expect("overview uses four domain rows after full reveal",
		int(full_overview.visible_domains) == 4 and int(full_overview.visible_eras) == 11)
	var fog_states: PackedInt32Array = (workspace.get("_research").technology_states \
		as PackedInt32Array).duplicate()
	overview.patch_states(fog_states)
	var fog_overview: Dictionary = overview.overview_report()
	_expect("overview keeps the four domain rows while hiding future eras",
		(workspace.get("_domains") as Array).size() == 4
		and int(fog_overview.visible_domains) > 0
		and int(fog_overview.visible_domains) <= 4
		and int(fog_overview.visible_eras) < 11)
	workspace._set_mode(0)


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


func _finish() -> void:
	print("=== technology workspace smoke: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)
