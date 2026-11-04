extends PanelContainer
class_name BuildingHoverCard

## 建筑目录的结构化悬停卡。
##
## 原先把整份报价塞进 `tooltip_text`，用户只能在一段长句里找数字。这里把同一份
## view model 输出拆成身份、三项关键数字、岗位/生产、建材与状态五个视觉层级。
## 卡片只读 row data，不重新查询经济或市场，避免 hover 触发模拟侧工作。

const EDGE_MARGIN := 8.0
const POINTER_GAP := 12.0
const CARD_MAX_HEIGHT := 520.0
const CARD_WIDTH := 500.0

@onready var _icon: IconBadge = $Body/Header/Icon
@onready var _title: Label = $Body/Header/Identity/Title
@onready var _subtitle: Label = $Body/Header/Identity/Subtitle
@onready var _status: Label = $Body/Header/Status
@onready var _cost: Label = $Body/Stats/Cost/Text/Value
@onready var _duration: Label = $Body/Stats/Duration/Text/Value
@onready var _profit: Label = $Body/Stats/Profit/Text/Value
@onready var _employment: PanelContainer = $Body/Sections/Employment
@onready var _employment_text: Label = $Body/Sections/Employment/Text
@onready var _flow: PanelContainer = $Body/Sections/Flow
@onready var _flow_text: Label = $Body/Sections/Flow/Text
@onready var _materials: PanelContainer = $Body/Sections/Materials
@onready var _materials_text: Label = $Body/Sections/Materials/Text
@onready var _summary: Label = $Body/Summary

var _source: Control
var _workspace: Control
var _payload: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	custom_minimum_size.x = CARD_WIDTH
	size = Vector2(CARD_WIDTH, 0.0)
	_process_mode_always()


func _process_mode_always() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func show_for(row: Dictionary, source: Control, workspace: Control) -> void:
	_payload = row.duplicate(true)
	_source = source
	_workspace = workspace
	_apply_payload()
	visible = true
	modulate.a = 0.0
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "modulate:a", 1.0, 0.12)
	call_deferred("_place_card")
	call_deferred("_fit_card")


func hide_card() -> void:
	_source = null
	_workspace = null
	_payload.clear()
	visible = false


func refresh(row: Dictionary) -> void:
	_payload = row.duplicate(true)
	if visible:
		_apply_payload()
		call_deferred("_place_card")
		call_deferred("_fit_card")


func _fit_card() -> void:
	if not visible:
		return
	# 首次写入长文本时，Label 的自动换行需要先拿到容器宽度；下一帧再收紧
	# 高度，避免 PanelContainer 把「窄宽度下的巨大最小高度」永久保留下来。
	size.y = clampf(get_combined_minimum_size().y, 160.0, CARD_MAX_HEIGHT)
	_place_card()


func _apply_payload() -> void:
	var name := String(_payload.get("name", "建筑"))
	var icon := StringName(_payload.get("icon", &"economy.building"))
	var eligible := bool(_payload.get("eligible", false))
	_icon.set_semantic(icon, UITokens.DOSSIER_BRASS if eligible else UITokens.DOSSIER_UMBER)
	_title.text = name
	_subtitle.text = _subtitle_text()
	_status.text = "可营造" if eligible else String(_payload.get("reason_text", "暂不可营造"))
	_status.add_theme_color_override("font_color",
		UITokens.DOSSIER_VERDIGRIS if eligible else UITokens.DOSSIER_OXBLOOD)
	_cost.text = String(_payload.get("cash_text", "—"))
	var days := int(_payload.get("days", 0))
	_duration.text = "%d 日" % days if days > 0 else "—"
	var score := int(_payload.get("score", 0))
	_profit.text = _money_text(score) if score != 0 else "—"
	_profit.add_theme_color_override("font_color", _profit_color())

	var lines := _tooltip_lines()
	var employment := _lines_with_prefix(lines, "岗位：")
	var inputs := _lines_with_prefix(lines, "投入：")
	var outputs := _lines_with_prefix(lines, "产出：")
	var material_lines := _lines_with_prefix(lines, "建材：")
	var stock_lines := _lines_with_prefix(lines, "现货：")
	var flow_lines := PackedStringArray()
	for line in inputs + outputs:
		flow_lines.append(line)
	_set_section(_employment, _employment_text, employment,
		"♟  岗位配置\n%s" % "\n".join(employment))
	_set_section(_flow, _flow_text, flow_lines,
		"↗  生产链路\n%s" % "\n".join(flow_lines))
	var material_all := material_lines + stock_lines
	_set_section(_materials, _materials_text, material_all,
		"▣  营造资源\n%s" % "\n".join(material_all))
	var facts := _lines_with_prefix(lines, "概况：")
	var reason := _lines_with_prefix(lines, "不满足：")
	var summary_parts := PackedStringArray()
	for item in facts + reason:
		summary_parts.append(item)
	_summary.text = " · ".join(summary_parts)
	_summary.visible = not summary_parts.is_empty()
	_summary.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if not reason.is_empty() else UITokens.DOSSIER_INK_MUTED)


func _subtitle_text() -> String:
	var role := String(_payload.get("role_label", ""))
	var tier := int(_payload.get("tier", -1))
	if not role.is_empty() and tier >= 0:
		return "%s · 第 %d 档" % [role, tier + 1]
	if not role.is_empty():
		return role
	return "生产与营造报价"


func _tooltip_lines() -> PackedStringArray:
	var raw := String(_payload.get("tooltip", ""))
	var result := PackedStringArray()
	for line in raw.split("\n"):
		var clean := String(line).strip_edges()
		if not clean.is_empty() and not clean == String(_payload.get("name", "")):
			result.append(clean)
	return result


func _lines_with_prefix(lines: PackedStringArray, prefix: String) -> PackedStringArray:
	var result := PackedStringArray()
	for line in lines:
		if line.begins_with(prefix):
			result.append(line.trim_prefix(prefix).strip_edges())
	return result


func _set_section(panel: PanelContainer, label: Label, lines: PackedStringArray,
		value: String) -> void:
	panel.visible = not lines.is_empty()
	if panel.visible:
		label.text = value


func _profit_color() -> Color:
	var value := _profit.text.replace("+", "").replace("−", "-")
	if value.begins_with("-"):
		return UITokens.DOSSIER_OXBLOOD
	if value == "—" or value.is_empty():
		return UITokens.DOSSIER_INK_SOFT
	return UITokens.DOSSIER_VERDIGRIS


func _money_text(value: int) -> String:
	if value == 0:
		return "—"
	var sign := "+" if value > 0 else ""
	return "%s%s" % [sign, UITokens.format_compact_number_cn(float(value) / 10000.0, 2)]


func _place_card() -> void:
	if not visible or _source == null or _workspace == null \
			or not is_instance_valid(_source) or not is_instance_valid(_workspace):
		return
	var viewport := get_viewport_rect().size
	var safe := Rect2(Vector2(EDGE_MARGIN, EDGE_MARGIN),
		viewport - Vector2(EDGE_MARGIN * 2.0, EDGE_MARGIN * 2.0))
	# 普通地块档案的详情列只有约 424px；卡片在宽屏时可展开，窄栏时
	# 自动收窄，避免被 DetailShell 的 clip_contents 截掉右侧数字。
	var available_width := maxf(320.0, _workspace.size.x - EDGE_MARGIN * 2.0)
	var desired_width := minf(CARD_WIDTH, available_width)
	custom_minimum_size.x = desired_width
	size.x = desired_width
	var source_rect := Rect2(_source.get_global_position(), _source.size)
	var card_size := size
	if card_size.x <= 0.0:
		card_size.x = CARD_WIDTH
	card_size.y = minf(maxf(card_size.y, 160.0), CARD_MAX_HEIGHT)
	var pointer := get_viewport().get_mouse_position()
	var pos := pointer + Vector2(POINTER_GAP, POINTER_GAP)
	if pos.x + card_size.x > safe.end.x:
		pos.x = source_rect.position.x - card_size.x - POINTER_GAP
	if pos.y + card_size.y > safe.end.y:
		pos.y = source_rect.position.y + source_rect.size.y - card_size.y
	pos.x = clampf(pos.x, safe.position.x, maxf(safe.position.x, safe.end.x - card_size.x))
	pos.y = clampf(pos.y, safe.position.y, maxf(safe.position.y, safe.end.y - card_size.y))
	global_position = pos
