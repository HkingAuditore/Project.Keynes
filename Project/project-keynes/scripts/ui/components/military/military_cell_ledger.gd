extends PanelContainer

## 地块档案「军事」页的一整张撕纸台账（见 docs/ui/military-cell-tab.md）。
##
## 自上而下：驻军条 → 当地部队（点行开军务档案）→ 本地训练 → 手绘分隔 → 三行官营建筑。
## 数据全部由 CellInspectorViewModel 组好（`military_cell`），这里只画和发请求：
## 不查原生、不做规则判断、不写解释性文案。
##
## 节点恒定：三个建筑行在 _ready() 建好，之后只改值与可见性；同一身份重复
## set_model 不改变节点数（地块档案每日补丁因为结构未变走这条路径）。

signal army_selected(handle: int)
signal action_requested(request: Dictionary)

const RosterListScript := preload("res://scripts/ui/components/military/military_roster_list.gd")
const BuildingRowScript := preload("res://scripts/ui/components/military/military_building_row.gd")
const ROW_COUNT := 3
## 视图模型的动作 → 正式军事命令。
const ACTION_OPS := {
	"build": "state.build",
	"upgrade": "state.build",
	"demolish": "state.demolish",
}

@onready var _garrison: Control = %GarrisonStrip
@onready var _troops: Control = %TroopList
@onready var _training: Control = %TrainingList
@onready var _rows_box: VBoxContainer = %Rows

var _model: Dictionary = {}
var _cell := -1
var _rows: Array = []


func _ready() -> void:
	if _garrison == null or _troops == null or _training == null or _rows_box == null:
		push_error("MilitaryCellLedger 必须通过 military_cell_ledger.tscn 实例化。")
		return
	_build_rows()
	_troops.army_selected.connect(func(handle: int) -> void:
		army_selected.emit(handle))
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
		_rows.append(row)


func set_model(model: Dictionary) -> void:
	_model = model
	_cell = int(model.get("cell", -1))
	if is_node_ready() and _rows_box != null:
		_apply_model()


func _apply_model() -> void:
	if _garrison != null:
		_garrison.set_data(_model.get("garrison", {}))
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


## 命令被拒（科技/领土/资金）时解锁动作键：成功的命令保留禁用，直到模型画出「在建」。
func release_busy() -> void:
	for row in _rows:
		(row as Control).set_busy(false)


func _on_row_action(index: int) -> void:
	var buildings: Array = _model.get("buildings", [])
	if index < 0 or index >= buildings.size():
		return
	var entry: Dictionary = buildings[index]
	var op := String(ACTION_OPS.get(String(entry.get("action", "")), ""))
	var target := int(entry.get("target", -1))
	if op.is_empty() or target < 0 or _cell < 0:
		return
	(_rows[index] as Control).set_busy(true)
	action_requested.emit({
		"cell": _cell,
		"role": String(entry.get("role", "")),
		"op": op,
		"building": target,
	})
