extends Node2D

## Standalone M2 production-backend harness.
##
## This scene drives the real MilitaryArmyTokenLayer directly. It injects a
## synthetic MilitaryRenderFeed and the real sorted dense unit catalog, so the
## paper fallback, three LODs, member layouts and cue state machine can be
## inspected without mounting MilitaryMapLayers or changing MilitaryCore.

const TOKEN_SCRIPT = preload("res://scripts/rendering/military_army_token_layer.gd")
const FEED_SCRIPT = preload("res://scripts/rendering/military_render_feed.gd")
const THEME: Theme = preload("res://assets/themes/player_session_theme.tres")
const DISPLAY_FONT: Font = preload("res://assets/fonts/muyao/display_handwritten.tres")
const SANS_BOLD: Font = preload("res://assets/fonts/swei/SweiGothicLegCJKsc-Bold.ttf")
const SANS: Font = preload("res://assets/fonts/swei/SweiGothicLegCJKsc-Regular.ttf")

const MILITARY_CATALOG_PATH := "res://data/military/military_catalog.json"
const CAPTURE_DIR := "res://tmp/military_formation_token_harness"
const ARMY_COUNT := 6
const CUE_TARGET := 3
const HEX_SIZE := 40.0
const ZOOM_BY_LOD := [0.2, 0.5, 1.0]
const ACTION_NAMES := ["待命", "行军", "攻击", "受击"]
const LOD_NAMES := ["聚合", "代表", "编队"]
const LOD_IDS := ["aggregate", "representative", "formation"]

# Five unique cells cover the member-count bands; the final cell is the old
# snapshot / paper-fallback case.
const DEMO_CELL_IDS := [10, 11, 12, 13, 14, 15]
const DEMO_HEADINGS_Q16 := [0, 8192, 16384, 24576, 32768, 0]
const DEMO_HEADCOUNTS := [120, 600, 1800, 4200, 9600, 900]
const DEMO_OWNER_SLOTS := [0, 0, 0, 0, 0, 1]
const DEMO_UNIT_CLASSES := [0, 1, 2, 1, 0, 0]
const DEMO_LABELS = [
	"步兵 / 1 成员",
	"骑乘 / 2 成员",
	"炮兵 / 3 成员",
	"装甲 / 4 成员",
	"混编 / 5 成员",
	"纸片 fallback",
]

const INK := Color("2b2118")
const MUTED := Color("6b5742")
const RED := Color("9b3324")
const BRASS := Color("a97823")
const PARCHMENT_TOP := Color("d8c9aa")
const PARCHMENT_BOTTOM := Color("f1e8d2")
const FIELD_LINE := Color("9c8465")


class FakeCell:
	var q: int
	var r: int

	func _init(q_value: int, r_value: int) -> void:
		q = q_value
		r = r_value


class FakeMap:
	var cells: Dictionary = {}
	var visible_arr: PackedByteArray = PackedByteArray()
	var country_slot_arr: PackedInt32Array = PackedInt32Array()

	func _init() -> void:
		cells[10] = FakeCell.new(3, 5)
		cells[11] = FakeCell.new(7, 5)
		cells[12] = FakeCell.new(11, 5)
		cells[13] = FakeCell.new(4, 8)
		cells[14] = FakeCell.new(8, 8)
		cells[15] = FakeCell.new(12, 8)
		visible_arr.resize(32)
		visible_arr.fill(0)
		country_slot_arr.resize(32)
		country_slot_arr.fill(0)

	func cell_at(cell: int):
		return cells.get(cell)


var _layer
var _map: FakeMap
var _camera: Camera2D
var _feed
var _dense_units: Array = []
var _dense_ids: PackedStringArray = PackedStringArray()
var _attack_seq: PackedInt32Array = PackedInt32Array()
var _hit_seq: PackedInt32Array = PackedInt32Array()
var _revision := 1
var _heading_offset_q16 := 0
var _lod_index := 2
var _capture_running := false
var _debug_update_accum := 0.0
var _last_cue_text := "无"

var _status_label: Label
var _debug_label: Label
var _cue_label: Label
var _heading_label: Label
var _lod_buttons: Array[Button] = []


func _ready() -> void:
	_attack_seq.resize(ARMY_COUNT)
	_attack_seq.fill(0)
	_hit_seq.resize(ARMY_COUNT)
	_hit_seq.fill(0)
	_load_dense_units()

	_map = FakeMap.new()
	_camera = Camera2D.new()
	_camera.name = "ReferenceCamera"
	_camera.enabled = false
	add_child(_camera)

	_layer = TOKEN_SCRIPT.new()
	_layer.name = "ProductionArmyTokenLayer"
	add_child(_layer)
	_layer.configure(_map, _camera, HEX_SIZE, 0.0)
	_layer.set_player_slot(0)
	var catalog_report: Dictionary = _layer.configure_formation_catalog(_dense_units)
	if not bool(catalog_report.get("ok", false)):
		push_error("M2 harness failed to bind dense units: %s" % str(catalog_report))

	_layer.set_lod_override_for_tests(_lod_index)
	_layer.set_zoom_override_for_tests(ZOOM_BY_LOD[_lod_index])
	_layer.set_visual_day(1.0)
	_push_feed()

	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_build_ui()
	_refresh_controls()
	_refresh_debug()
	queue_redraw()
	call_deferred("_maybe_run_capture")


func _load_dense_units() -> void:
	if not FileAccess.file_exists(MILITARY_CATALOG_PATH):
		push_error("Missing military catalog: %s" % MILITARY_CATALOG_PATH)
		return
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(MILITARY_CATALOG_PATH))
	if not (parsed is Dictionary):
		push_error("Invalid military catalog JSON")
		return
	var rows: Array = (parsed as Dictionary).get("units", []) as Array
	var ids: Array[String] = []
	for row_value in rows:
		var row := row_value as Dictionary
		ids.append(String(row.get("id", "")))
	ids.sort()
	_dense_ids = PackedStringArray(ids)
	for index in ids.size():
		_dense_units.append({"index": index, "id": ids[index]})
	if _dense_units.size() != 24:
		push_error("Expected 24 dense military units, got %d" % _dense_units.size())


func _unit_index(unit_id: String) -> int:
	for index in _dense_ids.size():
		if _dense_ids[index] == unit_id:
			return index
	push_error("Unknown dense military unit id: %s" % unit_id)
	return 0


func _composition_specs() -> Array:
	return [
		[["bronze_spearmen", 100]],
		[["cavalry", 70], ["heavy_cavalry", 30]],
		[["field_artillery", 60], ["heavy_artillery", 25], ["siege_train", 15]],
		[["tank_corps", 55], ["early_armor", 30], ["drone_swarm", 15]],
		[["bronze_spearmen", 50], ["field_artillery", 30], ["tank_corps", 20]],
		[],
	]


func _make_snapshot() -> Dictionary:
	var units := PackedInt32Array()
	var weights := PackedInt64Array()
	var offsets := PackedInt32Array()
	offsets.resize(ARMY_COUNT + 1)
	offsets[0] = 0
	var specs: Array = _composition_specs()
	for row in ARMY_COUNT:
		var composition: Array = specs[row] as Array
		for entry_value in composition:
			var entry := entry_value as Array
			units.append(_unit_index(String(entry[0])))
			weights.append(int(entry[1]))
		offsets[row + 1] = units.size()

	var headings := PackedInt32Array()
	headings.resize(ARMY_COUNT)
	for row in ARMY_COUNT:
		headings[row] = posmod(int(DEMO_HEADINGS_Q16[row]) + _heading_offset_q16, 65536)

	var attack := PackedInt32Array()
	attack.resize(ARMY_COUNT)
	var hit := PackedInt32Array()
	hit.resize(ARMY_COUNT)
	for row in ARMY_COUNT:
		attack[row] = int(_attack_seq[row])
		hit[row] = int(_hit_seq[row])

	return {
		"revision": _revision,
		"selected_army": 101,
		"armies": {
			"handle": PackedInt64Array([101, 102, 103, 104, 105, 106]),
			"owner_slot": PackedInt32Array(DEMO_OWNER_SLOTS),
			"cell": PackedInt32Array(DEMO_CELL_IDS),
			"prev_cell": PackedInt32Array(DEMO_CELL_IDS),
			"moved_day": PackedInt32Array([0, 0, 0, 0, 0, 0]),
			"unit_class": PackedByteArray(DEMO_UNIT_CLASSES),
			"headcount": PackedInt64Array(DEMO_HEADCOUNTS),
			"flags": PackedInt32Array([0, 0, 0, 0, 0, 0]),
			"composition_offsets": offsets,
			"composition_unit": units,
			"composition_weight": weights,
			"heading_q16": headings,
			"attack_seq": attack,
			"hit_seq": hit,
		},
	}


func _push_feed() -> void:
	if _layer == null:
		return
	var feed = FEED_SCRIPT.new()
	feed.player_slot = 0
	feed.apply_synthetic(_make_snapshot(), -1)
	# The harness is a visual test bench, so every row is visible. The final
	# row still exercises the paper fallback caused by missing composition CSR.
	feed.apply_fog(_map, false)
	_layer.set_armies(feed)
	_feed = feed
	_refresh_debug()


func _set_lod(index: int) -> void:
	_lod_index = clampi(index, 0, 2)
	if _layer != null:
		_layer.set_lod_override_for_tests(_lod_index)
		_layer.set_zoom_override_for_tests(float(ZOOM_BY_LOD[_lod_index]))
	_refresh_controls()
	_refresh_debug()


func _step_heading(delta_degrees: float) -> void:
	var delta_q16 := int(round(delta_degrees * 65536.0 / 360.0))
	_heading_offset_q16 = posmod(_heading_offset_q16 + delta_q16, 65536)
	_revision += 1
	_push_feed()
	_refresh_controls()


func _trigger_cue(action_id: String) -> void:
	if action_id == "attack":
		_attack_seq[CUE_TARGET] += 1
		_last_cue_text = "攻击 / 4 成员装甲"
	elif action_id == "hit":
		_hit_seq[CUE_TARGET] += 1
		_last_cue_text = "受击 / 4 成员装甲"
	_revision += 1
	_push_feed()
	_refresh_controls()


func _reset_demo() -> void:
	_heading_offset_q16 = 0
	_attack_seq.fill(0)
	_hit_seq.fill(0)
	_last_cue_text = "无"
	_revision += 1
	_set_lod(2)
	_push_feed()
	_refresh_controls()


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HarnessUI"
	canvas.layer = 4
	add_child(canvas)

	var ui_root := Control.new()
	ui_root.name = "UIRoot"
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.theme = THEME
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(ui_root)

	var header_margin := MarginContainer.new()
	header_margin.name = "Header"
	header_margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	header_margin.offset_left = 34
	header_margin.offset_top = 20
	header_margin.offset_right = -34
	header_margin.offset_bottom = 168
	header_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(header_margin)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 24)
	header_margin.add_child(header)

	var title_block := VBoxContainer.new()
	title_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_block.add_theme_constant_override("separation", 1)
	header.add_child(title_block)

	var kicker := _make_label("军事地图表现 / M2 PRODUCTION BACKEND", 12, RED)
	kicker.add_theme_font_override("font", SANS_BOLD)
	title_block.add_child(kicker)

	var title := _make_label("部队编队生产接入演示", 36, INK)
	title.add_theme_font_override("font", DISPLAY_FONT)
	title_block.add_child(title)

	var subtitle := _make_label(
		"真实 MilitaryArmyTokenLayer · 24 兵种 dense mapping · 1–5 成员编队",
		15,
		MUTED
	)
	title_block.add_child(subtitle)

	var note := _make_label(
		"只读快照驱动；纸片 fallback 保留。本演示不挂 MilitaryMapLayers，不改生产逻辑。",
		12,
		Color(MUTED, 0.84)
	)
	title_block.add_child(note)

	var control_panel := PanelContainer.new()
	control_panel.theme_type_variation = "PKPaperCard"
	control_panel.custom_minimum_size = Vector2(770, 0)
	header.add_child(control_panel)
	var control_margin := MarginContainer.new()
	control_margin.add_theme_constant_override("margin_left", 12)
	control_margin.add_theme_constant_override("margin_top", 8)
	control_margin.add_theme_constant_override("margin_right", 12)
	control_margin.add_theme_constant_override("margin_bottom", 8)
	control_panel.add_child(control_margin)

	var controls := VBoxContainer.new()
	controls.add_theme_constant_override("separation", 5)
	control_margin.add_child(controls)

	var lod_group := ButtonGroup.new()
	var lod_row := _make_control_row(controls, "LOD")
	for index in 3:
		var lod_button := _make_toggle_button(
			"%d  %s" % [index + 1, LOD_NAMES[index]], lod_group)
		lod_button.pressed.connect(_on_lod_button.bind(index))
		lod_row.add_child(lod_button)
		_lod_buttons.append(lod_button)

	var cue_row := _make_control_row(controls, "CUE")
	var attack_button := _make_button("攻击  A")
	attack_button.pressed.connect(_on_attack_button)
	cue_row.add_child(attack_button)
	var hit_button := _make_button("受击  H")
	hit_button.pressed.connect(_on_hit_button)
	cue_row.add_child(hit_button)
	_cue_label = _make_label("目标：4 成员装甲", 12, MUTED)
	_cue_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cue_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cue_row.add_child(_cue_label)

	var heading_row := _make_control_row(controls, "朝向")
	var ccw_button := _make_button("逆时针  15°  [")
	ccw_button.pressed.connect(_on_heading_button.bind(-15.0))
	heading_row.add_child(ccw_button)
	var cw_button := _make_button("顺时针  15°  ]")
	cw_button.pressed.connect(_on_heading_button.bind(15.0))
	heading_row.add_child(cw_button)
	var reset_button := _make_button("重置  R")
	reset_button.pressed.connect(_on_reset_button)
	heading_row.add_child(reset_button)
	_heading_label = _make_label("", 12, MUTED)
	_heading_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_heading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	heading_row.add_child(_heading_label)

	_status_label = _make_label("", 12, Color(INK, 0.84))
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(_status_label)

	_add_notes_panel(ui_root, false)
	_add_notes_panel(ui_root, true)
	_add_debug_panel(ui_root)


func _add_notes_panel(parent: Control, right_side: bool) -> void:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "PKPaperCard"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if right_side:
		panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		panel.offset_left = -278
		panel.offset_right = -34
	else:
		panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
		panel.offset_left = 34
		panel.offset_right = 278
	panel.offset_top = 184
	panel.offset_bottom = 462
	parent.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 5)
	margin.add_child(stack)

	if right_side:
		stack.add_child(_make_label("LOD / 视觉预算", 20, INK))
		stack.add_child(_make_label("聚合  zoom < 0.35", 12, MUTED))
		stack.add_child(_make_label("代表  0.35 – 0.70", 12, MUTED))
		stack.add_child(_make_label("编队  zoom > 0.70", 12, MUTED))
		stack.add_child(_make_label("", 5, MUTED))
		stack.add_child(_make_label("选中部队优先", 12, Color(MUTED, 0.92)))
		stack.add_child(_make_label("单军成员不拆分预算", 12, Color(MUTED, 0.92)))
		stack.add_child(_make_label("缺配比 → 单纸片 fallback", 12, Color(RED, 0.92)))
	else:
		stack.add_child(_make_label("ATLAS / 生图资产", 20, INK))
		stack.add_child(_make_label("military_formation_prototype_v4_1", 11, RED))
		stack.add_child(_make_label("1024 × 2048 · 8 × 16", 12, MUTED))
		stack.add_child(_make_label("4 原型 × 4 动作 × 8 帧", 12, MUTED))
		stack.add_child(_make_label("", 5, MUTED))
		stack.add_child(_make_label("DENSE UNIT MAP", 12, BRASS))
		stack.add_child(_make_label("%d / %d 已映射" % [
			_dense_units.size(), _dense_units.size(),
		], 14, INK))
		stack.add_child(_make_label("纸底、纸片与选中圈仍由生产层绘制", 11, Color(MUTED, 0.9)))


func _add_debug_panel(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.name = "DebugPanel"
	panel.theme_type_variation = "PKPaperCard"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 34
	panel.offset_top = -184
	panel.offset_right = -34
	panel.offset_bottom = -24
	parent.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	margin.add_child(row)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 3)
	row.add_child(left)
	left.add_child(_make_label("LIVE DEBUG / production token layer", 12, RED))
	_debug_label = _make_label("", 12, INK)
	_debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_debug_label.custom_minimum_size = Vector2(940, 0)
	left.add_child(_debug_label)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(260, 0)
	right.add_theme_constant_override("separation", 4)
	row.add_child(right)
	right.add_child(_make_label("操作", 12, BRASS))
	right.add_child(_make_label("1 / 2 / 3  LOD", 11, MUTED))
	right.add_child(_make_label("[ / ]  朝向    A / H  cue", 11, MUTED))
	right.add_child(_make_label("Space 暂停（场景树）  R 重置", 11, MUTED))


func _make_control_row(parent: Control, caption: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var label := _make_label(caption, 11, MUTED)
	label.custom_minimum_size = Vector2(38, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	return row


func _make_toggle_button(text: String, group: ButtonGroup) -> Button:
	var button := _make_button(text)
	button.toggle_mode = true
	button.button_group = group
	return button


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.theme_type_variation = "PKHUDButton"
	button.custom_minimum_size = Vector2(92, 30)
	button.add_theme_font_override("font", SANS_BOLD)
	button.add_theme_font_size_override("font_size", 13)
	return button


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", SANS)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _on_lod_button(index: int) -> void:
	_set_lod(index)


func _on_attack_button() -> void:
	_trigger_cue("attack")


func _on_hit_button() -> void:
	_trigger_cue("hit")


func _on_heading_button(delta_degrees: float) -> void:
	_step_heading(delta_degrees)


func _on_reset_button() -> void:
	_reset_demo()


func _refresh_controls() -> void:
	for index in _lod_buttons.size():
		_lod_buttons[index].set_pressed_no_signal(index == _lod_index)
	if _cue_label != null:
		_cue_label.text = "目标：4 成员装甲 · cue %s" % _last_cue_text
	if _heading_label != null:
		var degrees := _heading_degrees()
		_heading_label.text = "统一偏移 %+.0f° · 焦点 %.0f°" % [
			float(_heading_offset_q16) * 360.0 / 65536.0,
			degrees,
		]
	if _status_label != null:
		_status_label.text = "演示部队 6 · 编队 5 · fallback 1 · LOD %s · zoom %.2f" % [
			LOD_NAMES[_lod_index], float(ZOOM_BY_LOD[_lod_index]),
		]


func _refresh_debug() -> void:
	if _layer == null or _debug_label == null:
		return
	var stats: Dictionary = _layer.debug_snapshot()
	var action := String(_layer.debug_army_action(CUE_TARGET))
	if action.is_empty():
		action = "n/a"
	var heading := _heading_degrees()
	var visible := bool(stats.get("visible_layer", false))
	var line_one := (
		"LOD %s · 实例 %d（编队 %d / 纸片 %d） · 编队部队 %d · fallback %d"
		% [
			String(stats.get("lod", "?")),
			int(stats.get("instances", 0)),
			int(stats.get("formation_instances", 0)),
			int(stats.get("paper_instances", 0)),
			int(stats.get("formation_armies", 0)),
			int(stats.get("paper_fallback", 0)),
		]
	)
	var line_two := (
		"dense %d / %d · 行动 %s · 朝向 %.0f° · 图层%s · uploads %d"
		% [
			int(stats.get("catalog_mapped", 0)),
			int(stats.get("catalog_units", 0)),
			action,
			heading,
			"可见" if visible else "隐藏",
			int(stats.get("uploads", 0)),
		]
	)
	_debug_label.text = "%s\n%s · 最近 cue：%s" % [line_one, line_two, _last_cue_text]


func _heading_degrees() -> float:
	var q16 := posmod(int(DEMO_HEADINGS_Q16[CUE_TARGET]) + _heading_offset_q16, 65536)
	return float(q16) * 360.0 / 65536.0


func _process(delta: float) -> void:
	_debug_update_accum += delta
	if _debug_update_accum >= 0.12:
		_debug_update_accum = 0.0
		_refresh_debug()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1:
			_set_lod(0)
		KEY_2:
			_set_lod(1)
		KEY_3:
			_set_lod(2)
		KEY_A:
			_trigger_cue("attack")
		KEY_H:
			_trigger_cue("hit")
		KEY_BRACKETLEFT:
			_step_heading(-15.0)
		KEY_BRACKETRIGHT:
			_step_heading(15.0)
		KEY_R:
			_reset_demo()
		_:
			return
	get_viewport().set_input_as_handled()


func _on_viewport_size_changed() -> void:
	queue_redraw()


func _draw() -> void:
	var size := get_viewport_rect().size
	if size.x < 2.0 or size.y < 2.0:
		return

	var bands := 32
	for index in bands:
		var t := float(index) / float(bands - 1)
		var color := PARCHMENT_TOP.lerp(PARCHMENT_BOTTOM, t)
		draw_rect(Rect2(0.0, size.y * t, size.x, size.y / float(bands) + 2.0), color)

	# Paper folds and a quiet survey grid.
	for x_fraction in [0.27, 0.63]:
		var fold := PackedVector2Array()
		for step in 22:
			var y := size.y * float(step) / 21.0
			var wave := sin(float(step) * 1.33 + x_fraction * 17.0) * 3.0
			fold.append(Vector2(size.x * x_fraction + wave, y))
		draw_polyline(fold, Color(0.31, 0.24, 0.17, 0.075), 1.0, true)

	for x in range(32, int(size.x), 64):
		draw_line(Vector2(x, 176), Vector2(x, size.y - 192),
			Color(FIELD_LINE, 0.07), 1.0)
	for y in range(176, int(size.y) - 192, 48):
		draw_line(Vector2(32, y), Vector2(size.x - 32, y),
			Color(FIELD_LINE, 0.055), 1.0)

	draw_rect(Rect2(32, 176, size.x - 64, maxf(1.0, size.y - 368)),
		Color(INK, 0.035), false, 1.0)
	draw_rect(Rect2(0, 0, size.x, 7), Color(INK, 0.92))
	draw_rect(Rect2(0, 7, size.x, 2), Color(RED, 0.72))

	# Survey marks around the visualization field.
	for cell_id in DEMO_CELL_IDS:
		var cell := _map.cell_at(cell_id) as FakeCell
		var center := HexUtils.cube_to_world(cell.q, cell.r, HEX_SIZE)
		_draw_hex(center, 50.0)
		var label := String(DEMO_LABELS[DEMO_CELL_IDS.find(cell_id)])
		draw_string(SANS_BOLD, center + Vector2(-96, 66), label,
			HORIZONTAL_ALIGNMENT_CENTER, 168, 12, Color(INK, 0.82))
		draw_circle(center, 2.0, Color(RED, 0.58), true, -1.0, true)

	var compass := Vector2(size.x - 124.0, 104.0)
	draw_arc(compass, 64.0, 0.0, TAU, 64, Color(INK, 0.10), 1.0, true)
	draw_arc(compass, 48.0, 0.0, TAU, 64, Color(RED, 0.16), 1.0, true)
	draw_line(compass + Vector2(-70, 0), compass + Vector2(70, 0),
		Color(INK, 0.10), 1.0)
	draw_line(compass + Vector2(0, -70), compass + Vector2(0, 70),
		Color(INK, 0.10), 1.0)
	draw_string(SANS_BOLD, compass + Vector2(-7, -74), "N",
		HORIZONTAL_ALIGNMENT_LEFT, 20, 11, Color(RED, 0.68))

	draw_string(SANS, Vector2(48, size.y - 22),
		"FIELD STUDY · PRODUCTION TOKEN BACKEND · READ-ONLY SNAPSHOT",
		HORIZONTAL_ALIGNMENT_LEFT, size.x - 96, 10, Color(MUTED, 0.72))


func _draw_hex(center: Vector2, radius: float) -> void:
	var points := PackedVector2Array()
	for side in 6:
		var angle := PI / 6.0 + TAU * float(side) / 6.0
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	draw_colored_polygon(points, Color(BRASS, 0.035))
	points.append(points[0])
	draw_polyline(points, Color(FIELD_LINE, 0.18), 1.0, true)


func _maybe_run_capture() -> void:
	if _capture_running:
		return
	for argument in OS.get_cmdline_user_args():
		if String(argument) == "--capture":
			_capture_running = true
			await _run_capture_sequence()
			return


func _run_capture_sequence() -> void:
	var output_dir := ProjectSettings.globalize_path(CAPTURE_DIR)
	DirAccess.make_dir_recursive_absolute(output_dir)
	await get_tree().create_timer(0.45).timeout

	_set_lod(2)
	await get_tree().create_timer(0.20).timeout
	await _capture("01_formation")

	_set_lod(1)
	await get_tree().create_timer(0.20).timeout
	await _capture("02_representative")

	_set_lod(0)
	await get_tree().create_timer(0.20).timeout
	await _capture("03_aggregate")

	_set_lod(2)
	await get_tree().create_timer(0.12).timeout
	_trigger_cue("attack")
	await get_tree().create_timer(0.26).timeout
	await _capture("04_attack")

	_trigger_cue("hit")
	await get_tree().create_timer(0.20).timeout
	await _capture("05_hit")
	get_tree().quit(0)


func _capture(label: String) -> void:
	for _index in 4:
		await get_tree().process_frame
	await get_tree().create_timer(0.08).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [
		ProjectSettings.globalize_path(CAPTURE_DIR), label,
	]
	if image == null or image.is_empty() or image.save_png(path) != OK:
		push_error("M2 harness capture failed: %s" % path)
		return
	print("[military-formation-token] %s" % path)
