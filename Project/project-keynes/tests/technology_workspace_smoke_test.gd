extends SceneTree

const WorkspaceScene := preload("res://scenes/ui/technology_workspace.tscn")
const DialScene := preload("res://scenes/ui/research_weight_dial.tscn")
const DialScript = preload("res://scripts/ui/components/research_weight_dial.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

var _failures := 0


func _init() -> void:
	var compiled: Dictionary = TechnologyCatalogScript.compile_native_catalog()
	_expect("technology catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		_finish()
		return
	var definitions: Array = TechnologyCatalogScript.public_definitions()
	var eras: Array = TechnologyCatalogScript.public_era_metadata()
	var domains: Array = TechnologyCatalogScript.public_domain_metadata()
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
	_audit_navigation(tree, definitions)
	_finish()


func _model(definitions: Array, eras: Array, domains: Array) -> Dictionary:
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
	return {
		"country_handle": 0,
		"technology_definitions": definitions,
		"technology_eras": eras,
		"technology_domains": domains,
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
		},
	}


func _audit_layout(layout: Dictionary, definitions: Array) -> void:
	var nodes: Array = layout.get("nodes", [])
	var bands: Array = layout.get("bands", [])
	_expect("layout covers the whole catalog", nodes.size() == definitions.size())
	_expect("layout bands one per era", bands.size() == 11)
	var descending := true
	for edge in layout.get("edges", []) as Array:
		var data: Dictionary = edge
		var parent: Rect2 = (nodes[int(data.from)] as Dictionary).rect
		var child: Rect2 = (nodes[int(data.to)] as Dictionary).rect
		if child.position.y <= parent.position.y:
			descending = false
			break
	_expect("every dependency edge points strictly downwards", descending)
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
		int(report.visible) < 24 and int(report.visible) > int(report.known))
	_expect("fog hides later eras entirely",
		int(report.visible_bands) < int(report.total_bands))
	var states: PackedInt32Array = tree.get("_states")
	var visible: PackedByteArray = tree.get("_visible_nodes")
	var consistent := true
	for index in range(visible.size()):
		var reachable := int(states[index]) >= 1
		if not reachable:
			for parent in parents[index]:
				if int(states[int(parent)]) >= 1:
					reachable = true
					break
		if (visible[index] != 0) != reachable:
			consistent = false
			break
	_expect("visible set is exactly discovered plus its unknown frontier", consistent)


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


# 1280x720 is the supported floor: policy column, tree and detail card must all
# stay inside the screen instead of pushing each other out of view.
func _audit_fit(workspace: Control, tree: Control) -> void:
	var frame := Rect2(Vector2.ZERO, workspace.size)
	var policy := workspace.get("_policy_panel") as Control
	var detail := workspace.get("_detail") as Control
	var columns := {"policy": policy, "tree": tree, "detail": detail}
	var contained := true
	for key in columns:
		var column := columns[key] as Control
		var rect := Rect2(column.global_position - workspace.global_position, column.size)
		print("  [info] %s column %.0f x %.0f at %.0f" % [key, rect.size.x, rect.size.y,
			rect.position.x])
		if not frame.grow(1.0).encloses(rect) or rect.size.x <= 0.0:
			contained = false
	_expect("every research column stays inside 1280x720", contained)
	_expect("the tree keeps the dominant share of the screen",
		tree.size.x >= policy.size.x + detail.size.x)
	workspace.set_compact(true)
	await process_frame
	print("  [info] compact tree width %.0f" % tree.size.x)
	_expect("compact mode still leaves the tree over 420px wide", tree.size.x >= 420.0)
	workspace.set_compact(false)
	await process_frame


func _audit_refresh(workspace: Control, tree: Control, definitions: Array,
		eras: Array, domains: Array) -> void:
	var before: Rect2 = (tree.layout_report().get("content_rect", Rect2()) as Rect2)
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


# The wheel scrolls the era stack; it must never scale the tree, and it must not
# be able to push the tree off screen.
func _audit_navigation(tree: Control, definitions: Array) -> void:
	_expect("the tree view exposes no zoom state at all", tree.get("_zoom") == null)
	var states := PackedInt32Array()
	var progress := PackedInt64Array()
	states.resize(definitions.size())
	progress.resize(definitions.size())
	states.fill(5)
	tree.patch_states(states, progress)
	var bounds: Rect2 = tree.visibility_report().get("bounds", Rect2())
	_expect("revealing the catalog makes the tree taller than the viewport",
		bounds.size.y > tree.size.y)
	var start: Vector2 = tree.get("_offset")
	_scroll(tree, MOUSE_BUTTON_WHEEL_DOWN, 1)
	var scrolled: Vector2 = tree.get("_offset")
	_expect("wheel down walks towards later eras", scrolled.y < start.y \
		and is_equal_approx(scrolled.x, start.x))
	_scroll(tree, MOUSE_BUTTON_WHEEL_UP, 1)
	_expect("wheel up returns to the previous row",
		is_equal_approx((tree.get("_offset") as Vector2).y, start.y))
	_scroll(tree, MOUSE_BUTTON_WHEEL_DOWN, 60)
	var floor_offset: Vector2 = tree.get("_offset")
	_expect("scrolling past the last era stops at the content edge",
		floor_offset.y >= tree.size.y - bounds.position.y - bounds.size.y - 0.5)
	_scroll(tree, MOUSE_BUTTON_WHEEL_UP, 120)
	_expect("scrolling past the first era stops at the content edge",
		(tree.get("_offset") as Vector2).y <= -bounds.position.y + 0.5)


func _scroll(tree: Control, button: int, times: int) -> void:
	for _i in range(times):
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.pressed = true
		event.factor = 1.0
		event.position = tree.size * 0.5
		tree._gui_input(event)


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


func _finish() -> void:
	print("=== technology workspace smoke: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)
