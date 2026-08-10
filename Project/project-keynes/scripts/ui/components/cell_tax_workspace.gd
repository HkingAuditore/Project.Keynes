extends VBoxContainer
class_name CellTaxWorkspace

## Inspector-owned sparse cell-tax editor. The row node count is fixed; scroll
## only rebinds visible rows, so daily commits never rebuild the control tree.

const KIND_KEYS := ["income", "consumption", "business", "import", "export"]
const KIND_LABELS := ["所得税", "消费税", "营业税", "进口关税", "出口关税"]
const ROW_HEIGHT := 48.0
const ROW_POOL_SIZE := 10

var _player_controller = null
var _model: Dictionary = {}
var _kind := 0
var _search: LineEdit
var _local_only: CheckButton
var _kind_picker: OptionButton
var _default_spin: SpinBox
var _default_clear: Button
var _clear_all: Button
var _status: Label
var _scroll: ScrollContainer
var _canvas: Control
var _rows: Array[Dictionary] = []
var _filtered: PackedInt32Array = PackedInt32Array()
var _pending: Dictionary = {}


func _ready() -> void:
	if _search != null:
		return
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tools := HBoxContainer.new()
	add_child(tools)
	_kind_picker = OptionButton.new()
	for label in KIND_LABELS:
		_kind_picker.add_item(label)
	_kind_picker.item_selected.connect(_on_kind_selected)
	tools.add_child(_kind_picker)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索 stable item ID"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_on_filter_changed.unbind(1))
	tools.add_child(_search)
	_local_only = CheckButton.new()
	_local_only.text = "仅本地"
	_local_only.toggled.connect(_on_filter_changed.unbind(1))
	tools.add_child(_local_only)

	var defaults := HBoxContainer.new()
	add_child(defaults)
	var default_label := Label.new()
	default_label.text = "本地税种默认率"
	default_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	defaults.add_child(default_label)
	_default_spin = SpinBox.new()
	_default_spin.min_value = -100
	_default_spin.max_value = 100
	_default_spin.suffix = "%"
	_default_spin.get_line_edit().text_submitted.connect(
		func(_text: String) -> void: _submit_default())
	defaults.add_child(_default_spin)
	_default_clear = Button.new()
	_default_clear.text = "恢复继承"
	_default_clear.pressed.connect(_clear_default)
	defaults.add_child(_default_clear)
	_clear_all = Button.new()
	_clear_all.text = "清除本格全部"
	_clear_all.pressed.connect(_clear_all_policy)
	defaults.add_child(_clear_all)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, 360)
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.get_v_scroll_bar().value_changed.connect(_on_scroll.unbind(1))
	add_child(_scroll)
	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(0, ROW_POOL_SIZE * ROW_HEIGHT)
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_canvas)
	for pool_index in range(ROW_POOL_SIZE):
		_rows.append(_make_row(pool_index))

	_status = Label.new()
	_status.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	add_child(_status)


func set_player_controller(controller) -> void:
	_player_controller = controller
	_refresh_controls()


func set_model(model: Dictionary, reset_scroll: bool = false) -> void:
	if _search == null:
		_ready()
	var old_cell := int(_model.get("cell", -1))
	_model = model
	_resolve_pending()
	if reset_scroll or old_cell != int(_model.get("cell", -1)):
		_scroll.scroll_vertical = 0
	_rebuild_filter()
	_refresh_controls()


func pooled_row_count() -> int:
	return _rows.size()


func _make_row(pool_index: int) -> Dictionary:
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	panel.offset_top = pool_index * ROW_HEIGHT
	panel.offset_bottom = panel.offset_top + ROW_HEIGHT - 4
	panel.custom_minimum_size.y = ROW_HEIGHT - 4
	_canvas.add_child(panel)
	var row := HBoxContainer.new()
	panel.add_child(row)
	var name := Label.new()
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name)
	var source := Label.new()
	source.custom_minimum_size.x = 92
	source.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	row.add_child(source)
	var effective := Label.new()
	effective.custom_minimum_size.x = 66
	effective.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(effective)
	var spin := SpinBox.new()
	spin.min_value = -100
	spin.max_value = 100
	spin.suffix = "%"
	spin.custom_minimum_size.x = 92
	spin.get_line_edit().text_submitted.connect(
		func(_text: String) -> void: _submit_row(pool_index))
	row.add_child(spin)
	var clear := Button.new()
	clear.text = "重置"
	clear.pressed.connect(func() -> void: _clear_row(pool_index))
	row.add_child(clear)
	return {"panel": panel, "name": name, "source": source,
		"effective": effective, "spin": spin, "clear": clear,
		"item_index": -1}


func _on_kind_selected(index: int) -> void:
	_kind = clampi(index, 0, KIND_KEYS.size() - 1)
	_scroll.scroll_vertical = 0
	_rebuild_filter()
	_refresh_controls()


func _on_filter_changed() -> void:
	_scroll.scroll_vertical = 0
	_rebuild_filter()
	_refresh_rows()


func _on_scroll() -> void:
	_refresh_rows()


func _rebuild_filter() -> void:
	_filtered.clear()
	var group: Dictionary = _model.get(KIND_KEYS[_kind], {})
	var ids: PackedStringArray = group.get("item_ids", PackedStringArray())
	var local: PackedByteArray = group.get("has_local_item", PackedByteArray())
	var needle := _search.text.strip_edges().to_lower() if _search != null else ""
	for item in range(ids.size()):
		if not needle.is_empty() and String(ids[item]).to_lower().find(needle) < 0:
			continue
		if _local_only != null and _local_only.button_pressed and \
				(item >= local.size() or local[item] == 0):
			continue
		_filtered.append(item)
	if _canvas != null:
		_canvas.custom_minimum_size.y = maxf(ROW_POOL_SIZE * ROW_HEIGHT,
			_filtered.size() * ROW_HEIGHT)


func _refresh_controls() -> void:
	if _default_spin == null:
		return
	var editable := bool(_model.get("editable", false)) and _player_controller != null
	var local_defaults: PackedInt32Array = _model.get(
		"local_default_rates", PackedInt32Array())
	var country_defaults: PackedInt32Array = _model.get(
		"country_default_rates", PackedInt32Array())
	var flags: PackedByteArray = _model.get(
		"has_local_default", PackedByteArray())
	var local := _kind < flags.size() and flags[_kind] != 0
	var value := int(local_defaults[_kind]) if local and _kind < local_defaults.size() \
		else (int(country_defaults[_kind]) if _kind < country_defaults.size() else 0)
	_default_spin.editable = editable
	_default_spin.set_value_no_signal(value)
	_default_clear.visible = editable and local
	_clear_all.visible = editable
	_refresh_rows()


func _refresh_rows() -> void:
	if _scroll == null:
		return
	var group: Dictionary = _model.get(KIND_KEYS[_kind], {})
	var ids: PackedStringArray = group.get("item_ids", PackedStringArray())
	var rates: PackedInt32Array = group.get("final_base_rates", PackedInt32Array())
	var effective_rates: PackedInt32Array = group.get(
		"effective_rates", PackedInt32Array())
	var flags: PackedByteArray = group.get("has_local_item", PackedByteArray())
	var sources: PackedStringArray = group.get("source_scopes", PackedStringArray())
	var editable := bool(_model.get("editable", false)) and _player_controller != null
	var first := maxi(0, int(floor(_scroll.scroll_vertical / ROW_HEIGHT)))
	for pool_index in range(_rows.size()):
		var row: Dictionary = _rows[pool_index]
		var filtered_index := first + pool_index
		var panel := row.panel as PanelContainer
		if filtered_index >= _filtered.size():
			panel.visible = false
			row.item_index = -1
			continue
		var item := int(_filtered[filtered_index])
		row.item_index = item
		panel.visible = true
		panel.position.y = filtered_index * ROW_HEIGHT
		(row.name as Label).text = String(ids[item]) if item < ids.size() else ""
		var source := String(sources[item]) if item < sources.size() else ""
		(row.source as Label).text = _source_label(source)
		var base := int(rates[item]) if item < rates.size() else 0
		var effective := int(effective_rates[item]) if item < effective_rates.size() else base
		(row.effective as Label).text = "有效 %d%%" % effective
		var spin := row.spin as SpinBox
		spin.editable = editable
		if not spin.get_line_edit().has_focus():
			spin.set_value_no_signal(base)
		var local := item < flags.size() and flags[item] != 0
		(row.clear as Button).visible = editable and local
		var pending_key := "%d:%s" % [_kind, String(ids[item])]
		if _pending.has(pending_key):
			(row.source as Label).text += " · 次日"


func _submit_default() -> void:
	if not _can_edit():
		return
	_submit(&"country.tax.cell.set_default", {
		"cell": int(_model.cell), "kind": _kind,
		"rate_percent": int(_default_spin.value)}, "%d:__default__" % _kind)


func _clear_default() -> void:
	if not _can_edit():
		return
	_submit(&"country.tax.cell.clear_default", {
		"cell": int(_model.cell), "kind": _kind}, "%d:__default__" % _kind)


func _clear_all_policy() -> void:
	if not _can_edit():
		return
	_submit(&"country.tax.cell.clear_all", {"cell": int(_model.cell)}, "all")


func _submit_row(pool_index: int) -> void:
	if not _can_edit() or pool_index < 0 or pool_index >= _rows.size():
		return
	var row: Dictionary = _rows[pool_index]
	var item := int(row.item_index)
	var ids: PackedStringArray = (_model.get(KIND_KEYS[_kind], {}) as Dictionary).get(
		"item_ids", PackedStringArray())
	if item < 0 or item >= ids.size():
		return
	var item_id := String(ids[item])
	_submit(&"country.tax.cell.set_override", {
		"cell": int(_model.cell), "kind": _kind,
		"item_id": StringName(item_id),
		"rate_percent": int((row.spin as SpinBox).value)},
		"%d:%s" % [_kind, item_id])


func _clear_row(pool_index: int) -> void:
	if not _can_edit() or pool_index < 0 or pool_index >= _rows.size():
		return
	var item := int((_rows[pool_index] as Dictionary).item_index)
	var ids: PackedStringArray = (_model.get(KIND_KEYS[_kind], {}) as Dictionary).get(
		"item_ids", PackedStringArray())
	if item < 0 or item >= ids.size():
		return
	var item_id := String(ids[item])
	_submit(&"country.tax.cell.clear_override", {
		"cell": int(_model.cell), "kind": _kind,
		"item_id": StringName(item_id)}, "%d:%s" % [_kind, item_id])


func _submit(command: StringName, args: Dictionary, pending_key: String) -> void:
	var result: Dictionary = _player_controller.request_command(command, args)
	if bool(result.get("ok", false)):
		_pending[pending_key] = {
			"effective_day": int(result.get("effective_day", -1)),
			"policy_version": int(_model.get("policy_version", -1)),
		}
		_status.text = "命令已提交：第 %d 日生效" % int(result.get("effective_day", -1))
	else:
		_status.text = String(result.get("message", result.get("reason", "命令失败")))
	_refresh_rows()


func _resolve_pending() -> void:
	var resolved: Array[String] = []
	for key_value in _pending:
		var key := String(key_value)
		var pending: Dictionary = _pending[key]
		if int(_model.get("current_day", -1)) >= int(pending.effective_day) and \
				int(_model.get("policy_version", -1)) > int(pending.policy_version):
			resolved.append(key)
	for key in resolved:
		_pending.erase(key)


func _can_edit() -> bool:
	return _player_controller != null and bool(_model.get("editable", false)) and \
		int(_model.get("cell", -1)) >= 0


func _source_label(source: String) -> String:
	match source:
		"cell_item": return "本格细项"
		"cell_default": return "本格默认"
		"country_item": return "全国细项"
		"country_default": return "全国默认"
	return "继承"
