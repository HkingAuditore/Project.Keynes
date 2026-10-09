extends SceneTree

## Headless smoke test for the technology authoring workbench.
##
## The prototype it replaces rebuilt 369 GraphNodes on every field edit. The
## assertions below lock in the opposite behaviour: one Control draws the whole
## network, field edits never rebake the layout, and the inspector genuinely
## covers every authored schema field.

const EditorScene := preload("res://scenes/tools/technology_tree_authoring_editor.tscn")
const InspectorScript = preload(
	"res://scripts/tools/technology_authoring/technology_authoring_inspector.gd")

const NETWORK_PATH := "res://data/technology/technology_network.json"
## `id` is renamed through `rename_node`, not edited as a field. The rationale
## arrays deliberately have no standalone editor: they are written only through
## the paired relation editors, which is what stops the two sides from drifting.
const UNCOVERED_BY_DESIGN := ["id", "prerequisite_rationales",
	"branch_successor_rationales", "application_target_rationales"]

const CANVAS_PATH := "Root/Body/WorkArea/CenterSplit/ViewHost/GraphCanvas"

var _failures := 0


func _init() -> void:
	get_root().size = Vector2i(1920, 1080)
	var before := FileAccess.get_file_as_string(NETWORK_PATH)
	var editor := EditorScene.instantiate() as Control
	get_root().add_child(editor)
	await process_frame
	await process_frame

	var boot: Dictionary = editor.call("report")
	var canvas: Dictionary = boot.canvas
	print("  [info] baked %d nodes / %d edges in %.2fms, %d findings" % [
		int(canvas.nodes), int(canvas.edges), float(canvas.bake_msec),
		int(boot.findings)])
	_expect("editor bakes the whole network", int(canvas.nodes) == int(boot.nodes)
		and int(canvas.nodes) > 300)
	_expect("canvas carries the full visual edge set", int(canvas.edges) > 1300)
	_expect("canvas draws without child controls", int(canvas.child_count) == 0)
	_expect("layout bake stays inside the cold-start budget",
		float(canvas.bake_msec) <= 1500.0)
	_expect("table view has one row per technology",
		int(boot.table_rows) == int(boot.nodes))
	_expect("problems dock loaded the shared validator findings",
		int(boot.findings) > 0)

	await _check_shell_layout(editor)
	await _check_edge_filters(editor)
	await _check_problem_jump(editor)

	var target := _first_technology(editor)
	editor.call("select_technology", target)
	await process_frame
	_expect("inspector builds for the selected technology",
		int(editor.call("inspector_row_count")) > 20)
	_check_inspector_coverage(editor)

	var row: Dictionary = editor.call("technology_row", target)
	var original := String(row.get("display_name", ""))
	var rebakes_before := int((editor.call("report") as Dictionary).rebakes)
	editor.call("commit_field", target, "display_name", "%s·测试" % original)
	await process_frame
	var after_edit: Dictionary = editor.call("report")
	_expect("field edit lands in the model",
		String((editor.call("technology_row", target) as Dictionary).display_name)
		== "%s·测试" % original)
	_expect("a field edit never rebakes the graph",
		int(after_edit.rebakes) == rebakes_before)

	await _check_shortcuts(editor, target, original)

	editor.call("set_search_text", "灌溉")
	await process_frame
	var filtered: Dictionary = editor.call("report")
	print("  [info] filter pass in %.3fms" % float(filtered.filter_msec))
	_expect("filtering stays interactive", float(filtered.filter_msec) <= 8.0)
	_expect("filtering actually narrows the set",
		int(filtered.matches) > 0 and int(filtered.matches) < int(boot.nodes))
	await _check_unlock_search(editor)
	editor.call("set_search_text", "")
	await process_frame

	editor.call("show_view", false)
	await process_frame
	editor.call("show_view", true)
	await process_frame

	var canvas_node: Control = editor.get_node(CANVAS_PATH)
	canvas_node.call("fit_to_content")
	canvas_node.queue_redraw()
	await process_frame
	await process_frame
	var drawn: Dictionary = canvas_node.call("report")
	print("  [info] draw pass %d nodes / %d edges in %dus at zoom %.2f" % [
		int(drawn.visible_nodes), int(drawn.visible_edges), int(drawn.draw_usec),
		float(drawn.zoom)])
	_expect("draw pass culls to the viewport",
		int(drawn.visible_nodes) > 0 and int(drawn.visible_nodes) <= int(drawn.nodes))
	_expect("draw pass fits a frame budget", int(drawn.draw_usec) <= 33000)

	var structural_before := int((editor.call("report") as Dictionary).rebakes)
	var model = editor.call("authoring_model")
	model.begin_batch("smoke insert")
	var added: Dictionary = model.add_node(model.new_node_template("tech.smoke_probe",
		"冒烟探针", String(row.get("era_id", "")), String(row.get("domain_id", "")),
		String(row.get("branch_family_id", ""))), target)
	model.commit_batch()
	await process_frame
	var structural: Dictionary = editor.call("report")
	_expect("structural insert succeeds", bool(added.ok))
	_expect("a structural change rebakes exactly once",
		int(structural.rebakes) == structural_before + 1)
	_expect("table gains the new row",
		int(structural.table_rows) == int(boot.nodes) + 1)
	model.undo()
	await process_frame
	var reverted: Dictionary = editor.call("report")
	_expect("undo removes the inserted row",
		int(reverted.table_rows) == int(boot.nodes))
	_expect("undo of a structural change rebakes again",
		int(reverted.rebakes) == structural_before + 2)

	editor.call("validate_now")
	await process_frame
	var after := FileAccess.get_file_as_string(NETWORK_PATH)
	_expect("the smoke test never wrote the authored network", before == after)
	editor.queue_free()
	_finish()


func _first_technology(editor: Control) -> String:
	var model = editor.call("authoring_model")
	var ids: PackedStringArray = model.ids()
	for id in ids:
		var row: Dictionary = model.node(String(id))
		if not (row.get("modifier_terms", []) as Array).is_empty():
			return String(id)
	return String(ids[0]) if not ids.is_empty() else ""


## Every authored schema field must have exactly one inspector editor, or the
## workbench would silently hide data the gate still validates.
func _check_inspector_coverage(editor: Control) -> void:
	var model = editor.call("authoring_model")
	var authored := {}
	for node_value in model.nodes():
		for key in (node_value as Dictionary):
			authored[String(key)] = true
	var covered := {}
	var duplicated := PackedStringArray()
	for key in InspectorScript.covered_keys():
		if covered.has(String(key)):
			duplicated.append(String(key))
		covered[String(key)] = true
	var missing := PackedStringArray()
	for key in authored:
		var name := String(key)
		if covered.has(name) or UNCOVERED_BY_DESIGN.has(name):
			continue
		missing.append(name)
	if not missing.is_empty():
		print("  [info] inspector is missing: %s" % ", ".join(missing))
	_expect("inspector covers every authored schema field", missing.is_empty())
	_expect("no schema field has two inspector editors", duplicated.is_empty())
	var stale := PackedStringArray()
	for key in covered:
		var name := String(key)
		if not authored.has(name):
			stale.append(name)
	if not stale.is_empty():
		print("  [info] inspector edits fields absent from the data: %s" % ", ".join(stale))


## Ctrl+Z must reach the model, and it must not fire while the author is typing
## in a text field, where the LineEdit's own undo has to win.
func _check_shortcuts(editor: Control, target: String, original_name: String) -> void:
	var edited := "%s·测试" % original_name
	editor.call("focus_search_field")
	_send_key(editor, KEY_Z, true, false)
	await process_frame
	_expect("Ctrl+Z is left to the focused text field",
		String((editor.call("technology_row", target) as Dictionary).display_name) == edited)
	editor.call("focus_canvas")
	_send_key(editor, KEY_Z, true, false)
	await process_frame
	_expect("Ctrl+Z undoes the field edit once the canvas has focus",
		String((editor.call("technology_row", target) as Dictionary).display_name)
		== original_name)
	_send_key(editor, KEY_Z, true, true)
	await process_frame
	_expect("Ctrl+Shift+Z redoes it",
		String((editor.call("technology_row", target) as Dictionary).display_name) == edited)


func _send_key(editor: Control, keycode: Key, ctrl: bool, shift: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	editor.get_viewport().push_input(event)


## A finding must be actionable: clicking it has to land on the named field of
## the named node, and any error has to hold the save button shut.
## The shell used to demand 1292px of minimum width, which overflowed the
## viewport and squeezed the graph pane down to 22px tall. What reached the
## screen was then a thin slice of the network dominated by edges whose nodes
## were clipped away, and every window resize moved the slice somewhere else.
func _check_shell_layout(editor: Control) -> void:
	var shell := editor.get_node("Root") as Control
	var canvas := editor.get_node(CANVAS_PATH) as Control
	# The editor Control only picks up the viewport size once a resize has been
	# processed, so drive the measurement from an explicit one.
	get_root().size = Vector2i(1600, 900)
	await process_frame
	await process_frame
	var shell_width := editor.size.x
	_expect("the shell fits the viewport instead of overflowing it",
		shell.get_combined_minimum_size().x <= shell_width
		and shell.size.x <= shell_width + 1.0)
	_expect("the graph pane gets most of the window",
		canvas.size.x >= shell_width * 0.4 and canvas.size.y >= 240.0)

	var before: Dictionary = canvas.call("edge_alignment_report")
	_expect("edges terminate on their nodes", float(before.worst_gap) <= 0.5
		and int(before.checked) > 0)

	get_root().size = Vector2i(1180, 700)
	await process_frame
	await process_frame
	var after: Dictionary = canvas.call("edge_alignment_report")
	_expect("a resize keeps edges welded to their nodes",
		float(after.worst_gap) <= 0.5 and int(after.checked) == int(before.checked))
	_expect("a resize keeps the graph centred rather than pinned to a corner",
		not is_equal_approx(float(before.offset.x), float(after.offset.x)))
	get_root().size = Vector2i(1920, 1080)
	await process_frame
	await process_frame


func _check_edge_filters(editor: Control) -> void:
	var canvas := editor.get_node(CANVAS_PATH) as Control
	var box := editor.get_node("Root/Body/LeftDock/EdgeKindBox") as VBoxContainer
	var toggle: CheckBox = null
	for child in box.get_children():
		if (child as CheckBox).text == "替代路线":
			toggle = child
	_expect("the hidden edge kinds have a visible switch",
		toggle != null and not toggle.button_pressed)
	if toggle == null:
		return
	var hidden := int((canvas.call("report") as Dictionary).visible_edges)
	toggle.button_pressed = true
	canvas.queue_redraw()
	await process_frame
	await process_frame
	var shown := int((canvas.call("report") as Dictionary).visible_edges)
	_expect("turning on an edge kind draws more edges", shown > hidden)
	toggle.button_pressed = false
	canvas.queue_redraw()
	await process_frame
	await process_frame


func _check_problem_jump(editor: Control) -> void:
	var jumped := false
	var has_error := false
	for value in editor.call("findings"):
		var row: Dictionary = value
		if String(row.get("severity", "")) == "error":
			has_error = true
		if jumped or String(row.get("node_id", "")).is_empty() \
				or String(row.get("field", "")).is_empty():
			continue
		jumped = await editor.call("focus_problem", String(row.node_id),
			String(row.field))
		_expect("clicking a problem focuses the offending field", jumped)
	if not jumped:
		print("  [info] no finding carried both a node id and a field")
	_expect("errors keep the save button disabled",
		bool(editor.call("save_blocked")) == has_error)
	# A blocked save must not be a dead end: the committed network already has
	# errors, so without a draft path an authoring session could never persist.
	_expect("a draft save stays available while errors remain",
		not bool(editor.call("draft_save_blocked")))


## Searching an unlocked building's display name must find the technology that
## unlocks it: that cross-file lookup is the reason the index exists.
func _check_unlock_search(editor: Control) -> void:
	var probe: Dictionary = editor.call("unlock_search_probe")
	if probe.is_empty():
		print("  [info] no .tres unlock carries a display name to search for")
		return
	editor.call("set_search_text", String(probe.needle))
	await process_frame
	var matched: Dictionary = editor.call("report")
	_expect("searching an unlocked building name finds its technology",
		bool(editor.call("is_match", String(probe.technology_id))))
	_expect("unlock search stays interactive", float(matched.filter_msec) <= 8.0)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1


func _finish() -> void:
	print("technology authoring editor smoke: %d failures" % _failures)
	quit(1 if _failures > 0 else 0)
