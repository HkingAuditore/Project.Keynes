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
@onready var _troops: Control = %TroopList
@onready var _training: Control = %TrainingList
@onready var _create_army: Button = %CreateArmy
@onready var _army_feedback: Label = %ArmyFeedback
@onready var _rows_box: VBoxContainer = %Rows

var _model: Dictionary = {}
var _cell := -1
var _rows: Array = []
## 最近一次按下动作键的行：命令回执写在这一行上（成功与被拒都写）。
## 只在按下时更新，模型落地不改写——回执的存活时间由行自己按秒计。
var _action_index := -1


func _ready() -> void:
	if _garrison == null or _troops == null or _training == null or _rows_box == null:
		push_error("MilitaryCellLedger 必须通过 military_cell_ledger.tscn 实例化。")
		return
	_build_rows()
	IconButton.apply_with_text(_create_army, &"military.banner", "编成部队",
		IconButton.SMALL, "把本格驻军编成一支野战部队")
	_create_army.focus_mode = Control.FOCUS_ALL
	_create_army.custom_minimum_size = Vector2(_create_army.custom_minimum_size.x, 44.0)
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
		_rows.append(row)


func set_model(model: Dictionary) -> void:
	_model = model
	_cell = int(model.get("cell", -1))
	if is_node_ready() and _rows_box != null:
		_apply_model()


func _apply_model() -> void:
	if _garrison != null:
		_garrison.set_data(_model.get("garrison", {}))
	var army_create: Dictionary = _model.get("army_create", {})
	if _create_army != null:
		_create_army.disabled = not bool(army_create.get("enabled", false))
		_create_army.text = "编成部队 · %s 人" % UITokens.format_compact_number_cn(
			float(army_create.get("heads", 0)), 1)
	if _troops != null:
		_troops.set_rows(_model.get("troops", []))
	if _training != null:
		_training.set_rows(_model.get("training", []))
	var buildings: Array = _model.get("buildings", [])
	for index in range(_rows.size()):
		var entry: Dictionary = {}
		if index < buildings.size() and buildings[index] is Dictionary:
			entry = buildings[index]
		(_rows[index] as Control).set_data(entry)


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
