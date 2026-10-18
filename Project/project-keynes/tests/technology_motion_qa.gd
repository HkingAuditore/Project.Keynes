extends SceneTree

## Deterministic presentation fixture, no world generation or simulation writes.
## --headless: integration assertions. -- --capture: PNGs plus animation frames.
const Workspace := preload("res://scenes/ui/technology_workspace.tscn")
const Catalog := preload("res://scripts/economy/technology_catalog.gd")
const OUTPUT := "res://tmp/technology_motion_qa"
var _failures := 0
var _capture := false
var _model: Dictionary
var _workspace: Control


func _init() -> void:
	_capture = "--capture" in OS.get_cmdline_user_args()
	call_deferred("_run")


func _run() -> void:
	var settings := root.get_node("GameSettings")
	var previous_settings: Dictionary = settings.values()
	settings.update({"reduce_motion": false, "window_mode": "windowed"}, false)
	root.size = Vector2i(1280, 720)
	var compiled: Dictionary = Catalog.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	var definitions: Array = Catalog.public_definitions(compiled)
	var domains: Array = Catalog.public_domain_metadata()
	var eras: Array = Catalog.public_era_metadata()
	var states := PackedInt32Array()
	var progress := PackedInt64Array()
	states.resize(definitions.size())
	progress.resize(definitions.size())
	var queue := PackedInt32Array()
	var offsets := PackedInt32Array([0])
	# A small known stone-age frontier, using the real topology and names.
	for domain in range(4):
		var domain_nodes: Array[int] = []
		for index in range(definitions.size()):
			var definition: Dictionary = definitions[index]
			if String(definition.get("era_id", "")) == String((eras[0] as Dictionary).get("id", "")) \
					and String(definition.get("domain_id", "")) == String((domains[domain] as Dictionary).get("id", "")) \
					and not bool(definition.get("is_milestone", false)):
				domain_nodes.append(index)
		for cursor in range(mini(7, domain_nodes.size())):
			var index := domain_nodes[cursor]
			states[index] = 5 if cursor < 2 else 2
			if cursor == 2:
				states[index] = 3
				var cost := int((definitions[index] as Dictionary).get("cost_points_scaled",
					int((definitions[index] as Dictionary).get("cost_points", 1)) * 1000))
				progress[index] = int(float(cost) * (0.28 + float(domain) * 0.15))
				queue.append(index)
		offsets.append(queue.size())
	_expect("fixture has four live research lanes", queue.size() == 4)
	if queue.is_empty():
		settings.update(previous_settings, false)
		quit(1)
		return
	_model = {"country_handle": 0, "technology_definitions": definitions,
		"technology_eras": Catalog.public_era_metadata(),
		"technology_domains": Catalog.public_domain_metadata(),
		"technology_lanes": Catalog.public_lane_metadata(),
		"technology_visual_edges": Catalog.public_visual_edges(),
		"research": {"technology_states": states, "technology_progress": progress,
			"domain_weights_bp": PackedInt32Array([2500, 2500, 2500, 2500]),
			"queue_offsets": offsets, "queue_technology_indices": queue,
			"technology_points_stock": 125000, "country_cash": 540000000,
			"last_research_day": 12, "daily_procurement_budget": 10000000,
			"auto_purchase_enabled": true}}
	var host := Panel.new()
	host.theme = load("res://assets/themes/player_session_theme.tres") as Theme
	host.add_theme_stylebox_override("panel", host.theme.get_stylebox("panel", "PKCountryPage"))
	root.add_child(host)
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_workspace = Workspace.instantiate()
	host.add_child(_workspace)
	_workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_workspace.set_model(_model)
	await _settle()
	var list: Control = _workspace.available_view().list_canvas()
	# Headless rendering does not dispatch _draw; sync explicitly for assertions.
	list.call("_sync_effects")
	var list_fx := list.get_node("ResearchEffects") as Control
	_expect("hydration never celebrates old completions", (list_fx.get("_bursts") as Array).is_empty())
	_expect("effect canvas ignores input", list_fx.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_expect("live research enables its independent animation", list_fx.is_processing())
	var list_states := states.duplicate()
	list_states.fill(5)
	list_states[int(queue[0])] = 4
	list.patch_states(list_states, progress)
	list.call("_sync_effects")
	_expect("desk completion also receives its seal burst", (list_fx.get("_bursts") as Array).size() == 1)
	list_states[int(queue[0])] = 5
	list.patch_states(list_states, progress)
	list.call("_sync_effects")
	_expect("departed cards leave no effects on the next card", (list_fx.get("_bursts") as Array).is_empty())
	list.patch_states(states, progress)
	list.call("_sync_effects")
	if _capture:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT + "/frames"))
		await _snapshot("available_1280x720")
	_workspace.call("_set_mode", 1)
	await _settle()
	var tree: Control = _workspace.tree_view()
	tree.call("_sync_effects")
	var fx := tree.get_node("ResearchEffects") as Control
	_expect("hidden desk stops its frame processing", not list_fx.is_processing())
	var selected := int(queue[0])
	tree.select_technology(selected)
	_workspace.call("_on_tree_selected", selected)
	tree.call("_sync_effects")
	_expect("known selection creates directional route streams", not (fx.get("_streams") as Array).is_empty())
	var base_draws := [0]
	tree.draw.connect(func() -> void: base_draws[0] += 1)
	await _settle()
	base_draws[0] = 0
	await create_timer(0.22).timeout
	_expect("ambient effects do not redraw the text canvas every frame", int(base_draws[0]) <= 1)
	var geometry: Dictionary = tree.focus_report()
	var target_rect := Rect2()
	for node in geometry.get("nodes", []):
		if int(node.index) == selected:
			target_rect = node.rect
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = target_rect.get_center() + (tree.get("_offset") as Vector2)
	tree.call("_gui_input", event)
	_expect("selection remains clickable under the effects", tree.selected_technology() == selected)
	var shifted := (tree.get("_offset") as Vector2) + Vector2(0, -60)
	tree.set("_offset", shifted)
	tree.call("_sync_effects")
	_expect("effect coordinates track panning", fx.get("content_offset") == shifted)
	tree.call("frame_frontier")
	# Bring the same queued card fully into view before capturing its completion.
	tree.set("_offset", Vector2((tree.get("_offset") as Vector2).x,
		tree.size.y * 0.45 - target_rect.get_center().y))
	tree.call("_clamp_offset")
	tree.call("_sync_effects")
	# Completion emits once; the later pending -> active transition is quiet.
	states[selected] = 4
	tree.patch_states(states, progress)
	tree.call("_sync_effects")
	_expect("research completion emits a seal burst", (fx.get("_bursts") as Array).size() == 1)
	states[selected] = 5
	tree.patch_states(states, progress)
	tree.call("_sync_effects")
	_expect("activation does not celebrate the same completion twice", (fx.get("_bursts") as Array).size() == 1)
	if _capture:
		await _snapshot("breakthrough_1280x720", 0.08)
		# Record actual game-rendered frames, including a fresh completion at frame 18.
		for frame in range(54):
			if frame == 0:
				states[selected] = 3
				tree.patch_states(states, progress)
				fx.set_interaction(-1, -1)
				tree.call("_sync_effects")
				UIAnimation.reveal_technology_page(tree)
			if frame == 18:
				states[selected] = 4
				tree.patch_states(states, progress)
			await _snapshot("frames/%03d" % frame, 1.0 / 18.0)
	for _attempt in range(20):
		states[selected] = 2
		tree.patch_states(states, progress)
		tree.call("_sync_effects")
		states[selected] = 3
		tree.patch_states(states, progress)
		tree.call("_sync_effects")
	_expect("effect bursts stay bounded under rapid state changes", (fx.get("_bursts") as Array).size() == 12)
	settings.update({"reduce_motion": true}, false)
	_expect("reduced motion stops continuous effects immediately", not fx.is_processing())
	_expect("reduced motion clears transient particles", (fx.get("_bursts") as Array).is_empty())
	UIAnimation.reveal_technology_page(tree)
	_expect("reduced motion shows the page without a reveal shader", tree.material == null)
	settings.update({"reduce_motion": false}, false)
	_expect("restoring motion restarts live routes", fx.is_processing())
	_workspace.hide()
	_expect("closed workspace performs no effect processing", not fx.is_processing())
	states[selected] = 5
	tree.patch_states(states, progress)
	_workspace.show()
	tree.call("_sync_effects")
	_expect("reopening does not replay hidden completion events", (fx.get("_bursts") as Array).is_empty())
	if _capture:
		for viewport_size in [Vector2i(1280, 720), Vector2i(1920, 1080)]:
			DisplayServer.window_set_size(viewport_size)
			root.size = viewport_size
			await _settle()
			for mode in range(3):
				_workspace.call("_set_mode", mode)
				await _snapshot("%s_%dx%d" % [["available", "tree", "overview"][mode], viewport_size.x, viewport_size.y])
	_workspace.queue_free()
	host.queue_free()
	await process_frame
	settings.update(previous_settings, false)
	print("=== technology motion QA: %d failures ===" % _failures)
	quit(0 if _failures == 0 else 1)


func _settle() -> void:
	await process_frame
	await process_frame


func _snapshot(label: String, delay: float = 0.6) -> void:
	await create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	_expect("capture " + label, image != null and image.save_png(OUTPUT + "/" + label + ".png") == OK)


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("[PASS] " + label)
	else:
		_failures += 1
		push_error("[FAIL] " + label)
