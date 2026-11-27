extends PanelContainer

## 地块档案「军事」页的一整张撕纸台账（见 docs/ui/military-cell-tab.md）。
##
## 自上而下：驻军条 → 编成部队 → 当地部队（点行开军务档案）→ 本地训练 → 建筑行。
## 数据全部由 CellInspectorViewModel 组好（`military_cell`），这里只画和发请求：
## 不查原生、不做规则判断、不写解释性文案。
##
## 节点恒定：三个建筑行在 _ready() 建好，之后只改值与可见性；同一身份重复
## set_model 不改变节点数（地块档案每日补丁因为结构未变走这条路径）。

signal army_selected(handle: int)
signal army_create_requested(request: Dictionary)
signal action_requested(request: Dictionary)

const RosterListScript := preload("res://scripts/ui/components/military/military_roster_list.gd")
const BuildingRowScript := preload("res://scripts/ui/components/military/military_building_row.gd")
const ROW_COUNT := 3
## 视图模型的主键动作 → 正式军事命令。主键语义恒定：只会是这三个正向动作。
const ACTION_OPS := {
	"build": "state.build",
	"upgrade": "state.build",
	"rebuild": "state.build",
	"demolish": "state.demolish",
}

@onready var _garrison: Control = %GarrisonStrip
@onready var _troops_tag: Label = %TroopsTag
@onready var _troops: Control = %TroopList
@onready var _training_tag: Label = %TrainingTag
@onready var _training: Control = %TrainingList
@onready var _buildings_tag: Label = %BuildingsTag
@onready var _create_army: Button = %CreateArmy
@onready var _army_feedback: Label = %ArmyFeedback
@onready var _rows_box: VBoxContainer = %Rows
@onready var _building_hover: BuildingHoverCard = %BuildingHover

var _model: Dictionary = {}
var _cell := -1
var _rows: Array = []
var _preview_index := -1
var _preview_demolition := false
var _preview_payload: Dictionary = {}
var _preview_boundary: Control
## 最近一次按下动作键的行：命令回执写在这一行上（成功与被拒都写）。
## 只在按下时更新，模型落地不改写——回执的存活时间由行自己按秒计。
var _action_index := -1


func _ready() -> void:
	if _garrison == null or _troops == null or _training == null or _rows_box == null:
		push_error("MilitaryCellLedger 必须通过 military_cell_ledger.tscn 实例化。")
		return
	_build_rows()
	visibility_changed.connect(_on_preview_visibility_changed)
	var ancestor := get_parent()
	while ancestor != null and not ancestor is ScrollContainer:
		ancestor = ancestor.get_parent()
	if ancestor is ScrollContainer:
		ancestor.get_v_scroll_bar().value_changed.connect(_on_preview_scroll)
	IconButton.apply_with_text(_create_army, &"military.banner", "编成部队",
		IconButton.SMALL, "把本格驻军编成一支野战部队")
	_create_army.focus_mode = Control.FOCUS_ALL
	_create_army.custom_minimum_size = Vector2(_create_army.custom_minimum_size.x, 38.0)
	_apply_create_army_style(_create_army)
	UIAnimation.bind_tactile_button(_create_army)
	_troops.army_selected.connect(func(handle: int) -> void:
		army_selected.emit(handle))
	if _create_army != null:
		_create_army.pressed.connect(_on_create_army_pressed)
	if not _model.is_empty():
		_apply_model()


func _build_rows() -> void:
	if _rows_box == null or not _rows.is_empty():
		return
	# 三行之间不再插分隔线：每行自己画一条手绘底线就够了，两套线叠在一起会显得碎。
	for index in range(ROW_COUNT):
		var row := BuildingRowScript.new()
		row.name = "Row%d" % index
		_rows_box.add_child(row)
		row.action_pressed.connect(_on_row_action.bind(index))
		row.demolish_pressed.connect(_on_row_demolish.bind(index))
		row.preview_changed.connect(_on_row_preview.bind(index))
		_rows.append(row)


func set_model(model: Dictionary) -> void:
	_model = model
	if _cell != int(model.get("cell", -1)):
		_clear_preview()
	_cell = int(model.get("cell", -1))
	if is_node_ready() and _rows_box != null:
		_apply_model()


func set_preview_boundary(boundary: Control) -> void:
	_preview_boundary = boundary


func _apply_model() -> void:
	if _garrison != null:
		_garrison.set_data(_model.get("garrison", {}))
	var army_create: Dictionary = _model.get("army_create", {})
	if _create_army != null:
		var enabled := bool(army_create.get("enabled", false))
		var heads := int(army_create.get("heads", 0))
		_create_army.disabled = not enabled
		_create_army.text = ("编成部队 · %s 人" % UITokens.format_compact_number_cn(
			float(heads), 1)) if heads > 0 else "暂无可编成驻军"
	if _troops != null:
		var troops: Array = _model.get("troops", [])
		_troops.set_rows(troops)
		if _troops_tag != null:
			_troops_tag.visible = not troops.is_empty()
	if _training != null:
		var training: Array = _model.get("training", [])
		_training.set_rows(training)
		if _training_tag != null:
			_training_tag.visible = not training.is_empty()
	var buildings: Array = _model.get("buildings", [])
	if _buildings_tag != null:
		_buildings_tag.visible = not buildings.is_empty()
	for index in range(_rows.size()):
		var entry: Dictionary = {}
		if index < buildings.size() and buildings[index] is Dictionary:
			entry = buildings[index]
		(_rows[index] as Control).set_data(entry)
	_refresh_preview()


func _on_row_preview(show: bool, demolition: bool, index: int) -> void:
	if not show:
		if index == _preview_index:
			_clear_preview()
		return
	if not is_visible_in_tree():
		return
	var same_row := index == _preview_index and demolition == _preview_demolition
	_preview_index = index
	_preview_demolition = demolition
	_refresh_preview(not same_row)


func _refresh_preview(reopen: bool = false) -> void:
	if _preview_index < 0:
		return
	var row: Control = _rows[_preview_index]
	var payload: Dictionary = row.preview_data(_preview_demolition)
	if payload.is_empty():
		_clear_preview()
	elif reopen or not _building_hover.visible:
		_preview_payload = payload
		_building_hover.show_for(payload, row, _preview_boundary if is_instance_valid(_preview_boundary) else self, true)
	elif payload != _preview_payload:
		_preview_payload = payload
		_building_hover.refresh(payload)


func _clear_preview() -> void:
	_preview_index = -1
	_preview_payload = {}
	if _building_hover != null:
		_building_hover.hide_card()


func _on_preview_visibility_changed() -> void:
	if not is_visible_in_tree():
		_clear_preview()


func _on_preview_scroll(_value: float) -> void:
	_clear_preview()


func cell_index() -> int:
	return _cell


func building_rows() -> Array:
	return _rows


## 命令被拒时解锁对应动作键：成功的建筑命令保留禁用，直到模型画出「在建」。
func release_busy() -> void:
	for row in _rows:
		(row as Control).set_busy(false)
	if _create_army != null:
		var army_create: Dictionary = _model.get("army_create", {})
		_create_army.disabled = not bool(army_create.get("enabled", false))


## 命令回执（成功=已排队 / 失败=被拒的理由）写在刚按下的那一行上。
## 营造反馈条只在营造窗口里可见，地块档案这一页必须自己给回音，否则按钮像坏了。
func show_feedback(message: String, ok: bool) -> void:
	if _action_index < 0 or _action_index >= _rows.size():
		return
	(_rows[_action_index] as Control).flash_notice(message, ok)


func show_army_feedback(message: String, ok: bool) -> void:
	if _army_feedback == null:
		return
	_army_feedback.text = message
	_army_feedback.add_theme_color_override("font_color",
		UITokens.DOSSIER_VERDIGRIS if ok else UITokens.DOSSIER_OXBLOOD)
	_army_feedback.visible = not message.is_empty()


func feedback_text() -> String:
	if _action_index < 0 or _action_index >= _rows.size():
		return ""
	return String((_rows[_action_index] as Control).notice_text())


func _on_row_action(index: int) -> void:
	var buildings: Array = _model.get("buildings", [])
	if index < 0 or index >= buildings.size():
		return
	var entry: Dictionary = buildings[index]
	# 主键只走正向动作：视图模型的 primary_action 只会是 build / upgrade / rebuild。
	var primary := String(entry.get("primary_action", "none"))
	var op := String(ACTION_OPS.get(primary, "")) if primary != "none" \
		else String(ACTION_OPS.get(String(entry.get("action", "")), ""))
	var target := int(entry.get("target", -1))
	if op.is_empty() or target < 0 or _cell < 0:
		return
	_action_index = index
	(_rows[index] as Control).set_busy(true)
	action_requested.emit({
		"cell": _cell,
		"role": String(entry.get("role", "")),
		"op": op,
		"building": target,
	})


## 拆除是独立通道：它的目标必须是**已建成的那一档**，不是主键的 target
## （主键在可升级时指向更高档，拿它去拆会拆错建筑）。
func _on_row_demolish(index: int) -> void:
	var buildings: Array = _model.get("buildings", [])
	if index < 0 or index >= buildings.size():
		return
	var entry: Dictionary = buildings[index]
	if not bool(entry.get("can_demolish", false)):
		return
	var target := int(entry.get("demolish_target", -1))
	if target < 0 or _cell < 0:
		return
	_action_index = index
	(_rows[index] as Control).set_busy(true)
	action_requested.emit({
		"cell": _cell,
		"role": String(entry.get("role", "")),
		"op": String(ACTION_OPS.get("demolish", "state.demolish")),
		"building": target,
	})


func _on_create_army_pressed() -> void:
	var army_create: Dictionary = _model.get("army_create", {})
	if not bool(army_create.get("enabled", false)):
		return
	_create_army.disabled = true
	army_create_requested.emit({
		"cell": _cell,
		"units": army_create.get("units", {}),
	})


func _apply_create_army_style(button: Button) -> void:
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.955, 0.915, 0.825, 0.94)
	normal.border_color = Color(UITokens.DOSSIER_BRASS, 0.8)
	normal.set_border_width_all(1)
	normal.border_width_bottom = 2
	normal.set_corner_radius_all(4)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.98, 0.945, 0.865, 1.0)
	hover.border_color = UITokens.DOSSIER_BRASS
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.89, 0.81, 0.67, 1.0)
	pressed.border_color = UITokens.DOSSIER_OXBLOOD
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.92, 0.89, 0.82, 0.55)
	disabled.border_color = Color(UITokens.DOSSIER_RULE, 0.38)
	disabled.border_width_bottom = 1
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("focus", hover)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	button.add_theme_color_override("font_hover_color", UITokens.DOSSIER_OXBLOOD)
	button.add_theme_color_override("font_pressed_color", UITokens.DOSSIER_OXBLOOD)
	button.add_theme_color_override("font_disabled_color", Color(UITokens.DOSSIER_INK_MUTED, 0.65))
