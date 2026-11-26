extends RefCounted

const TouchUI = preload("res://scripts/ui/touch_ui.gd")

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const LevelMeterScript = preload(
	"res://scripts/ui/components/ideology_level_meter.gd")

## A collection entry is a physical card in the archive, not a text row. The
## authored frame carries rarity; the face reserves its space for school,
## current effect, a brass level seal and a full-width understanding track.
class CollectionEntry:
	extends Control
	var _name: Label
	var _effects: Label
	var _emblem: TextureRect
	var _footer: HBoxContainer
	var _level_meter: Control
	var _payload := {}
	var _draggable := true
	var _surface: CardSurface
	var _face: MarginContainer
	var _column: VBoxContainer
	var _band: HBoxContainer
	var _rarity := 1
	var _hover_tween: Tween
	var _status: Label
	var _detail_model: Dictionary = {}
	var _action_well: MarginContainer
	var _head: HBoxContainer
	var _compact := false
	var _pressing := false
	var _press_pos := Vector2.ZERO
	var _press_moved := false

	func setup(data: Dictionary) -> void:
		_detail_model = data.get("detail_model", {})
		_payload = data.get("payload", {}).duplicate()
		_payload["activated"] = data.get("activated", Callable())
		_payload["detail_requested"] = data.get("detail_requested", Callable())
		_payload["locate_requested"] = data.get("locate_requested", Callable())
		_draggable = bool(data.get("draggable", true))
		_compact = bool(data.get("compact", false))
		var compact := _compact
		_rarity = clampi(int(data.get("rarity", 1)), 1, 3)
		focus_mode = Control.FOCUS_ALL
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		clip_contents = false
		_surface = CardSurface.new()
		_surface.rarity = _rarity
		_surface.accent = ArtScript.school_color(String(data.get("school_id", "")))
		_surface.compact = compact
		_surface.rarity_glow = ArtScript.rarity_glow(_rarity)
		_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(_surface)
		_face = MarginContainer.new()
		_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_face.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# 纸面只保留统一内边距；文字、理解度和操作由同一列容器顺排。
		for side in ["left", "top", "right", "bottom"]:
			_face.add_theme_constant_override("margin_%s" % side, 18)
		add_child(_face)
		_column = VBoxContainer.new()
		_column.add_theme_constant_override("separation", 10)
		_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_face.add_child(_column)
		_head = HBoxContainer.new()
		_head.add_theme_constant_override("separation", 10)
		_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_column.add_child(_head)
		_emblem = TextureRect.new()
		_emblem.texture = ArtScript.emblem_for(String(data.get("school_id", "")))
		_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_emblem.custom_minimum_size = Vector2(36, 36)
		_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_head.add_child(_emblem)
		var identity := VBoxContainer.new()
		identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		identity.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_head.add_child(identity)
		_name = ArtScript.label(String(data.get("name", "")), 22,
			ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
		_name.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
		_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		identity.add_child(_name)
		_status = ArtScript.label("", 15, ArtScript.VERMILION, HORIZONTAL_ALIGNMENT_LEFT)
		identity.add_child(_status)
		refresh_status(bool(data.get("pending", false)), int(data.get("location", 0)))
		var edition := ArtScript.label(String(ArtScript.RARITY_NAMES[_rarity]),
			15, ArtScript.rarity_accent(_rarity), HORIZONTAL_ALIGNMENT_RIGHT)
		edition.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_head.add_child(edition)
		_effects = ArtScript.label("", 17, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
		_effects.text = "\n".join(data.get("effects", PackedStringArray()))
		_effects.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_effects.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_column.add_child(_effects)
		_band = HBoxContainer.new()
		_band.name = "LevelSealBand"
		_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_band.add_theme_constant_override("separation", 8)
		_column.add_child(_band)
		var meter_data: Dictionary = data.get("level_progress", {})
		meter_data["accent"] = ArtScript.GOLD_LEAF.lerp(
			ArtScript.school_color(String(data.get("school_id", ""))), 0.12)
		_level_meter = LevelMeterScript.new()
		_level_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_level_meter.configure(meter_data, compact)
		_band.add_child(_level_meter)
		_action_well = MarginContainer.new()
		_action_well.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_action_well.add_theme_constant_override("margin_top", 4)
		_action_well.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_column.add_child(_action_well)
		_footer = HBoxContainer.new()
		_footer.alignment = BoxContainer.ALIGNMENT_END
		_footer.add_theme_constant_override("separation", 8)
		_footer.size_flags_vertical = Control.SIZE_SHRINK_END
		_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_footer.visible = false
		_action_well.add_child(_footer)
		_column.minimum_size_changed.connect(_queue_layout)

		var tip_lines := PackedStringArray([String(data.get("name", ""))])
		var detail := String(data.get("detail", "")).strip_edges()
		if not detail.is_empty() and not detail.contains("."):
			tip_lines.append(detail)
		var effect_values: PackedStringArray = data.get("effects", PackedStringArray())
		for effect in effect_values:
			if not String(effect).strip_edges().is_empty():
				tip_lines.append("· %s" % String(effect))
		tooltip_text = String(data.get("tooltip", "\n".join(tip_lines)))
		gui_input.connect(_on_input)
		mouse_entered.connect(_set_hover.bind(true))
		mouse_exited.connect(_set_hover.bind(false))
		focus_entered.connect(_set_hover.bind(true))
		focus_exited.connect(_set_hover.bind(false))
		_apply_scaled_layout()

	func footer() -> HBoxContainer:
		return _footer

	func refresh_status(pending: bool, location: int) -> void:
		_status.text = "待生效" if pending else "推行中" if location == 1 else "民族精神" if location == 2 else ""
		_status.visible = not _status.text.is_empty()
		if not _detail_model.is_empty():
			_detail_model["status"] = "待生效" if pending else "推行中" \
				if location == 1 else "民族精神" if location == 2 else "尚未推行"

	func refresh_support_details(supports: Array[Dictionary]) -> void:
		if not _detail_model.is_empty():
			_detail_model["supports"] = supports

	func refresh_progress(data: Dictionary) -> void:
		if _level_meter != null:
			_level_meter.configure(data, _compact)
		if not _detail_model.is_empty():
			var progress := data.duplicate(false)
			progress.erase("accent")
			_detail_model["progress"] = progress

	func refresh_card_data(data: Dictionary) -> void:
		tooltip_text = String(data.get("tooltip", ""))
		set_detail_model(data.get("detail_model", {}))
		var effects: PackedStringArray = data.get("effects", PackedStringArray())
		_effects.text = "\n".join(effects)
		refresh_progress(data.get("level_progress", {}))

	func level_meter() -> Control:
		return _level_meter

	func refresh_layout() -> void:
		_apply_scaled_layout()

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_apply_scaled_layout()

	func _queue_layout() -> void:
		call_deferred("_apply_scaled_layout")

	func _apply_scaled_layout() -> void:
		if _face == null or _column == null or size.x < 1.0:
			return
		# 正文完整换行后决定卡高；操作始终位于理解度下方。
		var required := ceilf(_column.get_combined_minimum_size().y + 36.0)
		custom_minimum_size.y = maxf(208.0, required)

	func _make_custom_tooltip(for_text: String) -> Object:
		return ArtScript.detail_tooltip(for_text, _detail_model)

	func set_detail_model(data: Dictionary) -> void:
		_detail_model = data

	func frame_path() -> String:
		return ArtScript.PAPER_SHEET

	func play_deal_in(delay := 0.0) -> void:
		if not is_inside_tree() or UIAnimation.reduced_motion():
			return
		pivot_offset = size * 0.5
		scale = Vector2(0.94, 0.94)
		modulate.a = 0.0
		var tween := create_tween().set_parallel(true)
		tween.tween_interval(delay)
		tween.tween_property(self, "modulate:a", 1.0, 0.24) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_property(self, "scale", Vector2.ONE, 0.30) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

	func _set_hover(on: bool) -> void:
		if _hover_tween != null and _hover_tween.is_valid():
			_hover_tween.kill()
		_hover_tween = create_tween().set_parallel(true)
		_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_hover_tween.tween_property(_surface, "hover_lift", 1.0 if on else 0.0, 0.15)
		_hover_tween.tween_property(self, "self_modulate",
			Color(1.035, 1.025, 0.985) if on else Color.WHITE, 0.15)

	func _on_input(event: InputEvent) -> void:
		if ArtScript.scroll_detail(event):
			accept_event()
			return
		if event.is_action_pressed(&"ui_accept"):
			_payload.get("activated", Callable()).call()
			accept_event()
			return
		if event is InputEventMouseMotion:
			if _pressing and (event as InputEventMouseMotion).position.distance_to(_press_pos) > 10.0:
				_press_moved = true
			return
		if event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index == MOUSE_BUTTON_RIGHT:
				if mouse.pressed:
					var locate_cb: Callable = _payload.get("locate_requested", Callable())
					if locate_cb.is_valid():
						locate_cb.call()
						accept_event()
				return
			if mouse.button_index == MOUSE_BUTTON_LEFT:
				if mouse.pressed:
					_pressing = true
					_press_pos = mouse.position
					_press_moved = false
				else:
					var was_tap := _pressing and not _press_moved
					_pressing = false
					if mouse.double_click:
						_payload.get("activated", Callable()).call()
						accept_event()
					elif was_tap:
						var detail_cb: Callable = _payload.get("detail_requested", Callable())
						if detail_cb.is_valid():
							detail_cb.call()
							accept_event()

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if not _draggable or TouchUI.is_touch():
			return null
		var holder := Control.new()
		var preview := NinePatchRect.new()
		preview.texture = ArtScript.collection_frame_for(_rarity)
		preview.size = Vector2(220, 148)
		preview.position = -preview.size * 0.5
		preview.patch_margin_left = 0
		preview.patch_margin_right = 0
		preview.patch_margin_top = 0
		preview.patch_margin_bottom = 0
		preview.rotation = -0.035
		holder.add_child(preview)
		var label := ArtScript.label(_name.text, 16, ArtScript.INK)
		label.add_theme_font_override("font",
			preload("res://assets/fonts/muyao/display_handwritten.tres"))
		label.position = -preview.size * 0.5 + Vector2(18, 18)
		label.size = Vector2(preview.size.x - 24, 24)
		holder.add_child(label)
		set_drag_preview(holder)
		return _payload.duplicate()


## Independent paper, edition edging and diffuse shadow layers.
class CardSurface:
	extends Control
	var rarity := 1
	var accent := Color(0.3, 0.22, 0.14)
	var rarity_glow := Color(0.88, 0.79, 0.59, 0.20)
	var compact := false
	var hover_lift := 0.0:
		set(value):
			hover_lift = value
			queue_redraw()

	func _init() -> void:
		ArtScript.attach_paper_shadow(self, 0.16)

	func _draw() -> void:
		if size.x < 20.0 or size.y < 20.0:
			return
		var rect := Rect2(Vector2.ZERO, size)
		draw_style_box(ArtScript.paper_style(0.0, ArtScript.paper_tint(rarity)), rect)
		if rarity >= 2:
			draw_style_box(ArtScript.edition_style(rarity), rect)
		# A school-coloured paper tab and ink rule are independent layers.
		draw_style_box(ArtScript.paper_style(0.0, accent.lightened(0.12)),
			Rect2(0, 16, 6, 40))
		if hover_lift > 0.01:
			draw_rect(rect.grow(-3), Color(accent, 0.35 * hover_lift), false, 1.0)
