extends SceneTree

## Production-map visual acceptance for the military formation prototype.
##
## This harness deliberately mounts the real player_game.tscn: real generated
## MapData, HexRenderer, MapCamera, settlements and terrain. It injects a
## read-only MilitaryRenderFeed into MilitaryMapLayers, then captures the
## production MilitaryArmyTokenLayer at three LODs and all four action states.
##
## Run with rendering (do not add --headless):
##   godot --path Project/project-keynes --resolution 1600x900 \
##     --script res://tests/military/military_formation_map_visual_harness.gd

const CAPTURE_DIR := "res://tmp/military_formation_map_visual"
const MILITARY_CATALOG_PATH := "res://data/military/military_catalog.json"
const SYNTHETIC_FEED_SCRIPT := preload(
	"res://tests/military/synthetic_military_render_feed.gd")
const THEME: Theme = preload("res://assets/themes/player_session_theme.tres")
const DISPLAY_FONT: Font = preload("res://assets/fonts/muyao/display_handwritten.tres")
const SANS_BOLD: Font = preload(
	"res://assets/fonts/swei/SweiGothicLegCJKsc-Bold.ttf")
const SANS: Font = preload(
	"res://assets/fonts/swei/SweiGothicLegCJKsc-Regular.ttf")

const ARMY_COUNT := 6
const SEQUENCE_CROP_SIZE := 720
const HEADCOUNTS := [120, 600, 1800, 4200, 9600, 900]
const HEADINGS_Q16 := [0, 8192, 16384, 24576, 32768, 0]
const UNIT_CLASSES := [0, 1, 2, 1, 0, 0]
const COMPOSITIONS := [
	[["bronze_spearmen", 100]],
	[["cavalry", 68], ["heavy_cavalry", 32]],
	[["field_artillery", 58], ["heavy_artillery", 27], ["siege_train", 15]],
	[["tank_corps", 56], ["early_armor", 31], ["drone_swarm", 13]],
	[["combined_arms", 42], ["field_artillery", 33], ["tank_corps", 25]],
	[],
]
const MEMBER_LABELS := ["1 成员", "2 成员", "3 成员", "4 成员", "5 成员", "纸片 fallback"]
const ACTION_NAMES := ["待命", "行军", "攻击", "受击"]
const LOD_NAMES := ["聚合", "代表", "编队"]
const INK := Color("2b2118")
const MUTED := Color("6b5742")
const RED := Color("9b3324")
const BRASS := Color("a97823")
const CARD := Color(0.91, 0.87, 0.78, 0.92)

var _drawer: Control
var _game: Node
var _host: WorldRuntimeHost
var _map: MapData
var _camera: MapCamera
var _layers
var _token_layer
var _feed
var _clock: WorldClock
var _dense_units: Array = []
var _dense_ids: PackedStringArray = PackedStringArray()
var _cells := PackedInt32Array()
var _home_cell := -1
var _player_slot := -1
var _revision := 1
var _attack_seq: PackedInt32Array = PackedInt32Array()
var _hit_seq: PackedInt32Array = PackedInt32Array()
var _move_from := -1
var _capture_dir := CAPTURE_DIR
var _status_label: Label
var _detail_label: Label
var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("capture_dir="):
			_capture_dir = argument.trim_prefix("capture_dir=")
	DisplayServer.window_set_size(Vector2i(1600, 900))
	root.size = Vector2i(1600, 900)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_capture_dir))
	_build_dense_catalog()
	if _dense_units.size() != 24:
		_finish(2)
		return

	var config := NewGameConfig.create_default()
	config.base.map_width = 44
	config.base.map_height = 30
	config.base.initial_seed = 17
	config.country.foreign_count = 0
	root.get_node("GameFlow").set("_pending_request", {
		"kind": "new_game",
		"config": config.to_dictionary(),
	})

	_feed = SYNTHETIC_FEED_SCRIPT.new()
	_game = load("res://scenes/player_game.tscn").instantiate()
	_host = _game.get_node("RuntimeHost") as WorldRuntimeHost
	_host.military_render_feed = _feed
	_host.fog_of_war_enabled = false
	root.add_child(_game)
	await _host.world_ready
	for _frame in 8:
		await process_frame

	_clock = _game.get_node("WorldClock") as WorldClock
	_clock.pause(true)
	_camera = _game.get_node("MapCamera") as MapCamera
	_map = _host.current_map()
	_layers = _host.military_map_layers
	_expect(_layers != null, "production MilitaryMapLayers is mounted")
	if _layers == null or _map == null or _camera == null:
		_finish(1)
		return
	_token_layer = _layers.token_layer
	_expect(_token_layer != null, "production army token layer exists")

	_prepare_game_view()
	var start_report: Dictionary = _host.get("_generator").gameplay_start_report()
	_home_cell = int(start_report.get("cell", -1))
	if _home_cell < 0:
		_home_cell = int(_host.call("_resolve_player_start_cell"))
	_expect(_home_cell >= 0, "formal player start cell exists")
	_player_slot = int(_host.player_country_slot())
	_cells = _choose_demo_cells(_home_cell)
	_expect(_cells.size() == ARMY_COUNT,
		"found six separated land cells around the formal start")
	if _cells.size() < ARMY_COUNT:
		_finish(1)
		return
	_move_from = _first_land_neighbor(_cells[2])
	_expect(_move_from >= 0, "found a real neighbor for the movement capture")

	_layers.set_fog_override_for_tests(0)
	_layers.set_layers_enabled(true)
	_layers.set_enabled(true)
	var catalog_report: Dictionary = _token_layer.configure_formation_catalog(_dense_units)
	_expect(bool(catalog_report.get("ok", false)),
		"production token layer accepts the 24-unit dense visual catalog")
	if _player_slot < 0:
		_token_layer.set_formation_allow_all_for_tests(true)
	_token_layer.set_player_slot(_player_slot)
	_attack_seq.resize(ARMY_COUNT)
	_attack_seq.fill(0)
	_hit_seq.resize(ARMY_COUNT)
	_hit_seq.fill(0)
	_build_overlay()

	var cluster := _cluster_metrics()
	await _capture_lod("00_game_map_formation_overview", 2, float(cluster.zoom))
	await _capture_lod("01_game_map_formation_idle", 2, float(cluster.close_zoom))
	await _capture_action("02_game_map_formation_move", 1, 2, float(cluster.close_zoom))
	await _capture_action("03_game_map_formation_attack", 2, 2, float(cluster.close_zoom))
	await _capture_action("04_game_map_formation_hit", 3, 2, float(cluster.close_zoom))
	await _capture_lod("05_game_map_representative", 1, 0.55)
	await _capture_lod("06_game_map_aggregate_test_only", 0, 0.30)
	await _capture_lod("07_game_map_fallback_atlas_mixed", 2, float(cluster.close_zoom))
	await _capture_action_focus("08_game_map_action_idle_closeup", 0, 0, 4.0)
	await _capture_action_focus("09_game_map_action_move_closeup", 1, 2, 4.0)
	await _capture_action_focus("10_game_map_action_attack_closeup", 2, 3, 4.0)
	await _capture_action_focus("11_game_map_action_hit_closeup", 3, 4, 4.0)
	await _capture_map_action_sequence(
		"12_game_map_idle_sequence", 0, 0, 4.0)
	await _capture_map_action_sequence(
		"13_game_map_move_sequence", 1, 2, 4.0)
	await _capture_map_action_sequence(
		"14_game_map_attack_sequence", 2, 3, 4.0)
	await _capture_map_action_sequence(
		"15_game_map_hit_sequence", 3, 4, 4.0)
	_finish(0 if _failures.is_empty() else 1)


func _prepare_game_view() -> void:
	# Keep the formal top bar as session proof, but clear panels/tool overlays so
	# the formations can be judged against unobstructed real terrain.
	for path in [
		"UI/UIRoot/PanelLayer/RightPanel",
		"UI/UIRoot/PanelLayer/CountryPanel",
		"UI/UIRoot/HUDLayer/PerfMiniHUD",
		"UI/UIRoot/HUDLayer/MapOverlayToolbar",
		"UI/UIRoot/HUDLayer/CountryActionBar",
		"UI/UIRoot/HUDLayer/MapOverlayLegend",
		"UI/UIRoot/HUDLayer/HudStatusCard",
		"UI/UIRoot/HUDLayer/EraIndicator",
		"UI/UIRoot/ModalLayer",
		"UI/UIRoot/DebugLayer",
	]:
		var node := _game.get_node_or_null(path) as CanvasItem
		if node != null:
			node.visible = false


func _build_overlay() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "MapEvidenceOverlay"
	canvas.layer = 30
	root.add_child(canvas)
	var root_control := Control.new()
	root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_control.theme = THEME
	canvas.add_child(root_control)

	var panel := PanelContainer.new()
	panel.theme_type_variation = "PKPaperCard"
	panel.position = Vector2(28, 78)
	panel.custom_minimum_size = Vector2(520, 0)
	root_control.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 3)
	margin.add_child(stack)
	var kicker := _make_label("PRODUCTION MAP / READ-ONLY SYNTHETIC FEED", 11, RED)
	kicker.add_theme_font_override("font", SANS_BOLD)
	stack.add_child(kicker)
	var title := _make_label("真实游戏地图 · 正俯视部队编队", 24, INK)
	title.add_theme_font_override("font", DISPLAY_FONT)
	stack.add_child(title)
	_status_label = _make_label("", 14, INK)
	_detail_label = _make_label("", 11, MUTED)
	_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stack.add_child(_status_label)
	stack.add_child(_detail_label)

	var legend_panel := PanelContainer.new()
	legend_panel.theme_type_variation = "PKPaperCard"
	legend_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	legend_panel.offset_left = 28
	legend_panel.offset_top = -84
	legend_panel.offset_right = 720
	legend_panel.offset_bottom = -24
	root_control.add_child(legend_panel)
	var legend_margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		legend_margin.add_theme_constant_override("margin_" + side, 9)
	legend_panel.add_child(legend_margin)
	var legend := _make_label(
		"1 步兵（1）  2 骑乘（2）  3 炮兵（3）  4 装甲（4）  5 混编（5）  6 纸片 fallback\n"
		+ "所有动作严格 8 帧；图中为合成只读军情，真实地形 / 相机 / 生产 MultiMesh。",
		11,
		MUTED,
	)
	legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	legend_margin.add_child(legend)
	queue_redraw_all()


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", SANS)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _set_status(action_id: int, lod: int, zoom: float, note: String = "") -> void:
	if _status_label == null:
		return
	_status_label.text = "动作 %s · LOD %s · camera zoom %.2f" % [
		ACTION_NAMES[action_id], LOD_NAMES[lod], zoom,
	]
	_detail_label.text = note


func _capture_lod(label: String, lod: int, zoom: float) -> void:
	_apply_view(zoom)
	_token_layer.set_lod_override_for_tests(lod)
	_token_layer.set_zoom_override_for_tests(zoom)
	_revision += 1
	_push_snapshot()
	var notes := [
		"聚合档是测试夹具强制模式；正式相机在默认地图 fit 后通常不会降到该阈值。",
		"每支部队一个代表 sprite；缺少图集的第六条仍回退纸片。",
		"1–5 成员编队 + 纸片 fallback；朝向由真实 MilitaryCore 口径的 heading_q16 驱动。",
	]
	_set_status(0, lod, zoom, notes[lod])
	await _wait_render()
	await _capture(label)


func _capture_action(label: String, action_id: int, lod: int, zoom: float) -> void:
	_apply_view(zoom)
	_token_layer.set_lod_override_for_tests(lod)
	_token_layer.set_zoom_override_for_tests(zoom)
	if action_id == 1:
		_expect(_move_from >= 0, "movement fixture has a real previous cell")
	_revision += 1
	if action_id == 2:
		_attack_seq[3] += 1
	elif action_id == 3:
		_hit_seq[4] += 1
	_push_snapshot(true if action_id == 1 else false)
	_set_status(action_id, lod, zoom,
		"攻击目标：4 成员装甲；受击目标：5 成员混编。效果与阴影均保持在地图平面。")
	await _wait_render(action_id)
	await _capture(label)


func _capture_action_focus(label: String, action_id: int,
		focus_row: int, zoom: float) -> void:
	_expect(focus_row >= 0 and focus_row < _cells.size(),
		"action close-up focus row is valid")
	if focus_row < 0 or focus_row >= _cells.size():
		return
	_apply_focus_view(_cell_world(_cells[focus_row]), zoom)
	_token_layer.set_lod_override_for_tests(2)
	_token_layer.set_zoom_override_for_tests(zoom)
	_revision += 1
	if action_id == 2:
		_attack_seq[3] += 1
	elif action_id == 3:
		_hit_seq[4] += 1
	_push_snapshot(action_id == 1)
	_set_status(action_id, 2, zoom,
		"近景仍使用正式地图、地图相机和生产 MultiMesh；目标成员位于真实陆地格。")
	await _wait_render(action_id)
	await _capture(label)


func _capture_map_action_sequence(label: String, action_id: int,
		focus_row: int, zoom: float) -> void:
	_expect(focus_row >= 0 and focus_row < _cells.size(),
		"action sequence focus row is valid")
	if focus_row < 0 or focus_row >= _cells.size():
		return
	_apply_focus_view(_cell_world(_cells[focus_row]), zoom)
	_token_layer.set_lod_override_for_tests(2)
	_token_layer.set_zoom_override_for_tests(zoom)
	_revision += 1
	_push_snapshot(false)

	# Freeze the production layer clock so each captured image is an exact
	# atlas frame rather than a screenshot sampled from wall-clock time.
	_token_layer.set_process(false)
	var sequence_root := "%s/sequences/%s" % [
		ProjectSettings.globalize_path(_capture_dir), label,
	]
	DirAccess.make_dir_recursive_absolute(sequence_root)
	var frames: Array[Image] = []
	for frame_index in 8:
		_apply_token_action_frame(focus_row, action_id, frame_index)
		await process_frame
		await RenderingServer.frame_post_draw
		var screenshot := root.get_texture().get_image()
		if screenshot == null or screenshot.is_empty():
			_expect(false, "sequence screenshot %s frame %d" % [label, frame_index])
			continue
		var crop_rect := _sequence_crop_rect(focus_row, screenshot.get_size())
		var crop := screenshot.get_region(crop_rect)
		var frame_path := "%s/frame_%02d.png" % [sequence_root, frame_index]
		if crop.save_png(frame_path) != OK:
			_expect(false, "sequence frame save %s/%d" % [label, frame_index])
		frames.append(crop)
	_token_layer.set_process(true)
	_expect(frames.size() == 8, "map action sequence has eight frames: %s" % label)
	if frames.size() == 8:
		var sheet_path := "%s/%s.png" % [
			ProjectSettings.globalize_path(_capture_dir), label,
		]
		_save_sequence_contact_sheet(frames, sheet_path)
		print("[military-formation-map] %s" % sheet_path)


func _sequence_crop_rect(focus_row: int, viewport_size: Vector2i) -> Rect2i:
	var world_pos := Vector2(
		_token_layer._ax[focus_row],
		_token_layer._ay[focus_row],
	)
	var screen_pos := _camera.safe_world_to_screen(world_pos)
	var crop_size := Vector2i(
		mini(SEQUENCE_CROP_SIZE, viewport_size.x),
		mini(SEQUENCE_CROP_SIZE, viewport_size.y),
	)
	var crop_pos := Vector2i(
		roundi(screen_pos.x) - int(crop_size.x * 0.5),
		roundi(screen_pos.y) - int(crop_size.y * 0.5),
	)
	crop_pos.x = clampi(crop_pos.x, 0, viewport_size.x - crop_size.x)
	crop_pos.y = clampi(crop_pos.y, 0, viewport_size.y - crop_size.y)
	var crop := Rect2i(crop_pos, crop_size)
	var local_screen := Vector2i(roundi(screen_pos.x), roundi(screen_pos.y))
	_expect(crop.has_point(local_screen),
		"sequence crop centers the target formation row %d" % focus_row)
	return crop


func _apply_token_action_frame(row: int, action_id: int,
		frame_index: int) -> void:
	var frame_time := float(frame_index) / 8.0 + 0.001
	_token_layer._wall_time = frame_time
	for army_row in ARMY_COUNT:
		_token_layer._attack_started[army_row] = -1.0
		_token_layer._hit_started[army_row] = -1.0
		_token_layer._t0[army_row] = -100.0
	match action_id:
		1:
			_token_layer._t0[row] = 0.0
		2:
			_token_layer._attack_started[row] = 0.0
		3:
			_token_layer._hit_started[row] = 0.0
	_token_layer._formation_material.set_shader_parameter(
		"visual_seconds", frame_time)
	_token_layer._update_row_formation_custom(row)


func _save_sequence_contact_sheet(frames: Array[Image],
		path: String) -> void:
	var tile := 300
	var gap := 8
	var sheet := Image.create(tile * 4 + gap * 3, tile * 2 + gap,
		false, Image.FORMAT_RGBA8)
	sheet.fill(Color("171d21"))
	for frame_index in frames.size():
		var frame := frames[frame_index]
		frame.resize(tile, tile, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(
			frame,
			Rect2i(0, 0, tile, tile),
			Vector2i(
				(frame_index % 4) * (tile + gap),
				int(frame_index / 4) * (tile + gap),
			),
		)
	if sheet.save_png(path) != OK:
		_expect(false, "sequence contact sheet save %s" % path)


func _wait_render(action_id: int = 0) -> void:
	for _index in 4:
		await process_frame
	await create_timer(0.16 if action_id == 0 else 0.28).timeout


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [ProjectSettings.globalize_path(_capture_dir), label]
	if image == null or image.is_empty() or image.save_png(path) != OK:
		_expect(false, "capture %s" % label)
		return
	print("[military-formation-map] %s" % path)


func _apply_view(zoom: float) -> void:
	var metrics := _cluster_metrics()
	_apply_focus_view(metrics.focus, zoom)


func _apply_focus_view(focus: Vector2, zoom: float) -> void:
	_camera.set("_fit_floor_zoom", 0.25)
	_camera.restore_view_state(focus, zoom)
	_camera.force_update_scroll()


func _cluster_metrics() -> Dictionary:
	var positions: Array[Vector2] = []
	for cell in _cells:
		var obj = _map.cell_at(cell)
		positions.append(HexUtils.cube_to_world(obj.q, obj.r, _host.hex_size))
	var focus := Vector2.ZERO
	if positions.is_empty():
		return {"focus": focus, "zoom": 0.8, "close_zoom": 1.8}
	for point in positions:
		focus += point
	focus /= float(positions.size())
	var min_pos := positions[0]
	var max_pos := positions[0]
	for point in positions:
		min_pos = Vector2(minf(min_pos.x, point.x), minf(min_pos.y, point.y))
		max_pos = Vector2(maxf(max_pos.x, point.x), maxf(max_pos.y, point.y))
	var span := max_pos - min_pos
	var viewport := get_root().get_visible_rect().size
	var overview_zoom := clampf(minf(
		(viewport.x - 960.0) / maxf(span.x + 180.0, 1.0),
		(viewport.y - 300.0) / maxf(span.y + 160.0, 1.0),
	), 0.55, 1.25)
	# At 1600x900 the six fixture cells fit together at 3x while still clearing
	# the formal top bar and the evidence cards.
	var close_zoom := 3.0
	return {"focus": focus, "zoom": overview_zoom, "close_zoom": close_zoom}


func _choose_demo_cells(start_cell: int) -> PackedInt32Array:
	var neighbors := _map.neighbor_indices_packed()
	var candidates := PackedInt32Array()
	var seen := {start_cell: true}
	var frontier: Array[int] = [start_cell]
	for _depth in 7:
		var next: Array[int] = []
		for cell_id in frontier:
			if _is_land(cell_id):
				candidates.append(cell_id)
			for direction in 6:
				var neighbor := int(neighbors[cell_id * 6 + direction])
				if neighbor < 0 or seen.has(neighbor):
					continue
				seen[neighbor] = true
				next.append(neighbor)
		frontier = next
		if frontier.is_empty():
			break
	var chosen := PackedInt32Array()
	for separation in [2.45, 2.0, 1.55]:
		chosen.clear()
		var min_distance := _host.hex_size * float(separation)
		for cell_id in candidates:
			if chosen.has(cell_id):
				continue
			var point := _cell_world(cell_id)
			var separated := true
			for picked in chosen:
				if point.distance_to(_cell_world(picked)) < min_distance:
					separated = false
					break
			if separated:
				chosen.append(cell_id)
			if chosen.size() == ARMY_COUNT:
				break
		if chosen.size() == ARMY_COUNT:
			break
	if chosen.size() < ARMY_COUNT:
		for cell_id in _map.cell_count():
			if chosen.has(cell_id) or not _is_land(cell_id):
				continue
			chosen.append(cell_id)
			if chosen.size() == ARMY_COUNT:
				break
	var ordered: Array[int] = []
	for cell_id in chosen:
		ordered.append(cell_id)
	var home_world := _cell_world(_home_cell)
	ordered.sort_custom(func(a: int, b: int) -> bool:
		var da := _cell_world(a).distance_squared_to(home_world)
		var db := _cell_world(b).distance_squared_to(home_world)
		if is_equal_approx(da, db):
			var pa := _cell_world(a)
			var pb := _cell_world(b)
			if is_equal_approx(pa.x, pb.x):
				return pa.y < pb.y
			return pa.x < pb.x
		return da < db
	)
	var result := PackedInt32Array()
	for cell_id in ordered:
		result.append(cell_id)
	return result


func _is_land(cell_id: int) -> bool:
	if cell_id < 0 or cell_id >= _map.cell_count():
		return false
	if _map.is_water_arr.size() > cell_id and int(_map.is_water_arr[cell_id]) != 0:
		return false
	var cell = _map.cell_at(cell_id)
	return cell != null and bool(cell.passable_land)


func _first_land_neighbor(cell_id: int) -> int:
	var neighbors := _map.neighbor_indices_packed()
	for direction in 6:
		var neighbor := int(neighbors[cell_id * 6 + direction])
		if _is_land(neighbor):
			return neighbor
	return -1


func _cell_world(cell_id: int) -> Vector2:
	var cell = _map.cell_at(cell_id)
	if cell == null:
		return Vector2.ZERO
	return HexUtils.cube_to_world(cell.q, cell.r, _host.hex_size)


func _push_snapshot(movement: bool = false) -> void:
	var snapshot := _make_snapshot(movement)
	_feed.set_snapshot(snapshot)
	_layers._poll()
	_layers.token_layer.set_lod_override_for_tests(
		int(_layers.token_layer._lod_override))


func _make_snapshot(movement: bool = false) -> Dictionary:
	var units := PackedInt32Array()
	var weights := PackedInt64Array()
	var offsets := PackedInt32Array()
	offsets.resize(ARMY_COUNT + 1)
	offsets[0] = 0
	for row in ARMY_COUNT:
		var composition := COMPOSITIONS[row] as Array
		for entry_value in composition:
			var entry := entry_value as Array
			units.append(_unit_index(String(entry[0])))
			weights.append(int(entry[1]))
		offsets[row + 1] = units.size()
	var prev_cells: PackedInt32Array = _cells.duplicate()
	var cells: PackedInt32Array = _cells.duplicate()
	if movement and _move_from >= 0:
		# Animate west out of the idle formation row. The next idle snapshot
		# snaps back to the canonical fixture cell.
		prev_cells[2] = _cells[2]
		cells[2] = _move_from
	var owner_slots := PackedInt32Array()
	owner_slots.resize(ARMY_COUNT)
	owner_slots.fill(maxi(0, _player_slot))
	return {
		"ok": true,
		"available": true,
		"revision": _revision,
		"selected_army": 0,
		"armies": {
			"handle": PackedInt64Array([101, 102, 103, 104, 105, 106]),
			"owner_slot": owner_slots,
			"cell": cells,
			"prev_cell": prev_cells,
			"moved_day": PackedInt32Array([0, 0, 0, 0, 0, 0]),
			"unit_class": PackedByteArray(UNIT_CLASSES),
			"headcount": PackedInt64Array(HEADCOUNTS),
			"flags": PackedInt32Array([0, 0, 0, 0, 0, 0]),
			"composition_offsets": offsets,
			"composition_unit": units,
			"composition_weight": weights,
			"heading_q16": PackedInt32Array(HEADINGS_Q16),
			"attack_seq": _attack_seq,
			"hit_seq": _hit_seq,
		},
		"engagements": {},
		"convoys": {},
		"controller_cells": PackedInt32Array(),
		"controller_slots": PackedInt32Array(),
		"front_edges": PackedInt32Array(),
		"front_progress": PackedByteArray(),
	}


func _build_dense_catalog() -> void:
	if not FileAccess.file_exists(MILITARY_CATALOG_PATH):
		_expect(false, "military catalog exists")
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(MILITARY_CATALOG_PATH))
	if not (parsed is Dictionary):
		_expect(false, "military catalog parses")
		return
	var ids: Array[String] = []
	for row_value in (parsed as Dictionary).get("units", []) as Array:
		ids.append(String((row_value as Dictionary).get("id", "")))
	ids.sort()
	_dense_ids = PackedStringArray(ids)
	for index in ids.size():
		_dense_units.append({"index": index, "id": ids[index]})


func _unit_index(unit_id: String) -> int:
	var index := _dense_ids.find(unit_id)
	_expect(index >= 0, "dense unit %s exists" % unit_id)
	return maxi(0, index)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error("[military-formation-map] " + message)


func _finish(code: int) -> void:
	print("[military-formation-map] failures=%d output=%s" % [
		_failures.size(), ProjectSettings.globalize_path(_capture_dir),
	])
	for failure in _failures:
		push_error(failure)
	if _game != null:
		_game.queue_free()
	await process_frame
	quit(code)


func queue_redraw_all() -> void:
	for node in root.get_children():
		if node is CanvasItem:
			(node as CanvasItem).queue_redraw()
