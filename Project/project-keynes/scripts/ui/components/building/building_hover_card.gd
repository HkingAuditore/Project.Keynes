extends PanelContainer
class_name BuildingHoverCard

## 建筑目录的结构化悬停卡。
##
## 原先把整份报价塞进 `tooltip_text`，用户只能在一段长句里找数字。这里把同一份
## view model 输出拆成身份、三项关键数字、岗位/生产、建材与状态五个视觉层级。
## 卡片只读 row data，不重新查询经济或市场，避免 hover 触发模拟侧工作。

const EDGE_MARGIN := 8.0
const POINTER_GAP := 12.0
const CARD_WIDTH := 440.0

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
@onready var _materials_text: Label = $Body/Sections/Materials/Content/Text
@onready var _material_rows: VBoxContainer = $Body/Sections/Materials/Content/Rows
@onready var _summary: Label = $Body/Summary

var _source: Control
var _workspace: Control
var _payload: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
	visible = false
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	custom_minimum_size.x = CARD_WIDTH
	size = Vector2(CARD_WIDTH, 0.0)
	minimum_size_changed.connect(_fit_card, CONNECT_DEFERRED)
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
	_fit_after_layout()


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
		_fit_after_layout()


func _fit_after_layout() -> void:
	await get_tree().process_frame
	_fit_card()


func _fit_card() -> void:
	if not visible:
		return
	# 首次写入长文本时，Label 的自动换行需要先拿到容器宽度；下一帧再收紧
	# 高度，避免 PanelContainer 把「窄宽度下的巨大最小高度」永久保留下来。
	size.y = get_combined_minimum_size().y
	_place_card()


func _apply_payload() -> void:
	var name := String(_payload.get("name", "建筑"))
	var icon := StringName(_payload.get("icon", &"economy.building"))
	var eligible := bool(_payload.get("eligible", false))
	_icon.set_semantic(icon, UITokens.DOSSIER_BRASS if eligible else UITokens.DOSSIER_UMBER)
	_title.text = name
	_status.text = "可营造" if eligible else "暂不可营造"
	_status.add_theme_font_size_override("font_size", 15)
	_status.add_theme_color_override("font_color",
		UITokens.DOSSIER_VERDIGRIS if eligible else UITokens.DOSSIER_OXBLOOD)
	_cost.text = String(_payload.get("cash_text", "—"))
	var days := int(_payload.get("days", 0))
	_duration.get_parent().get_parent().visible = days > 0
	_duration.text = "%d 日" % days
	var score := int(_payload.get("score", 0))
	_profit.text = _money_text(score) if score != 0 else "—"
	_profit.add_theme_color_override("font_color", _profit_color())
	# 毛利只是排序启发式，建造前的关键决定是缺什么、为什么缺；不在悬停卡
	# 里抢占首屏空间。
	_profit.get_parent().get_parent().visible = false

	var lines := _tooltip_lines()
	_set_section(_flow, _flow_text, lines, ["投入：", "自然资源：", "产出："])
	_set_section(_employment, _employment_text, lines, ["岗位："])
	_subtitle.text = _subtitle_text()
	_subtitle.visible = not _subtitle.text.is_empty()
	_apply_issue_rows(_issue_rows(lines, eligible))
	_summary.text = ""
	_summary.visible = false


func _subtitle_text() -> String:
	var role := String(_payload.get("role_label", ""))
	var tier := int(_payload.get("tier", -1))
	if not role.is_empty() and tier >= 0:
		return "%s · 第 %d 档" % [role, tier + 1]
	if not role.is_empty():
		return role
	return "每栋建筑的生产配方" if _flow.visible else ""


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


func _issue_rows(lines: PackedStringArray, eligible: bool) -> Array:
	if eligible:
		return []
	var result: Array = []
	var material_rows: Array = _payload.get("material_status", [])
	for raw in material_rows:
		if not raw is Dictionary or not bool((raw as Dictionary).get("missing", false)):
			continue
		var material: Dictionary = raw
		var name := String(material.get("name", "建材"))
		var missing := String(material.get("missing_text", ""))
		var reason := String(material.get("reason", "市场无货"))
		result.append({
			"icon": StringName(material.get("icon", &"metric.goods")),
			"text": "%s 还差 %s · %s" % [name, missing, reason],
		})
	if bool(_payload.get("cash_blocked", false)):
		var cash := String(_payload.get("cash_text", ""))
		result.append({
			"icon": &"metric.treasury",
			"text": "现金 %s · 买不起" % cash if not cash.is_empty() else "现金不足 · 买不起",
		})
	if result.is_empty():
		var reason_text := String(_payload.get("reason_text", "")).strip_edges()
		if not reason_text.is_empty():
			result.append({"icon": &"status.warning", "text": reason_text})
		else:
			var stock_lines := _lines_with_prefix(lines, "现货：")
			for line in stock_lines:
				result.append({"icon": &"metric.goods", "text": "%s · 市场无货" % line})
	return result


func _apply_issue_rows(rows: Array) -> void:
	_materials.visible = not rows.is_empty()
	_materials_text.text = "缺口与原因"
	for index in range(_material_rows.get_child_count()):
		var row := _material_rows.get_child(index) as HBoxContainer
		var visible := index < rows.size()
		row.visible = visible
		if not visible:
			continue
		var data: Dictionary = rows[index]
		var icon := row.get_node("Icon") as IconBadge
		icon.set_semantic(StringName(data.get("icon", &"metric.goods")),
			UITokens.DOSSIER_OXBLOOD)
		(row.get_node("Label") as Label).text = String(data.get("text", ""))


func _set_section(panel: PanelContainer, label: Label, lines: PackedStringArray,
		prefixes: PackedStringArray) -> void:
	var section_lines := PackedStringArray()
	for line in lines:
		for prefix in prefixes:
			if line.begins_with(prefix):
				section_lines.append(line)
				break
	label.text = "\n".join(section_lines)
	panel.visible = not section_lines.is_empty()


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
	var viewport_rect := get_viewport_rect()
	# 悬停卡挂在 DetailShell 内，安全区必须跟随当前建造栏，而不是整个
	# viewport。否则指针靠近栏的右侧/顶部时，卡片会越过 DetailShell，压住
	# 旁边的地块详情，或被父容器的 clip_contents 截掉。
	var safe := _workspace.get_global_rect().intersection(viewport_rect)
	safe = safe.grow(-EDGE_MARGIN)
	if safe.size.x <= 0.0 or safe.size.y <= 0.0:
		return
	# 普通地块档案的详情列只有约 424px；宽屏时卡片可展开，窄栏时按
	# 当前栏宽收窄，保证纸笺完整落在 DetailShell 内。
	var desired_width := minf(CARD_WIDTH, safe.size.x)
	custom_minimum_size.x = desired_width
	size.x = desired_width
	var source_rect := Rect2(_source.get_global_position(), _source.size)
	var card_size := size
	var pointer := get_viewport().get_mouse_position()
	var pos := Vector2(pointer.x + POINTER_GAP, source_rect.end.y + POINTER_GAP)
	if pos.x + card_size.x > safe.end.x:
		pos.x = source_rect.position.x - card_size.x - POINTER_GAP
	if pos.y + card_size.y > safe.end.y:
		pos.y = source_rect.position.y - card_size.y - POINTER_GAP
	pos.x = clampf(pos.x, safe.position.x, maxf(safe.position.x, safe.end.x - card_size.x))
	pos.y = clampf(pos.y, safe.position.y, maxf(safe.position.y, safe.end.y - card_size.y))
	global_position = pos
