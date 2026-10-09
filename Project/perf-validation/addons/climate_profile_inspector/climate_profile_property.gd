@tool
extends EditorProperty

var _type: int = TYPE_NIL
var _hint: int = PROPERTY_HINT_NONE
var _hint_string: String = ""
var _updating: bool = false
var _control: Control = null
var _spin_boxes: Array[SpinBox] = []
var _option_button: OptionButton = null
var _line_edit: LineEdit = null
var _check_box: CheckBox = null


func setup(p_type: int, p_hint: int, p_hint_string: String, p_label: String) -> void:
	_type = p_type
	_hint = p_hint
	_hint_string = p_hint_string
	label = p_label
	_build_control()


func _build_control() -> void:
	match _type:
		TYPE_BOOL:
			_check_box = CheckBox.new()
			_check_box.text = ""
			_check_box.toggled.connect(_on_bool_changed)
			_control = _check_box
		TYPE_INT:
			if _hint == PROPERTY_HINT_ENUM:
				_option_button = OptionButton.new()
				_option_button.item_selected.connect(_on_option_selected)
				var names := _hint_string.split(",", false)
				for item_name in names:
					_option_button.add_item(item_name.strip_edges())
				_control = _option_button
			else:
				_control = _make_spin_box(true)
		TYPE_FLOAT:
			_control = _make_spin_box(false)
		TYPE_VECTOR2:
			_control = _make_vector2_editor()
		TYPE_ARRAY:
			_line_edit = LineEdit.new()
			_line_edit.placeholder_text = "用逗号分隔，例如 1.0, 0.8, 1.2"
			_line_edit.text_submitted.connect(_on_array_submitted)
			_line_edit.focus_exited.connect(_on_array_focus_exited)
			_control = _line_edit
		_:
			_line_edit = LineEdit.new()
			_line_edit.editable = false
			_control = _line_edit
	if _control != null:
		add_child(_control)
		add_focusable(_control)


func _make_spin_box(integer_only: bool) -> SpinBox:
	var spin := SpinBox.new()
	var range := _range_from_hint(integer_only)
	spin.min_value = range["min"]
	spin.max_value = range["max"]
	spin.step = range["step"]
	spin.allow_lesser = true
	spin.allow_greater = true
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.value_changed.connect(_on_number_changed)
	_spin_boxes.append(spin)
	return spin


func _make_vector2_editor() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for axis in ["X", "Y"]:
		var axis_label := Label.new()
		axis_label.text = axis
		box.add_child(axis_label)
		var spin := _make_spin_box(false)
		spin.custom_minimum_size.x = 96.0
		box.add_child(spin)
	return box


func _range_from_hint(integer_only: bool) -> Dictionary:
	var min_v: float = -1000000.0
	var max_v: float = 1000000.0
	var step_v: float = 1.0 if integer_only else 0.01
	if _hint == PROPERTY_HINT_RANGE and _hint_string != "":
		var parts := _hint_string.split(",", false)
		if parts.size() >= 2:
			min_v = float(parts[0])
			max_v = float(parts[1])
		if parts.size() >= 3:
			step_v = float(parts[2])
	return {"min": min_v, "max": max_v, "step": step_v}


func _update_property() -> void:
	var edited := get_edited_object()
	if edited == null:
		return
	var value = edited.get(get_edited_property())
	_updating = true
	match _type:
		TYPE_BOOL:
			if _check_box != null:
				_check_box.button_pressed = bool(value)
		TYPE_INT:
			if _option_button != null:
				_option_button.select(clampi(int(value), 0, max(0, _option_button.get_item_count() - 1)))
			elif not _spin_boxes.is_empty():
				_spin_boxes[0].value = int(value)
		TYPE_FLOAT:
			if not _spin_boxes.is_empty():
				_spin_boxes[0].value = float(value)
		TYPE_VECTOR2:
			if _spin_boxes.size() >= 2:
				var v := value as Vector2
				_spin_boxes[0].value = v.x
				_spin_boxes[1].value = v.y
		TYPE_ARRAY:
			if _line_edit != null:
				_line_edit.text = _array_to_text(value)
		_:
			if _line_edit != null:
				_line_edit.text = str(value)
	_updating = false


func _on_bool_changed(pressed: bool) -> void:
	if _updating:
		return
	emit_changed(get_edited_property(), pressed)


func _on_number_changed(_value: float) -> void:
	if _updating:
		return
	if _type == TYPE_VECTOR2 and _spin_boxes.size() >= 2:
		emit_changed(get_edited_property(), Vector2(_spin_boxes[0].value, _spin_boxes[1].value))
	elif _type == TYPE_INT:
		emit_changed(get_edited_property(), int(round(_spin_boxes[0].value)))
	else:
		emit_changed(get_edited_property(), float(_spin_boxes[0].value))


func _on_option_selected(index: int) -> void:
	if _updating:
		return
	emit_changed(get_edited_property(), index)


func _on_array_submitted(_text: String) -> void:
	_commit_array_text()


func _on_array_focus_exited() -> void:
	_commit_array_text()


func _commit_array_text() -> void:
	if _updating or _line_edit == null:
		return
	var out: Array[float] = []
	for part in _line_edit.text.split(",", false):
		var trimmed := part.strip_edges()
		if trimmed == "":
			continue
		out.append(float(trimmed))
	emit_changed(get_edited_property(), out)


func _array_to_text(value) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if value is Array:
		for item in value:
			parts.append(str(item))
	return ", ".join(parts)
