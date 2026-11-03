extends Node2D
class_name MilitaryFormationPreviewLayer

## Prototype-only formation map renderer. This node is not registered in
## MilitaryMapLayers and never writes military simulation state.

signal action_changed(action_id: String)
signal lod_changed(lod_index: int)
signal paused_changed(is_paused: bool)
signal reduced_motion_changed(enabled: bool)
signal heading_changed(degrees: float)

const CATALOG_PATH := "res://data/military/military_visual_catalog.json"
const ATLAS: Texture2D = preload(
	"res://assets/military/formations/prototype/military_formation_prototype_v4.png")
const SHADER: Shader = preload("res://shaders/military_formation_sprite.gdshader")
const DISPLAY_FONT: Font = preload("res://assets/fonts/muyao/display_handwritten.tres")
const SANS_FONT: Font = preload(
	"res://assets/fonts/swei/SweiGothicLegCJKsc-Regular.ttf")
const INSTANCE_CAP := 128
const ONE_SHOT_MEMBER_STAGGER_SECONDS := 0.025
const PAPER := Color("eee3c9")
const PAPER_LIGHT := Color("f6efd9")
const INK := Color("2b2118")
const INK_MUTED := Color("66513d")
const LINE := Color("9c8465")
const SEAL := Color("9b3324")
const PROTOTYPE_COLORS := [
	Color("2f6b61"),
	Color("9a4828"),
	Color("a97823"),
	Color("475157"),
]

var _catalog: Dictionary = {}
var _actions: Array = []
var _lods: Array = []
var _headcount_bands: Array = []
var _prototypes: Array = []

var _batch: MultiMeshInstance2D
var _material: ShaderMaterial
var _card_styles: Array[StyleBoxFlat] = []
var _content_rect := Rect2(32, 195, 1536, 630)
var _visual_seconds := 0.0
var _action_started := 0.0
var _action_index := 0
var _lod_index := 2
var _heading_degrees := 0.0
var _paused := false
var _reduced_motion_override := -1
var _visible_instances := 0


func _ready() -> void:
	z_index = 1
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_load_catalog()
	_build_card_styles()
	_ensure_batch()
	var viewport := get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(_on_viewport_size_changed):
		viewport.size_changed.connect(_on_viewport_size_changed)
	set_process(true)
	_layout_for_viewport()


func _load_catalog() -> void:
	if not FileAccess.file_exists(CATALOG_PATH):
		push_error("MilitaryFormationPreviewLayer: missing %s" % CATALOG_PATH)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if not (parsed is Dictionary):
		push_error("MilitaryFormationPreviewLayer: invalid visual catalog")
		return
	_catalog = parsed as Dictionary
	_actions = _catalog.get("actions", []) as Array
	_lods = _catalog.get("lod", []) as Array
	_headcount_bands = _catalog.get("headcount_bands", []) as Array
	_prototypes = _catalog.get("prototypes", []) as Array


func _build_card_styles() -> void:
	_card_styles.clear()
	for index in PROTOTYPE_COLORS.size():
		var accent: Color = PROTOTYPE_COLORS[index]
		var style := StyleBoxFlat.new()
		style.bg_color = Color(PAPER, 0.88)
		style.border_color = Color(accent, 0.52)
		style.set_border_width_all(1)
		style.set_corner_radius_all(4)
		style.shadow_color = Color(INK, 0.10)
		style.shadow_size = 3
		style.shadow_offset = Vector2(0, 2)
		_card_styles.append(style)


func _ensure_batch() -> void:
	if _batch != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("formation_atlas", ATLAS)
	_material.set_shader_parameter("visual_seconds", 0.0)
	_material.set_shader_parameter("layer_alpha", 1.0)
	# This isolated harness has no map lighting uniforms. Keep the generated
	# artwork neutral here; production lighting is validated in player_game.
	_material.set_shader_parameter("terrain_instance_lighting_enabled", false)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_custom_data = true
	multimesh.use_colors = true
	multimesh.mesh = quad
	multimesh.instance_count = INSTANCE_CAP
	multimesh.visible_instance_count = 0
	_batch = MultiMeshInstance2D.new()
	_batch.name = "FormationMembers"
	_batch.multimesh = multimesh
	_batch.texture = ATLAS
	_batch.material = _material
	_batch.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_batch)


func _on_viewport_size_changed() -> void:
	_layout_for_viewport()


func _layout_for_viewport() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var size := viewport.get_visible_rect().size
	_content_rect = Rect2(
		Vector2(32.0, 194.0),
		Vector2(maxf(900.0, size.x - 64.0), maxf(430.0, size.y - 266.0))
	)
	queue_redraw()
	_rebuild_instances()


func set_content_rect(rect: Rect2) -> void:
	_content_rect = rect
	queue_redraw()
	_rebuild_instances()


func set_action(action_id: String) -> void:
	for index in _actions.size():
		if String((_actions[index] as Dictionary).get("id", "")) == action_id:
			set_action_index(index)
			return
	push_warning("MilitaryFormationPreviewLayer: unknown action '%s'" % action_id)


func set_action_index(index: int) -> void:
	if _actions.is_empty():
		return
	_action_index = clampi(index, 0, _actions.size() - 1)
	_action_started = _visual_seconds
	_rebuild_instances()
	action_changed.emit(String((_actions[_action_index] as Dictionary).get("id", "")))


func set_lod_mode(index: int) -> void:
	if _lods.is_empty():
		return
	_lod_index = clampi(index, 0, _lods.size() - 1)
	_rebuild_instances()
	lod_changed.emit(_lod_index)


func step_lod(direction: int) -> void:
	if _lods.is_empty():
		return
	set_lod_mode(posmod(_lod_index + direction, _lods.size()))


func set_heading_degrees(value: float) -> void:
	_heading_degrees = fposmod(value, 360.0)
	_rebuild_instances()
	heading_changed.emit(_heading_degrees)


func step_heading_degrees(delta: float) -> void:
	set_heading_degrees(_heading_degrees + delta)


func set_paused(value: bool) -> void:
	if _paused == value:
		return
	_paused = value
	paused_changed.emit(_paused)


func toggle_paused() -> void:
	set_paused(not _paused)


func set_reduced_motion_override(value: int) -> void:
	_reduced_motion_override = clampi(value, -1, 1)
	_apply_motion_parameter()
	reduced_motion_changed.emit(is_reduced_motion())


func toggle_reduced_motion() -> void:
	set_reduced_motion_override(0 if is_reduced_motion() else 1)


func is_reduced_motion() -> bool:
	if _reduced_motion_override == 0:
		return false
	if _reduced_motion_override == 1:
		return true
	return UIAnimation.reduced_motion()


func is_paused() -> bool:
	return _paused


func active_action_id() -> String:
	if _actions.is_empty():
		return ""
	return String((_actions[_action_index] as Dictionary).get("id", ""))


func active_action_index() -> int:
	return _action_index


func active_action_name() -> String:
	if _actions.is_empty():
		return ""
	return String((_actions[_action_index] as Dictionary).get("name", ""))


func active_lod_id() -> String:
	if _lods.is_empty():
		return ""
	return String((_lods[_lod_index] as Dictionary).get("id", ""))


func active_lod_index() -> int:
	return _lod_index


func active_lod_name() -> String:
	if _lods.is_empty():
		return ""
	return String((_lods[_lod_index] as Dictionary).get("name", ""))


func action_ids() -> PackedStringArray:
	var result := PackedStringArray()
	for action in _actions:
		result.append(String((action as Dictionary).get("id", "")))
	return result


func lod_ids() -> PackedStringArray:
	var result := PackedStringArray()
	for lod in _lods:
		result.append(String((lod as Dictionary).get("id", "")))
	return result


func heading_degrees() -> float:
	return _heading_degrees


func reset_view() -> void:
	_visual_seconds = 0.0
	_action_index = 0
	_action_started = 0.0
	_lod_index = 2
	_heading_degrees = 0.0
	_paused = false
	_reduced_motion_override = -1
	_apply_motion_parameter()
	_rebuild_instances()
	action_changed.emit(active_action_id())
	lod_changed.emit(_lod_index)
	paused_changed.emit(_paused)
	reduced_motion_changed.emit(is_reduced_motion())


func _process(delta: float) -> void:
	if not _paused:
		_visual_seconds += delta
		if not _actions.is_empty():
			var action := _actions[_action_index] as Dictionary
			if not bool(action.get("loop", true)):
				var duration := _action_duration(action)
				if _visual_seconds - _action_started >= duration:
					set_action_index(0)
	if _material != null:
		_material.set_shader_parameter("visual_seconds", _visual_seconds)
	_apply_motion_parameter()


func _apply_motion_parameter() -> void:
	if _material != null:
		_material.set_shader_parameter("reduced_motion", is_reduced_motion())


func _action_duration(action: Dictionary) -> float:
	var frames := maxi(1, int(action.get("frames", 8)))
	var fps := maxf(1.0, float(action.get("fps", 8.0)))
	var duration := float(frames) / fps
	if not bool(action.get("loop", true)):
		duration += 4.0 * ONE_SHOT_MEMBER_STAGGER_SECONDS
	return duration


func _grid_metrics() -> Dictionary:
	var header_height := 30.0
	var gutter_width := 108.0
	var gap := 10.0
	var grid_origin := _content_rect.position + Vector2(gutter_width + gap, header_height + gap)
	var grid_size := Vector2(
		_content_rect.size.x - gutter_width - gap,
		_content_rect.size.y - header_height - gap
	)
	var column_gap := 10.0
	var row_gap := 9.0
	var columns := maxi(1, _headcount_bands.size())
	var rows := maxi(1, _prototypes.size())
	var cell_size := Vector2(
		(grid_size.x - column_gap * float(columns - 1)) / float(columns),
		(grid_size.y - row_gap * float(rows - 1)) / float(rows)
	)
	return {
		"origin": grid_origin,
		"size": grid_size,
		"cell_size": cell_size,
		"column_gap": column_gap,
		"row_gap": row_gap,
		"columns": columns,
		"rows": rows,
	}


func _card_rect(row: int, column: int) -> Rect2:
	var metrics := _grid_metrics()
	var cell_size: Vector2 = metrics["cell_size"]
	var origin: Vector2 = metrics["origin"]
	var column_gap := float(metrics["column_gap"])
	var row_gap := float(metrics["row_gap"])
	return Rect2(
		origin + Vector2(
			float(column) * (cell_size.x + column_gap),
			float(row) * (cell_size.y + row_gap)
		),
		cell_size
	)


func _rebuild_instances() -> void:
	if _batch == null:
		return
	var multimesh := _batch.multimesh
	if _prototypes.is_empty() or _headcount_bands.is_empty() or _actions.is_empty():
		multimesh.visible_instance_count = 0
		_visible_instances = 0
		return
	var metrics := _grid_metrics()
	var cell_size: Vector2 = metrics["cell_size"]
	var sprite_size := clampf(cell_size.y * 0.40, 34.0, 60.0)
	var custom_phase := _action_started
	var emitted := 0

	for prototype_row in _prototypes.size():
		var prototype := _prototypes[prototype_row] as Dictionary
		var layouts := prototype.get("layouts", []) as Array
		var prototype_scale := float(prototype.get("sprite_scale", 1.0))
		for band_index in _headcount_bands.size():
			var band := _headcount_bands[band_index] as Dictionary
			var member_count := int(band.get("members", band_index + 1))
			var shown_members := 1
			if _lod_index == 2:
				shown_members = member_count
			var card := _card_rect(prototype_row, band_index)
			var anchor := card.get_center() + Vector2(0, card.size.y * 0.035)
			var member_layout: Array = []
			if not layouts.is_empty():
				var layout_index := clampi(shown_members - 1, 0, layouts.size() - 1)
				member_layout = layouts[layout_index] as Array
			for member_index in shown_members:
				if emitted >= INSTANCE_CAP:
					break
				var offset := Vector2.ZERO
				if member_index < member_layout.size():
					var pair := member_layout[member_index] as Array
					if pair.size() >= 2:
						offset = Vector2(float(pair[0]), float(pair[1]))
				var scale := sprite_size * prototype_scale
				if _lod_index == 0:
					scale *= 1.28
				elif _lod_index == 1:
					scale *= 1.10
				var position := anchor + offset.rotated(deg_to_rad(_heading_degrees)) * scale
				var transform := Transform2D(
					deg_to_rad(_heading_degrees),
					Vector2(scale, scale),
					0.0,
					position
				)
				var phase := 0.0
				var action := _actions[_action_index] as Dictionary
				if not bool(action.get("loop", true)):
					phase = one_shot_member_start(custom_phase, member_index)
				else:
					phase = fposmod(
						float(prototype_row) * 0.19
						+ float(band_index) * 0.13
						+ float(member_index) * 0.077,
						1.0
					)
				var custom := Color(
					float(prototype_row),
					float(_action_index),
					phase,
					float(member_index)
				)
				multimesh.set_instance_transform_2d(emitted, transform)
				multimesh.set_instance_custom_data(emitted, custom)
				multimesh.set_instance_color(
					emitted, PROTOTYPE_COLORS[prototype_row % PROTOTYPE_COLORS.size()])
				emitted += 1
	multimesh.visible_instance_count = emitted
	_visible_instances = emitted
	queue_redraw()


static func one_shot_member_start(started: float, member: int) -> float:
	return maxf(0.0, started
		+ float(maxi(0, member)) * ONE_SHOT_MEMBER_STAGGER_SECONDS)


func _draw() -> void:
	if _prototypes.is_empty() or _headcount_bands.is_empty():
		return
	var metrics := _grid_metrics()
	var origin: Vector2 = metrics["origin"]
	var cell_size: Vector2 = metrics["cell_size"]
	var column_gap := float(metrics["column_gap"])
	var row_gap := float(metrics["row_gap"])

	for band_index in _headcount_bands.size():
		var band := _headcount_bands[band_index] as Dictionary
		var card := _card_rect(0, band_index)
		var header := "成员 %d  /  %s" % [
			int(band.get("members", band_index + 1)),
			String(band.get("label", "")),
		]
		draw_string(
			SANS_FONT,
			Vector2(card.position.x + 4.0, origin.y - 12.0),
			header,
			HORIZONTAL_ALIGNMENT_LEFT,
			card.size.x - 8.0,
			13,
			INK_MUTED
		)

	for prototype_row in _prototypes.size():
		var prototype := _prototypes[prototype_row] as Dictionary
		var accent: Color = PROTOTYPE_COLORS[prototype_row % PROTOTYPE_COLORS.size()]
		var first_card := _card_rect(prototype_row, 0)
		var label_rect := Rect2(
			Vector2(_content_rect.position.x, first_card.position.y),
			Vector2(96.0, first_card.size.y)
		)
		draw_line(
			Vector2(label_rect.end.x - 8.0, label_rect.position.y + 12.0),
			Vector2(label_rect.end.x - 8.0, label_rect.end.y - 12.0),
			Color(accent, 0.50),
			2.0
		)
		draw_string(
			DISPLAY_FONT,
			Vector2(label_rect.position.x + 12.0, label_rect.position.y + label_rect.size.y * 0.48),
			String(prototype.get("short_name", prototype.get("name", ""))),
			HORIZONTAL_ALIGNMENT_LEFT,
			label_rect.size.x - 20.0,
			24,
			INK
		)
		draw_string(
			SANS_FONT,
			Vector2(label_rect.position.x + 14.0, label_rect.position.y + label_rect.size.y * 0.66),
			String(prototype.get("caption", "")),
			HORIZONTAL_ALIGNMENT_LEFT,
			label_rect.size.x - 22.0,
			12,
			Color(accent, 0.90)
		)

		for band_index in _headcount_bands.size():
			var card := _card_rect(prototype_row, band_index)
			draw_style_box(_card_styles[prototype_row % _card_styles.size()], card)
			_draw_card_hexes(card, accent)
			if _lod_index == 0:
				_draw_aggregate_backing(card, accent)
			draw_line(
				Vector2(card.position.x + 8.0, card.position.y + 27.0),
				Vector2(card.end.x - 8.0, card.position.y + 27.0),
				Color(accent, 0.20),
				1.0
			)
			var band := _headcount_bands[band_index] as Dictionary
			draw_string(
				SANS_FONT,
				Vector2(card.position.x + 10.0, card.position.y + 19.0),
				"%d 组" % int(band.get("members", band_index + 1)),
				HORIZONTAL_ALIGNMENT_LEFT,
				card.size.x - 20.0,
				12,
				Color(accent, 0.96)
			)
			draw_string(
				SANS_FONT,
				Vector2(card.position.x + 10.0, card.end.y - 10.0),
				_sample_composition_label(prototype, int(band.get("members", band_index + 1))),
				HORIZONTAL_ALIGNMENT_CENTER,
				card.size.x - 20.0,
				12,
				INK_MUTED
			)

	# Bottom rule carries the prototype's visual key without competing with art.
	var bottom_y := _content_rect.end.y + 8.0
	draw_line(Vector2(_content_rect.position.x, bottom_y),
		Vector2(_content_rect.end.x, bottom_y), Color(LINE, 0.42), 1.0)


func _draw_aggregate_backing(card: Rect2, accent: Color) -> void:
	var center := card.get_center() + Vector2(0.0, card.size.y * 0.035)
	var radius := clampf(card.size.y * 0.22, 24.0, 34.0)
	draw_circle(center + Vector2(0.0, 2.0), radius + 1.5, Color(INK, 0.12), true, -1.0, true)
	draw_circle(center, radius, Color(PAPER_LIGHT, 0.97), true, -1.0, true)
	draw_arc(center, radius, 0.0, TAU, 48, Color(accent, 0.92), 1.6, true)
	draw_arc(center, radius - 4.0, 0.0, TAU, 48, Color(INK, 0.28), 0.8, true)
	var band := PackedVector2Array([
		center + Vector2(-radius * 0.50, radius * 0.78),
		center + Vector2(radius * 0.50, radius * 0.78),
		center + Vector2(radius * 0.36, radius * 0.93),
		center + Vector2(-radius * 0.36, radius * 0.93),
	])
	draw_colored_polygon(band, Color(accent, 0.88))


func _draw_card_hexes(card: Rect2, accent: Color) -> void:
	var radius := minf(11.0, card.size.y * 0.085)
	var x_step := radius * 1.70
	var y_step := radius * 1.48
	var center := card.get_center() + Vector2(0.0, 5.0)
	var fill := Color(accent, 0.055)
	var outline := Color(accent, 0.12)
	for row in range(-2, 2):
		for column in range(-4, 5):
			var cx := center.x + float(column) * x_step + (radius * 0.85 if row % 2 != 0 else 0.0)
			var cy := center.y + float(row) * y_step
			if cx < card.position.x + 8.0 or cx > card.end.x - 8.0:
				continue
			if cy < card.position.y + 33.0 or cy > card.end.y - 24.0:
				continue
			var points := PackedVector2Array()
			for side in 6:
				var angle := PI / 6.0 + TAU * float(side) / 6.0
				points.append(Vector2(cx, cy) + Vector2(cos(angle), sin(angle)) * radius)
			draw_colored_polygon(points, fill)
			points.append(points[0])
			draw_polyline(points, outline, 0.8, true)


func _sample_composition_label(prototype: Dictionary, members: int) -> String:
	var units := prototype.get("composition_units", []) as Array
	var weights: Array = []
	for unit in units:
		weights.append(float((unit as Dictionary).get("weight", 0)))
	var buckets := allocate_member_buckets(weights, members)
	var parts := PackedStringArray()
	for index in mini(buckets.size(), units.size()):
		if buckets[index] <= 0:
			continue
		var unit := units[index] as Dictionary
		parts.append("%s×%d" % [String(unit.get("short_name", unit.get("id", "?"))), buckets[index]])
	if parts.is_empty():
		return "%d 个视觉成员" % members
	return " + ".join(parts)


func debug_snapshot() -> Dictionary:
	return {
		"prototype_count": _prototypes.size(),
		"action_count": _actions.size(),
		"lod_count": _lods.size(),
		"headcount_bands": _headcount_bands.size(),
		"visible_instances": _visible_instances,
		"action": active_action_id(),
		"lod": active_lod_id(),
		"heading_degrees": _heading_degrees,
		"paused": _paused,
		"reduced_motion": is_reduced_motion(),
	}


static func member_count_for_headcount(headcount: int, bands: Array) -> int:
	for band in bands:
		var row := band as Dictionary
		var minimum := int(row.get("min", 0))
		var maximum := int(row.get("max", 2147483647))
		if headcount >= minimum and headcount <= maximum:
			return int(row.get("members", 1))
	return 1


static func lod_for_zoom(zoom: float, lods: Array) -> int:
	for index in lods.size():
		var row := lods[index] as Dictionary
		if zoom < float(row.get("zoom_max", 999.0)):
			return index
	return maxi(0, lods.size() - 1)


static func allocate_member_buckets(weights: Array, member_count: int) -> PackedInt32Array:
	var buckets := PackedInt32Array()
	buckets.resize(weights.size())
	buckets.fill(0)
	if weights.is_empty() or member_count <= 0:
		return buckets
	var order: Array[int] = []
	for index in weights.size():
		if float(weights[index]) > 0.0:
			order.append(index)
	if order.is_empty():
		for index in mini(member_count, buckets.size()):
			buckets[index] = 1
		return buckets
	order.sort_custom(func(a: int, b: int) -> bool:
		var aw := float(weights[a])
		var bw := float(weights[b])
		if is_equal_approx(aw, bw):
			return a < b
		return aw > bw
	)
	var selected := mini(member_count, order.size())
	for index in selected:
		buckets[order[index]] = 1
	var remaining := member_count - selected
	if remaining <= 0:
		return buckets
	var total_weight := 0.0
	for index in selected:
		total_weight += maxf(0.0, float(weights[order[index]]))
	if total_weight <= 0.000001:
		for index in remaining:
			buckets[order[index % selected]] += 1
		return buckets
	var fractions: Array[Dictionary] = []
	var assigned := 0
	for index in selected:
		var unit_index := order[index]
		var share := float(remaining) * float(weights[unit_index]) / total_weight
		var floor_share := int(floor(share))
		buckets[unit_index] += floor_share
		assigned += floor_share
		fractions.append({
			"index": unit_index,
			"fraction": share - float(floor_share),
		})
	var leftovers := remaining - assigned
	fractions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var af := float(a.get("fraction", 0.0))
		var bf := float(b.get("fraction", 0.0))
		if is_equal_approx(af, bf):
			return int(a.get("index", 0)) < int(b.get("index", 0))
		return af > bf
	)
	for index in leftovers:
		buckets[int(fractions[index].get("index", 0))] += 1
	return buckets
