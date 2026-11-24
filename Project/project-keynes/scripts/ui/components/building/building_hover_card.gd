extends PanelContainer
class_name BuildingHoverCard

## 只读营造报价与生产配方，随当前目录报价更新。

const EDGE_MARGIN := 8.0
const POINTER_GAP := 12.0
const CARD_WIDTH := 440.0
const MIN_SIDE_WIDTH := 285.0
const IssueRowScene := preload("res://scenes/ui/insight_row.tscn")

@onready var _icon: IconBadge = $Body/Header/Icon
@onready var _title: Label = $Body/Header/Identity/Title
@onready var _subtitle: Label = $Body/Header/Identity/Subtitle
@onready var _status: Label = $Body/Header/Status
@onready var _quote: PanelContainer = $Body/Quote
@onready var _stats: HBoxContainer = $Body/Quote/Content/Stats
@onready var _cost: Label = $Body/Quote/Content/Stats/Cost/Labels/Value
@onready var _duration: Label = $Body/Quote/Content/Stats/Duration/Labels/Value
@onready var _materials: VBoxContainer = $Body/Quote/Content/Materials
@onready var _requirements: VBoxContainer = $Body/Quote/Content/Requirements
@onready var _requirement_list = $Body/Quote/Content/Requirements/List
@onready var _flow: VBoxContainer = $Body/Flow
@onready var _outputs: VBoxContainer = $Body/Flow/Outputs
@onready var _inputs: VBoxContainer = $Body/Flow/Inputs
@onready var _employment: VBoxContainer = $Body/Employment
@onready var _optional: VBoxContainer = $Body/Optional
@onready var _upkeep: VBoxContainer = $Body/Upkeep

var _source: Control
var _workspace: Control
var _payload: Dictionary = {}
var _layout_generation := 0
var _beside_workspace := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_behavior_recursive = Control.MOUSE_BEHAVIOR_DISABLED
	visible = false
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	custom_minimum_size.x = CARD_WIDTH
	size = Vector2(CARD_WIDTH, 0.0)
	minimum_size_changed.connect(_fit_card, CONNECT_DEFERRED)
	get_viewport().size_changed.connect(_on_viewport_resized, CONNECT_DEFERRED)
	process_mode = Node.PROCESS_MODE_ALWAYS
	MoneyDisplay.apply_icon(_stats.get_node("Cost/Icon"), 22)
	(_stats.get_node("Duration/Icon") as IconBadge).set_semantic(&"system.calendar")


func show_for(row: Dictionary, source: Control, workspace: Control,
		beside_workspace: bool = false) -> void:
	_payload = row.duplicate(true)
	_source = source
	_workspace = workspace
	_beside_workspace = beside_workspace
	_apply_payload()
	visible = true
	if UIAnimation.reduced_motion():
		modulate.a = 1.0
	else:
		UIAnimation.crossfade(self)
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


func _on_viewport_resized() -> void:
	if visible:
		refresh(_payload)


func _fit_after_layout() -> void:
	_layout_generation += 1
	var generation := _layout_generation
	# 替代材料标签在取得栏宽后才会换行，等容器排完再判断可用高度。
	await get_tree().process_frame
	await get_tree().process_frame
	for section in [_optional, _employment, _inputs, _upkeep, _outputs]:
		if not visible or generation != _layout_generation or not is_instance_valid(_workspace):
			return
		var safe := _safe_rect()
		if get_combined_minimum_size().y <= safe.size.y:
			break
		if not section.visible:
			continue
		section.hide()
		_flow.visible = _inputs.visible or _outputs.visible
		await get_tree().process_frame
	_fit_card()


func _fit_card() -> void:
	if not visible:
		return
	size.y = get_combined_minimum_size().y
	_place_card()


func _apply_payload() -> void:
	var name := String(_payload.get("name", "建筑"))
	var icon := StringName(_payload.get("icon", &"economy.building"))
	var eligible := bool(_payload.get("eligible", false))
	_icon.set_semantic(icon, UITokens.DOSSIER_BRASS if eligible else UITokens.DOSSIER_UMBER)
	_title.text = name
	_status.text = String(_payload.get("status_text", "可营造" if eligible else "暂不可营造"))
	var status_tone := String(_payload.get("status_tone", "good" if eligible else "risk"))
	_status.add_theme_font_size_override("font_size", 15)
	_status.add_theme_color_override("font_color",
		UITokens.DOSSIER_VERDIGRIS if status_tone == "good" else (
			UITokens.DOSSIER_OXBLOOD if status_tone == "risk" else UITokens.DOSSIER_INK_MUTED))
	var has_cost := int(_payload.get("cash_required", 0)) > 0
	_cost.text = String(_payload.get("cash_text", "")) if has_cost else ""
	_cost.get_parent().get_parent().visible = has_cost
	var days := int(_payload.get("days", 0))
	_duration.get_parent().get_parent().visible = days > 0
	_duration.text = "%d 日" % days
	(_duration.get_parent().get_node("Label") as Label).text = String(_payload.get("days_label", "工期"))
	_stats.visible = has_cost or days > 0
	_subtitle.text = _subtitle_text()
	_subtitle.visible = not _subtitle.text.is_empty()

	_apply_quote(eligible)
	var preview: Dictionary = _payload.get("preview", {})
	(_outputs.get_node("Title") as Label).text = String(preview.get("outputs_title", "每栋基础日产"))
	_set_rows(_outputs, preview.get("outputs", []), UITokens.DOSSIER_VERDIGRIS)
	_set_rows(_inputs, preview.get("inputs", []))
	_set_rows(_employment, preview.get("jobs", []))
	_set_rows(_optional, preview.get("optional", []))
	_set_rows(_upkeep, preview.get("upkeep", []))
	_flow.visible = _outputs.visible or _inputs.visible


func _subtitle_text() -> String:
	var role := String(_payload.get("role_label", ""))
	var tier := int(_payload.get("tier", -1))
	if not role.is_empty() and tier > 0:
		return "%s · 第 %d 档" % [role, tier]
	if not role.is_empty():
		return role
	return ""


func _apply_quote(eligible: bool) -> void:
	var requirements: Array = []
	var issues: Array = []
	var has_shortage := false
	for material: Dictionary in _payload.get("material_status", []):
		var missing := not eligible and bool(material.get("missing", false))
		has_shortage = has_shortage or missing
		if material.has("text"):
			var item := material.duplicate()
			if missing:
				var missing_quantity := String(material.get("missing_text", ""))
				var cause := String(material.get("reason", ""))
				var shortage := "市场缺 %s 单位" % missing_quantity
				if not cause.is_empty():
					shortage = "%s · %s" % [cause, shortage]
				var source := String(material.get("detail", ""))
				item["detail"] = "%s，%s" % [source, shortage] if not source.is_empty() else shortage
				item["detail_accent"] = UITokens.DOSSIER_OXBLOOD
			requirements.append(item)
		elif missing:
			issues.append({"icon": material.get("icon", &"metric.goods"),
				"text": "%s 缺 %s 单位" % [material.get("name", ""), material.get("missing_text", "")]})
	if not eligible:
		var reason := String(_payload.get("reason_text", "")).strip_edges()
		var material_block := has_shortage and reason in ["建材不足", "市场缺货", "缺建材"]
		if bool(_payload.get("cash_blocked", false)):
			issues.append({"icon": &"metric.treasury", "text": "国库现金不足"})
		elif not reason.is_empty() and not material_block:
			issues.append({"icon": &"status.warning", "text": reason})
	_requirements.visible = not requirements.is_empty()
	_requirement_list.set_rows(requirements)
	_apply_issue_rows(issues)
	_quote.visible = _stats.visible or _requirements.visible or _materials.visible


func _apply_issue_rows(rows: Array) -> void:
	_materials.visible = not rows.is_empty()
	while _materials.get_child_count() < rows.size():
		var line := IssueRowScene.instantiate()
		_materials.add_child(line)
		var label := line.get_node("Label") as Label
		label.theme_type_variation = &"PKDossierBody"
		label.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	for index in _materials.get_child_count():
		var row := _materials.get_child(index) as HBoxContainer
		row.visible = index < rows.size()
		if row.visible:
			var data: Dictionary = rows[index]
			(row.get_node("Icon") as IconBadge).set_semantic(StringName(data.icon))
			(row.get_node("Label") as Label).text = String(data.text)


func _set_rows(section: VBoxContainer, rows: Array, accent: Color = Color.TRANSPARENT) -> void:
	section.visible = not rows.is_empty()
	if accent != Color.TRANSPARENT:
		rows = rows.map(func(row: Dictionary) -> Dictionary:
			var tinted := row.duplicate()
			tinted["value_accent"] = accent
			return tinted)
	section.get_node("List").set_rows(rows)


func _place_card() -> void:
	if not visible or _source == null or _workspace == null \
			or not is_instance_valid(_source) or not is_instance_valid(_workspace):
		return
	var safe := _safe_rect()
	if safe.size.x <= 0.0 or safe.size.y <= 0.0:
		return
	var source_rect := _source.get_global_rect()
	var desired_width := minf(CARD_WIDTH, safe.size.x)
	if _beside_workspace:
		var workspace_rect := _workspace.get_global_rect()
		var left_space := workspace_rect.position.x - safe.position.x - POINTER_GAP
		var right_space := safe.end.x - workspace_rect.end.x - POINTER_GAP
		if maxf(left_space, right_space) >= MIN_SIDE_WIDTH:
			var left := left_space >= right_space
			desired_width = minf(desired_width, left_space if left else right_space)
			custom_minimum_size.x = desired_width
			size.x = desired_width
			global_position = Vector2(
				workspace_rect.position.x - POINTER_GAP - size.x if left else workspace_rect.end.x + POINTER_GAP,
				clampf(source_rect.position.y, safe.position.y, maxf(safe.position.y, safe.end.y - size.y)))
			return
	var fits_below := source_rect.end.y + POINTER_GAP + size.y <= safe.end.y
	var fits_above := source_rect.position.y - POINTER_GAP - size.y >= safe.position.y
	var beside_button := false
	if not fits_below and not fits_above:
		var action := _source.get_node_or_null("%BuildButton") as Control
		if action != null:
			var side_width := action.get_global_rect().position.x - safe.position.x - EDGE_MARGIN
			if side_width >= MIN_SIDE_WIDTH:
				desired_width = minf(desired_width, side_width)
				beside_button = true
	custom_minimum_size.x = desired_width
	size.x = desired_width
	var card_size := size
	var pointer := get_viewport().get_mouse_position()
	var pos := Vector2(pointer.x + POINTER_GAP, source_rect.end.y + POINTER_GAP)
	if beside_button:
		pos.x = safe.position.x
	if not fits_below and fits_above:
		pos.y = source_rect.position.y - card_size.y - POINTER_GAP
	pos.x = clampf(pos.x, safe.position.x, maxf(safe.position.x, safe.end.x - card_size.x))
	pos.y = clampf(pos.y, safe.position.y, maxf(safe.position.y, safe.end.y - card_size.y))
	global_position = pos


func _safe_rect() -> Rect2:
	var viewport := get_viewport_rect()
	return (viewport if _beside_workspace else _workspace.get_global_rect().intersection(viewport)).grow(-EDGE_MARGIN)
