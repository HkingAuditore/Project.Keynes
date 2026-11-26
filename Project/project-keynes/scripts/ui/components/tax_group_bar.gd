extends HBoxContainer
## 税制页的「组合并筛选 + 整组设值 + 收起明细」条。
##
## 这一条只负责三件事：让玩家选一个分组轴、选一个组、给整组填一个税率。
## 它不认识税种、不拼 item 列表、也不发命令——分组内容由宿主（经济工作区）
## 按自己的税快照算好灌进来，命令也由宿主经 PlayerController 提交。
##
## 组的语义是「一批 item_id」：宿主在提交时再按页面的税种展开（物资税页
## 一个货有交易/进口/出口三个税种，展开与分批都在宿主侧做）。
## 这里不做多选：选组就是选择，所以行内不需要任何新控件。
##
## 整组设值只开百分比：`country.tax.set_override_group` 的批量模块把计税
## 模式写死成 TAX_MODE_PERCENT_BP（country_tax_override_batch.gd:25），
## 定额档在这里显式置灰并写明原因，不静默降级。

## 分组轴换了：宿主据此重算组列表。
signal axis_changed(axis_id: String)
## 组换了：宿主据此重新过滤卡片。
signal group_changed(group_id: String)
## 玩家点了「整组设为」：宿主负责校验、分块、提交。
signal apply_requested(rate_basis_points: int, item_ids: PackedStringArray)
## 收起 / 展开明细。
signal collapse_toggled(collapsed: bool)

const PERCENT_MIN := -1000.0
const PERCENT_MAX := 100.0
const RATE_MIN_BP := -100000
const RATE_MAX_BP := 10000
const MODE_PERCENT := 0
const MODE_ABSOLUTE := 1
const ABSOLUTE_DISABLED_REASON := "整组设值只支持百分比：批量通道把计税模式写死为百分比，定额档会静默失效。"
## 税率输入框走场景实例化而不是在脚本里造控件：玩家 UI 不许运行时构造控件
## （tests/ui/ui_scene_structure_test.gd 的静态场景规矩）。这个场景就一个
## 裸自旋框，world_setup.gd:6 也是这么实例化再配属性的。
const RateFieldScene := preload("res://scenes/ui/setup_spin.tscn")

var _axis_picker: OptionButton = null
var _group_picker: OptionButton = null
var _summary: Label = null
var _mode_picker: OptionButton = null
var _rate_spin: SpinBox = null
var _apply_button: Button = null
var _collapse_button: Button = null

var _axes: Array = []
var _groups: Array = []
var _collapsed := false
var _busy := false
var _editable := false
var _applying := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_constant_override("separation", 8)
	_build()


func _build() -> void:
	var caption := UIControlParts.label()
	caption.name = "Caption"
	caption.text = "分组"
	caption.add_theme_font_size_override("font_size", 12)
	caption.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(caption)

	_axis_picker = UIControlParts.option_button()
	_axis_picker.name = "Axis"
	_axis_picker.custom_minimum_size = Vector2(118.0, 30.0)
	_axis_picker.tooltip_text = "选择分组轴"
	_axis_picker.item_selected.connect(_on_axis_selected)
	add_child(_axis_picker)

	_group_picker = UIControlParts.option_button()
	_group_picker.name = "Group"
	_group_picker.custom_minimum_size = Vector2(190.0, 30.0)
	_group_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_picker.tooltip_text = "选择要操作的一组"
	_group_picker.item_selected.connect(_on_group_selected)
	add_child(_group_picker)

	_summary = UIControlParts.label()
	_summary.name = "Summary"
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_summary.add_theme_font_size_override("font_size", 12)
	_summary.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
	_summary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_summary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_child(_summary)

	_mode_picker = UIControlParts.option_button()
	_mode_picker.name = "Mode"
	_mode_picker.custom_minimum_size = Vector2(72.0, 30.0)
	_mode_picker.add_item("%", MODE_PERCENT)
	_mode_picker.add_icon_item(MoneyDisplay.MENU_ICON, "定额", MODE_ABSOLUTE)
	_mode_picker.select(MODE_PERCENT)
	_mode_picker.set_item_disabled(1, true)
	_mode_picker.set_item_tooltip(1, ABSOLUTE_DISABLED_REASON)
	_mode_picker.tooltip_text = ABSOLUTE_DISABLED_REASON
	add_child(_mode_picker)

	_rate_spin = RateFieldScene.instantiate() as SpinBox
	_rate_spin.name = "Rate"
	_rate_spin.custom_minimum_size = Vector2(92.0, 30.0)
	_rate_spin.min_value = PERCENT_MIN
	_rate_spin.max_value = PERCENT_MAX
	_rate_spin.step = 0.01
	_rate_spin.suffix = "%"
	_rate_spin.allow_greater = false
	_rate_spin.allow_lesser = false
	_rate_spin.tooltip_text = "整组统一设成这个税率"
	_rate_spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_rate_spin)

	_apply_button = UIControlParts.button()
	_apply_button.name = "Apply"
	_apply_button.text = "整组设为"
	_apply_button.custom_minimum_size = Vector2(92.0, 30.0)
	_apply_button.disabled = true
	_apply_button.tooltip_text = "把当前组的全部税档一次设成左边这个税率"
	_apply_button.pressed.connect(_on_apply_pressed)
	add_child(_apply_button)

	_collapse_button = UIControlParts.button()
	_collapse_button.name = "Collapse"
	_collapse_button.text = "收起明细"
	_collapse_button.custom_minimum_size = Vector2(96.0, 30.0)
	_collapse_button.toggle_mode = true
	_collapse_button.tooltip_text = "只留分组条，把每张卡片收起来"
	_collapse_button.toggled.connect(_on_collapse_toggled)
	add_child(_collapse_button)


## 分组轴：`axes` 是 [{id, label, hint}]，顺序即下拉顺序。
func configure(axes: Array) -> void:
	_axes = axes.duplicate(true)
	var previous := current_axis_id()
	_axis_picker.clear()
	for axis_value in _axes:
		var axis: Dictionary = axis_value
		_axis_picker.add_item(String(axis.get("label", "")))
		_axis_picker.set_item_tooltip(_axis_picker.item_count - 1,
			String(axis.get("hint", "")))
	var keep := 0
	for index in range(_axes.size()):
		if String((_axes[index] as Dictionary).get("id", "")) == previous:
			keep = index
			break
	if _axis_picker.item_count > 0:
		_axis_picker.select(keep)
	_axis_picker.disabled = _axes.is_empty()


## 组列表：`groups` 是 [{id, label, item_ids, overridden, count}]。
## `editable` 为假时整组设值整块禁用，`reason` 说明为什么。
func set_groups(groups: Array, editable: bool, reason: String = "") -> void:
	_editable = editable
	_groups = groups.duplicate(true)
	var previous := current_group_id()
	_applying = true
	_group_picker.clear()
	for group_value in _groups:
		var group: Dictionary = group_value
		_group_picker.add_item(String(group.get("label", "")))
		_group_picker.set_item_tooltip(_group_picker.item_count - 1,
			"这一组 %d 项" % int(group.get("count", 0)))
	_applying = false
	var keep := 0
	for index in range(_groups.size()):
		if String((_groups[index] as Dictionary).get("id", "")) == previous:
			keep = index
			break
	if _group_picker.item_count > 0:
		_group_picker.select(keep)
	_group_picker.disabled = _groups.is_empty() or _busy
	_refresh_summary()
	_refresh_apply_state(reason)


func set_busy(busy: bool) -> void:
	_busy = busy
	_refresh_apply_state()


func set_collapsed(value: bool) -> void:
	if _collapsed == value:
		_refresh_collapse_text()
		return
	_collapsed = value
	_collapse_button.set_pressed_no_signal(_collapsed)
	_refresh_collapse_text()


func is_collapsed() -> bool:
	return _collapsed


func current_axis_id() -> String:
	if _axes.is_empty() or _axis_picker == null:
		return ""
	var index := _axis_picker.selected
	if index < 0 or index >= _axes.size():
		return ""
	return String((_axes[index] as Dictionary).get("id", ""))


func current_group_id() -> String:
	if _groups.is_empty() or _group_picker == null:
		return ""
	var index := _group_picker.selected
	if index < 0 or index >= _groups.size():
		return ""
	return String((_groups[index] as Dictionary).get("id", ""))


func current_group_label() -> String:
	if _groups.is_empty() or _group_picker == null:
		return ""
	var index := _group_picker.selected
	if index < 0 or index >= _groups.size():
		return ""
	return String((_groups[index] as Dictionary).get("label", ""))


## 当前组包含的 item_id。空数组表示「没有可操作的组」。
func selected_item_ids() -> PackedStringArray:
	var index := _group_picker.selected if _group_picker != null else -1
	if index < 0 or index >= _groups.size():
		return PackedStringArray()
	var raw: Variant = (_groups[index] as Dictionary).get("item_ids",
		PackedStringArray())
	if raw is PackedStringArray:
		return raw
	return PackedStringArray(raw)


## 当前组的项数（给宿主做「单行」判断）。
func selected_count() -> int:
	var index := _group_picker.selected if _group_picker != null else -1
	if index < 0 or index >= _groups.size():
		return 0
	return int((_groups[index] as Dictionary).get("count", 0))


func rate_basis_points() -> int:
	var percent := float(_rate_spin.value)
	return clampi(int(round(percent * 100.0)), RATE_MIN_BP, RATE_MAX_BP)


func set_rate_basis_points(basis_points: int) -> void:
	_rate_spin.set_value_no_signal(clampf(
		float(basis_points) / 100.0, PERCENT_MIN, PERCENT_MAX))


func _refresh_summary() -> void:
	var index := _group_picker.selected if _group_picker != null else -1
	if index < 0 or index >= _groups.size():
		_summary.text = "无可分组的项"
		return
	var group: Dictionary = _groups[index]
	var count := int(group.get("count", 0))
	var overridden := int(group.get("overridden", 0))
	_summary.text = "共 %d 项 · 已覆盖 %d 项" % [count, overridden]


func _refresh_apply_state(reason: String = "") -> void:
	var has_group := not _groups.is_empty() and _group_picker.selected >= 0
	var single := selected_count() <= 1
	_apply_button.disabled = not has_group or _busy or not _editable or single
	if not _editable:
		var blocked := reason
		if blocked.is_empty():
			blocked = "当前政策不可改。"
		_apply_button.tooltip_text = blocked
	elif single:
		_apply_button.tooltip_text = "这一组只有 1 项，直接改那一行即可。"
	elif _busy:
		_apply_button.tooltip_text = "上一批还在提交，稍候。"
	else:
		_apply_button.tooltip_text = "把当前组的全部税档一次设成左边这个税率"
	_rate_spin.editable = _editable and has_group and not _busy
	_rate_spin.tooltip_text = "整组统一设成这个税率"
	if not _editable:
		_rate_spin.tooltip_text = _apply_button.tooltip_text
	_mode_picker.disabled = not (_editable and has_group and not _busy)


func _refresh_collapse_text() -> void:
	_collapse_button.text = "展开明细" if _collapsed else "收起明细"


func _on_axis_selected(_index: int) -> void:
	if _applying:
		return
	axis_changed.emit(current_axis_id())


func _on_group_selected(_index: int) -> void:
	if _applying:
		return
	_refresh_summary()
	_refresh_apply_state()
	group_changed.emit(current_group_id())


func _on_apply_pressed() -> void:
	if _busy or not _editable:
		return
	var ids := selected_item_ids()
	if ids.is_empty():
		return
	apply_requested.emit(rate_basis_points(), ids)


func _on_collapse_toggled(pressed: bool) -> void:
	_collapsed = pressed
	_refresh_collapse_text()
	collapse_toggled.emit(_collapsed)
