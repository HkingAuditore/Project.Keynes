extends PanelContainer
class_name BuildingOptionRow

## 营造目录的一行，显示每栋建材、现金支出和停用原因。

signal build_requested(building_id: StringName)
signal hover_started(row: Dictionary, source: Control)
signal hover_ended()

const CASH_FONT_SIZE := 17
const PENDING_TEXT := "营造中…"

var building_id := ""
var _row_data: Dictionary = {}

var _blocked := false
var _pending := false

@onready var _icon: IconBadge = $Row/Info/Summary/Icon
@onready var _name: Label = $Row/Info/Summary/Name
@onready var _meta: Label = $Row/Info/Meta
@onready var _cash_row: Control = $Row/Info/Summary/CashRow
@onready var _cash_icon: TextureRect = $Row/Info/Summary/CashRow/CashIcon
@onready var _cash: Label = $Row/Info/Summary/CashRow/Cash
@onready var _build: Button = %BuildButton
@onready var _materials: VBoxContainer = $Row/Materials
@onready var _material_list = $Row/Materials/List


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
	var materials: Array = row.get("material_status", [])
	var quoted: Array = materials.filter(func(material: Dictionary) -> bool:
		return material.has("text"))
	_material_list.set_rows(quoted, false)
	_materials.visible = not quoted.is_empty()
	_meta.text = meta_text(row, _materials.visible)
	_meta.visible = not _meta.text.is_empty()
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
static func meta_text(row: Dictionary, has_material_rows: bool = false) -> String:
	var materials := "" if has_material_rows else String(row.get("materials_text", "")).strip_edges()
	if not materials.is_empty():
		materials = "每栋建材 %s" % materials
	elif bool(row.get("material_free", false)):
		materials = "不耗建材"
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
