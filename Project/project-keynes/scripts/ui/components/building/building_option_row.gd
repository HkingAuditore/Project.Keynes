extends PanelContainer
class_name BuildingOptionRow

## 营造目录的一行：剪纸建筑徽记 + 名称 + 成本 + 「营造」按钮。
##
## 按钮的可用性就是「这一项现在能不能建」的唯一表达：可用是深胭脂纸钮，
## 不可用是浅纸 + 弱墨字；不可建时行内再写一句短因由（缺建材 / 资金不足 …）。
## 全部细节（逐项建材、国库与市购拆分、单价、工期、岗位、配方）走 hover 提示，
## 让单一界面保持简短。
##
## 节点全部来自 building_option_row.tscn；本脚本只写值。

signal build_requested(building_id: StringName)
signal hover_started(row: Dictionary, source: Control)
signal hover_ended()

const CASH_FONT_SIZE := 17
const PENDING_TEXT := "营造中…"

var building_id := ""
var _row_data: Dictionary = {}

var _blocked := false
var _pending := false

@onready var _icon: IconBadge = $Row/Icon
@onready var _name: Label = $Row/Info/Name
@onready var _meta: Label = $Row/Info/Meta
@onready var _cash_row: Control = $Row/CashRow
@onready var _cash_icon: TextureRect = $Row/CashRow/CashIcon
@onready var _cash: Label = $Row/CashRow/Cash
@onready var _build: Button = $Row/BuildButton


func _ready() -> void:
	if _build.pressed.is_connected(_on_build_pressed):
		return
	MoneyDisplay.apply_icon(_cash_icon, CASH_FONT_SIZE)
	_build.pressed.connect(_on_build_pressed)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	_apply_button_state()


func set_row(row: Dictionary, pending: bool = false) -> void:
	if _build == null:
		_ready()
	_row_data = row.duplicate(true)
	building_id = String(row.get("building_id", ""))
	_blocked = not bool(row.get("eligible", false))
	_pending = pending and not _blocked
	_icon.set_semantic(StringName(row.get("icon", &"economy.building")),
		UITokens.DOSSIER_UMBER if _blocked else UITokens.DOSSIER_INK_SOFT)
	_name.text = String(row.get("name", "建筑"))
	_name.tooltip_text = _name.text
	_meta.text = meta_text(row)
	_meta.tooltip_text = _meta.text
	_meta.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if _blocked else UITokens.DOSSIER_INK_MUTED)
	var cash := int(row.get("cash_required", 0))
	_cash_row.visible = cash > 0
	_cash.text = String(row.get("cash_text", ""))
	# 详情由 BuildingHoverCard 承担；清空原生 tooltip，避免两张卡重叠。
	tooltip_text = ""
	_build.tooltip_text = String(row.get("reason_text", "")) if _blocked \
		else "从国库与本地市场备料，营造一座%s" % _name.text
	_apply_button_state()


func set_pending(pending: bool) -> void:
	if _pending == pending:
		return
	_pending = pending
	_apply_button_state()


func is_pending() -> bool:
	return _pending


## 行内文字：不可建时先说因由，再说成本——玩家一眼看到「为什么点不动」。
static func meta_text(row: Dictionary) -> String:
	var materials := String(row.get("materials_text", "")).strip_edges()
	var reason := String(row.get("reason_text", "")).strip_edges()
	if reason.is_empty():
		return materials
	if materials.is_empty():
		return reason
	return "%s · %s" % [reason, materials]


func _apply_button_state() -> void:
	if _build == null:
		return
	_build.text = PENDING_TEXT if _pending else "营造"
	_build.disabled = _blocked or _pending


func _on_build_pressed() -> void:
	if _blocked or _pending or building_id.is_empty():
		return
	set_pending(true)
	build_requested.emit(StringName(building_id))


func _on_mouse_entered() -> void:
	if not _row_data.is_empty():
		hover_started.emit(_row_data, self)


func _on_mouse_exited() -> void:
	hover_ended.emit()
