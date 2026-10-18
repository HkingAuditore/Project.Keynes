extends Control
class_name ObjectDetailDialog

const FactGridScene := preload("res://scenes/ui/object_fact_grid.tscn")
const FactCellScene := preload("res://scenes/ui/object_fact_cell.tscn")
const RowsCardScene := preload("res://scenes/ui/object_rows_card.tscn")
const DetailLineScene := preload("res://scenes/ui/object_detail_line.tscn")
const StateCardScene := preload("res://scenes/ui/object_state_card.tscn")
const NoteScene := preload("res://scenes/ui/object_note.tscn")
const ActionButtonScene := preload("res://scenes/ui/object_action_button.tscn")
const TaxSectionScene := preload("res://scenes/ui/object_tax_section.tscn")
const TaxLaneScene := preload("res://scenes/ui/object_tax_lane.tscn")
const GoodDossierScene := preload("res://scenes/ui/object_good_dossier.tscn")
const CohortDossierScene := preload("res://scenes/ui/object_cohort_dossier.tscn")
const BuildingDossierScene := preload("res://scenes/ui/object_building_dossier.tscn")

signal closed()
signal colonization_requested(family_handle: int, source_cell: int)
signal tax_override_requested(scope: String, kind: String, item_id: String, rate: int, mode: int)
signal tax_reset_requested(scope: String, kind: String, item_id: String)
signal tax_editing_finished()
## 物资详情「逐单商路」翻页与对端定位。翻页只改请求 offset，由 GameUIManager
## 重建 payload；定位由上层关闭详情并选中对端地块。
signal trade_orders_page_requested(offset: int)
signal trade_order_locate_requested(cell_idx: int)

const PANEL_MIN_SIZE := Vector2(620.0, 520.0)
const DENSE_KPI_MAX_HEIGHT := 500.0

var _header_icon: IconBadge
var _kicker_label: Label
var _title_label: Label
var _subtitle_label: Label
var _summary_band: Control
var _kpi_cards: Array = []
var _kpi_values: Dictionary = {}
var _chapter_nav: DossierChapterNav
var _section_nav: HBoxContainer
var _section_buttons: Dictionary = {}
var _section_targets: Dictionary = {}
var _scroll: ScrollContainer
var _content: VBoxContainer
var _tax_section: VBoxContainer
var _tax_editors: Dictionary = {}
var _player_controller = null
var _fact_columns: Array[int] = []
var _embedded := false
var _fact_grids: Array[GridContainer] = []
var _detail_identity := ""
var _fact_value_labels: Array = []
var _payload_kind := ""
var _current_chapter := "overview"
var _scroll_by_chapter: Dictionary = {}
var _good_refs: Dictionary = {}
var _cohort_refs: Dictionary = {}
var _building_refs: Dictionary = {}
var _trade_orders_model: Dictionary = {}
var _trade_orders_signature := ""


func _ready() -> void:
	if _content != null:
		return
	_header_icon = get_node_or_null("Center/Dialog/Body/TitleRow/HeaderIcon") as IconBadge
	_kicker_label = get_node_or_null("%Kicker") as Label
	_title_label = get_node_or_null("Center/Dialog/Body/TitleRow/Titles/Title") as Label
	_subtitle_label = get_node_or_null("Center/Dialog/Body/TitleRow/Titles/Subtitle") as Label
	_summary_band = get_node_or_null("%Summary") as Control
	var kpi_row := get_node_or_null("%KpiRow")
	_kpi_cards.clear()
	if kpi_row != null:
		for child in kpi_row.get_children():
			if child is DossierKpiCard:
				(child as Control).custom_minimum_size = Vector2(72.0, DossierKpiCard.HEIGHT)
				_kpi_cards.append(child)
	if not _kpi_cards.is_empty():
		(_kpi_cards[_kpi_cards.size() - 1] as DossierKpiCard).show_divider = false
	_chapter_nav = get_node_or_null("%ChapterNav") as DossierChapterNav
	_section_nav = get_node_or_null("Center/Dialog/Body/ChapterNav/SectionNav") as HBoxContainer
	if _section_nav == null:
		_section_nav = get_node_or_null("Center/Dialog/Body/SectionNav") as HBoxContainer
	_scroll = get_node_or_null("Center/Dialog/Body/Scroll") as ScrollContainer
	_content = get_node_or_null("Center/Dialog/Body/Scroll/Content") as VBoxContainer
	var close_button := get_node_or_null("Center/Dialog/Body/TitleRow/CloseButton") as Button
	var backdrop_close := get_node_or_null("BackdropClose") as Button
	if _header_icon == null or _title_label == null or _subtitle_label == null \
			or _section_nav == null or _scroll == null or _content == null \
			or close_button == null or backdrop_close == null:
		push_error("ObjectDetailDialog 必须通过 object_detail_dialog.tscn 实例化。")
		return
	_section_buttons = {
		"overview": _section_nav.get_node("Overview"),
		"operations": _section_nav.get_node("Operations"),
		"effects": _section_nav.get_node("Effects"),
	}
	for section_id in _section_buttons:
		(_section_buttons[section_id] as Button).pressed.connect(
			_on_chapter_selected.bind(String(section_id)))
	if _chapter_nav != null:
		_chapter_nav.chapter_selected.connect(_on_chapter_selected)
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(close_dialog)
	backdrop_close.pressed.connect(close_dialog)
	resized.connect(_on_dialog_resized)


func show_details(payload: Dictionary) -> void:
	if _content == null:
		_ready()
	visible = true
	if _embedded:
		_apply_embedded_chrome(true)
	var next_identity := _detail_identity_of(payload)
	if next_identity != _detail_identity:
		_current_chapter = "overview"
		_scroll_by_chapter.clear()
		_trade_orders_model = {}
		_trade_orders_signature = ""
	_section_targets.clear()
	_fact_columns.clear()
	_fact_grids.clear()
	_fact_value_labels.clear()
	_kpi_values.clear()
	_good_refs.clear()
	_cohort_refs.clear()
	_building_refs.clear()
	_detail_identity = next_identity
	_payload_kind = String(payload.get("kind", ""))
	var kind := _payload_kind
	var header_icon_key := StringName("family.workspace.crest") \
		if kind == "family" else StringName(payload.get("icon", "resource"))
	_header_icon.set_semantic(header_icon_key,
		_dossier_accent(payload.get("accent", UITokens.DOSSIER_BRASS)))
	if _kicker_label != null:
		_kicker_label.text = _kicker_for_kind(kind)
	_title_label.text = String(payload.get("name", "对象详情"))
	_title_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	_subtitle_label.text = String(payload.get("subtitle", ""))
	_subtitle_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	_clear_content()
	_tax_section = null
	_tax_editors.clear()
	var row: Dictionary = payload.get("row", {})
	var is_dossier_kind := kind in ["cohort", "good", "building"]
	if not is_dossier_kind:
		if _summary_band != null:
			_summary_band.visible = false
		_build_tax_section(kind, payload.get("tax_context", {}), row)
	match kind:
		"cohort":
			_build_cohort_details(row, payload.get("tax_context", {}))
		"building":
			_build_building_details(row, payload.get("tax_context", {}))
		"good":
			_build_good_details(row, payload.get("tax_context", {}))
		"resource":
			_build_resource_details(row)
		"family":
			_build_family_details(row)
	if kind == "good":
		_apply_trade_orders(payload.get("trade_orders", {}))
	_configure_section_nav(kind)
	if is_dossier_kind:
		_apply_dossier_chapter(_current_chapter, false)
	call_deferred("_fit_embedded_layout")


func refresh_details(payload: Dictionary) -> bool:
	if not visible or payload.is_empty():
		return false
	if has_active_tax_edit():
		return false
	var identity := _detail_identity_of(payload)
	if identity == _detail_identity and _content != null and _content.get_child_count() > 0:
		if _patch_details(payload):
			return true
	var saved_scroll := _scroll.scroll_vertical if _scroll != null else 0
	show_details(payload)
	call_deferred("_restore_scroll", saved_scroll)
	return true


func set_player_controller(controller) -> void:
	_player_controller = controller


func tax_editors() -> Array:
	return _tax_editors.values()


func has_active_tax_edit() -> bool:
	for editor_value in _tax_editors.values():
		var editor := editor_value as TaxLaneEditor
		if editor != null and editor.is_editing():
			return true
	return false


func has_blocking_tax_state() -> bool:
	for editor_value in _tax_editors.values():
		var editor := editor_value as TaxLaneEditor
		if editor != null and editor.blocks_rebuild():
			return true
	return false


func _kicker_for_kind(kind: String) -> String:
	match kind:
		"good": return "物资市场卷宗"
		"cohort": return "阶层民生卷宗"
		"building": return "产业建筑卷宗"
		"resource": return "自然资源卷宗"
		"family": return "家族分支卷宗"
		_: return "地块对象卷宗"


static func _dossier_accent(color: Color) -> Color:
	if color.is_equal_approx(UITokens.RISK) or color.is_equal_approx(UITokens.DOSSIER_OXBLOOD):
		return UITokens.DOSSIER_OXBLOOD
	if color.is_equal_approx(UITokens.GOOD) or color.is_equal_approx(UITokens.ECO) \
			or color.is_equal_approx(UITokens.DOSSIER_VERDIGRIS):
		return UITokens.DOSSIER_VERDIGRIS
	if color.is_equal_approx(UITokens.WARN) or color.is_equal_approx(UITokens.CLIMATE):
		return UITokens.DOSSIER_BRASS
	if color.is_equal_approx(UITokens.WATER) or color.is_equal_approx(UITokens.DOSSIER_SLATE):
		return UITokens.DOSSIER_SLATE
	if color.is_equal_approx(UITokens.RESOURCE) or color.is_equal_approx(UITokens.ACCENT) \
			or color.is_equal_approx(UITokens.BRASS_HIGHLIGHT):
		return UITokens.DOSSIER_INK
	return UITokens.DOSSIER_INK


func _detail_identity_of(payload: Dictionary) -> String:
	var kind := String(payload.get("kind", ""))
	var row: Dictionary = payload.get("row", {})
	var row_id := String(row.get("id", ""))
	if row_id.is_empty():
		row_id = String(payload.get("name", ""))
	var family_handle := int(row.get("family_handle", 0))
	return "%s|%s|%d|%d" % [kind, row_id, family_handle, _item_tax_lanes(row).size()]


func _patch_details(payload: Dictionary) -> bool:
	var kind := String(payload.get("kind", ""))
	if kind != _payload_kind:
		return false
	var row: Dictionary = payload.get("row", {})
	if not _patch_tax_section(payload.get("tax_context", {}), row):
		return false
	var header_icon_key := StringName("family.workspace.crest") \
		if kind == "family" else StringName(payload.get("icon", "resource"))
	_header_icon.set_semantic(header_icon_key,
		_dossier_accent(payload.get("accent", UITokens.DOSSIER_BRASS)))
	_title_label.text = String(payload.get("name", "对象详情"))
	_subtitle_label.text = String(payload.get("subtitle", ""))
	if kind == "good" and not _good_refs.is_empty():
		_patch_good_dossier(row)
	elif kind == "cohort" and not _cohort_refs.is_empty():
		_patch_cohort_dossier(row)
	elif kind == "building" and not _building_refs.is_empty():
		_patch_building_dossier(row)
	else:
		_patch_fact_values(_facts_for_row(kind, row))
	if kind == "good":
		_apply_trade_orders(payload.get("trade_orders", {}))
	_detail_identity = _detail_identity_of(payload)
	return true


func _apply_kpis(kpis: Array, live_patch: bool) -> void:
	if _summary_band == null or _kpi_cards.is_empty():
		return
	var visible_count := mini(kpis.size(), _kpi_cards.size())
	_summary_band.visible = visible_count > 0
	for i in range(_kpi_cards.size()):
		var card := _kpi_cards[i] as DossierKpiCard
		card.visible = i < visible_count
		card.show_divider = i < visible_count - 1
		if i >= visible_count:
			continue
		var data: Dictionary = kpis[i]
		var signature := "%s|%s|%s|%s|%s" % [
			String(data.get("id", "")),
			str(data.get("value", "")),
			String(data.get("text", "")),
			String(data.get("caption", "")),
			String(data.get("tone", "")),
		]
		var slot := "kpi_%d" % i
		if live_patch and String(_kpi_values.get(slot, "")) == signature:
			continue
		_kpi_values[slot] = signature
		card.set_metric(data)
	_sync_kpi_density()


func _sync_kpi_density() -> void:
	if _kpi_cards.is_empty():
		return
	var dense := size.y > 1.0 and size.y < DENSE_KPI_MAX_HEIGHT
	for card_value in _kpi_cards:
		(card_value as DossierKpiCard).dense = dense


func _patch_tax_section(context_value: Variant, row: Dictionary) -> bool:
	var context: Dictionary = context_value if context_value is Dictionary else {}
	var item_lanes := _item_tax_lanes(row)
	if item_lanes.is_empty():
		return _tax_editors.is_empty()
	if _tax_section == null or item_lanes.size() != _tax_editors.size():
		return false
	var cell_idx := int(context.get("cell", -1))
	var editable := bool(context.get("editable", false))
	(_tax_section.get_node("Head/Readonly") as Control).visible = not editable
	var hint := _tax_section.get_node("Hint") as Label
	if not bool(context.get("available", true)):
		hint.text = String(context.get("reason", "该领土没有可调整的税收政策。"))
		hint.visible = true
	else:
		hint.text = _tax_hint(_payload_kind)
		hint.visible = true
	for raw in item_lanes:
		var lane: Dictionary = raw
		var item_key := String(lane.get("item_id", ""))
		var key := "cell:%d/%s/%s" % [
			cell_idx, String(lane.get("kind", "")), item_key]
		var editor := _tax_editors.get(key) as TaxLaneEditor
		if editor == null:
			editor = _find_tax_editor(String(lane.get("kind", "")), item_key)
		if editor == null:
			return false
		editor.set_data(lane)
	return true


func _find_tax_editor(kind: String, item_id: String) -> TaxLaneEditor:
	var suffix := "/%s/%s" % [kind, item_id]
	for key_value in _tax_editors.keys():
		var key := String(key_value)
		if key.ends_with(suffix):
			return _tax_editors[key] as TaxLaneEditor
	return null


func _good_ledger_facts(row: Dictionary) -> Array:
	var dossier := CellInspectorViewModel.good_dossier_model(row)
	var anchor_text := String(row.get("cost_anchor_text", "—"))
	if anchor_text == "—" or anchor_text.is_empty():
		for item in row.get("detail_rows", []):
			if item is Dictionary and String((item as Dictionary).get("id", "")) == "cost_anchor":
				anchor_text = String((item as Dictionary).get("value", "—"))
				break
	var delta_text := String(row.get("delta", "—"))
	var facts := [
		{"label": "本地库存", "value": String(row.get("stock_plain", row.get("stock", "—"))),
			"accent": UITokens.DOSSIER_INK},
		{"label": "本地时价", "value": String(row.get("price", "—")),
			"accent": UITokens.DOSSIER_INK},
		{"label": "成本锚价", "value": anchor_text,
			"accent": UITokens.DOSSIER_INK_SOFT},
		{"label": "库存日变", "value": delta_text,
			"accent": _delta_accent(delta_text)},
	]
	var inbound := String(row.get("trade_inbound", ""))
	var outbound := String(row.get("trade_outbound", ""))
	if not inbound.is_empty():
		facts.append({"label": "在途运入", "value": inbound, "accent": UITokens.DOSSIER_VERDIGRIS})
	if not outbound.is_empty():
		facts.append({"label": "在途运出", "value": outbound, "accent": UITokens.DOSSIER_OXBLOOD})
	return facts


func _cohort_ledger_facts(row: Dictionary) -> Array:
	var income_rows: Array = row.get("income_rows", [])
	var expense_rows: Array = row.get("expense_rows", [])
	var income_label := "人均日收"
	var primary_income := String(row.get("income", "—"))
	if not income_rows.is_empty() and income_rows[0] is Dictionary:
		var ir: Dictionary = income_rows[0]
		income_label = String(ir.get("name", income_label))
		primary_income = String(ir.get("value", primary_income))
	var expense_label := "人均日支"
	var primary_expense := String(row.get("expense", "—"))
	if not expense_rows.is_empty() and expense_rows[0] is Dictionary:
		var er: Dictionary = expense_rows[0]
		expense_label = String(er.get("name", expense_label))
		primary_expense = String(er.get("value", primary_expense))
	return [
		{"label": "阶层人口", "value": String(row.get("population", "—")),
			"accent": UITokens.DOSSIER_INK},
		{"label": "综合满意度", "value": String(row.get("satisfaction", "—")),
			"accent": UITokens.DOSSIER_INK},
		{"label": income_label, "value": primary_income,
			"accent": UITokens.DOSSIER_VERDIGRIS},
		{"label": expense_label, "value": primary_expense,
			"accent": UITokens.DOSSIER_OXBLOOD},
	]


func _facts_for_row(kind: String, row: Dictionary) -> Array:
	match kind:
		"cohort":
			return _cohort_ledger_facts(row)
		"building":
			return [
				{"label": "栋数", "value": String(row.get("count", "—")), "accent": UITokens.DOSSIER_INK},
				{"label": "状态", "value": String(row.get("status", "—")), "accent": _dossier_accent(row.get("accent", UITokens.DOSSIER_INK))},
				{"label": String(row.get("profit_label", "利润")), "value": String(row.get("profit", "—")),
					"accent": _dossier_accent(row.get("accent", UITokens.DOSSIER_INK))},
			]
		"good":
			return _good_ledger_facts(row)
		"resource":
			return [
				{"label": "储量指数", "value": String(row.get("value", "—")), "accent": UITokens.DOSSIER_INK},
				{"label": "密度", "value": String(row.get("density", "—")), "accent": UITokens.DOSSIER_INK_SOFT},
				{"label": "日变化", "value": String(row.get("delta", "—")),
					"accent": _delta_accent(String(row.get("delta", "")))},
				{"label": "开采条件", "value": "本地建筑可开采" if bool(row.get("extractable", false)) \
					else "本地无可开采建筑", "accent": UITokens.DOSSIER_VERDIGRIS if bool(row.get("extractable", false)) \
					else UITokens.DOSSIER_INK_MUTED},
			]
		"family":
			return [
				{"label": "家族人口", "value": String(row.get("population", "—")), "accent": UITokens.DOSSIER_INK},
				{"label": "重要人物", "value": "%d 位" % int(row.get("notable_people", 0)), "accent": UITokens.DOSSIER_INK},
				{"label": "家族产业", "value": "%s 栋" % String(row.get("owned_buildings", "0")), "accent": UITokens.DOSSIER_BRASS},
				{"label": "现金财产", "value": String(row.get("cash_claim", "—")), "accent": UITokens.DOSSIER_INK},
				{"label": "产业资产", "value": String(row.get("productive_asset_value", "—")), "accent": UITokens.DOSSIER_INK},
				{"label": "净资产", "value": String(row.get("net_worth", "—")), "accent": UITokens.DOSSIER_VERDIGRIS},
				{"label": "创立日", "value": "第 %d 日" % int(row.get("founded_day", 0)), "accent": UITokens.DOSSIER_INK_SOFT},
				{"label": "衰退复核", "value": "%d 次" % int(row.get("decline_reviews", 0)), "accent": UITokens.DOSSIER_INK_MUTED},
				{"label": "本地威望", "value": "%s · %s" % [
					["0", "I", "II", "III", "IV", "V"][clampi(int(row.get("prestige_level", 0)), 0, 5)],
					String(row.get("prestige_score", "0.0%"))], "accent": UITokens.DOSSIER_OXBLOOD},
			]
	return []


func _patch_fact_values(facts: Array) -> void:
	if facts.is_empty() or _fact_value_labels.is_empty():
		return
	var count := mini(facts.size(), _fact_value_labels.size())
	for index in range(count):
		var fact: Dictionary = facts[index]
		var value := _fact_value_labels[index] as Label
		if value == null or not is_instance_valid(value):
			continue
		value.text = String(fact.get("value", "—"))
		value.add_theme_color_override("font_color",
			_dossier_accent(fact.get("accent", UITokens.DOSSIER_INK)))


func _build_tax_section(kind: String, context_value: Variant, row: Dictionary,
		host: Control = null) -> void:
	var context: Dictionary = context_value if context_value is Dictionary else {}
	var item_lanes := _item_tax_lanes(row)
	if item_lanes.is_empty():
		return
	var parent_node: Control = host if host != null else _content
	_tax_section = TaxSectionScene.instantiate() as VBoxContainer
	parent_node.add_child(_tax_section)
	(_tax_section.get_node("Head/Icon") as IconBadge).set_semantic(
		&"tax.section", UITokens.DOSSIER_OXBLOOD)
	var title := _tax_section.get_node("Head/Title") as Label
	title.text = _tax_title(kind)
	title.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	var lanes := _tax_section.get_node("Lanes") as VBoxContainer
	var editable := bool(context.get("editable", false))
	var readonly_label := _tax_section.get_node("Head/Readonly") as Label
	readonly_label.visible = not editable
	readonly_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	var hint := _tax_section.get_node("Hint") as Label
	hint.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	if not bool(context.get("available", true)):
		hint.text = String(context.get("reason", "该领土没有可调整的税收政策。"))
		hint.visible = true
	else:
		hint.text = _tax_hint(kind)
		hint.visible = true
	for raw in item_lanes:
		var lane: Dictionary = raw
		var editor := TaxLaneScene.instantiate() as TaxLaneEditor
		lanes.add_child(editor)
		editor.override_requested.connect(func(scope: String, lane_kind: String,
				item_id: String, rate: int, mode: int = 0) -> void:
			tax_override_requested.emit(scope, lane_kind, item_id, rate, mode))
		editor.reset_requested.connect(func(scope: String, lane_kind: String,
				item_id: String) -> void:
			tax_reset_requested.emit(scope, lane_kind, item_id))
		editor.editing_finished.connect(func() -> void:
			tax_editing_finished.emit())
		editor.set_data(lane)
		_tax_editors[editor.editor_key(int(context.get("cell", -1)))] = editor
	lanes.visible = not item_lanes.is_empty()


func _item_tax_lanes(row: Dictionary) -> Array:
	var item_lanes: Array = []
	for lane_value in row.get("tax_lanes", []):
		var lane: Dictionary = lane_value
		if String(lane.get("scope", "item")) == "default":
			continue
		item_lanes.append(lane)
	return item_lanes


func _tax_title(kind: String) -> String:
	return {
		"cohort": "本阶层所得税",
		"good": "本物资交易税与关税",
		"building": "本建筑营业税",
	}.get(kind, "税收调整")


func _tax_hint(kind: String) -> String:
	return {
		"cohort": "在此调整本阶层所得税率，次日生效。",
		"good": "在此调整本物资交易税与进出口关税，次日生效。",
		"building": "在此调整本建筑税率，次日生效。",
	}.get(kind, "在此调整本项税率，次日生效。")


func set_embedded(embedded: bool = true) -> void:
	_embedded = embedded
	_apply_embedded_chrome(embedded)
	update_minimum_size()


func _get_minimum_size() -> Vector2:
	return Vector2.ZERO if _embedded else custom_minimum_size


func _apply_embedded_chrome(embedded: bool) -> void:
	clip_contents = embedded
	var backdrop := get_node_or_null("Backdrop") as Control
	var backdrop_close := get_node_or_null("BackdropClose") as Control
	var center := get_node_or_null("Center") as Control
	var dialog := get_node_or_null("Center/Dialog") as Control
	if backdrop != null:
		backdrop.visible = not embedded
	if backdrop_close != null:
		backdrop_close.visible = not embedded
	if center != null:
		center.clip_contents = embedded
	if dialog == null:
		return
	dialog.clip_contents = embedded
	dialog.custom_minimum_size = Vector2.ZERO if embedded else PANEL_MIN_SIZE
	if embedded:
		dialog.theme_type_variation = &""
		dialog.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		dialog.theme_type_variation = &"PKDialog"
		dialog.remove_theme_stylebox_override("panel")
		dialog.set_anchors_and_offsets_preset(Control.PRESET_CENTER,
			Control.PRESET_MODE_MINSIZE)
	dialog.update_minimum_size()


func close_dialog() -> void:
	if not visible:
		return
	visible = false
	_detail_identity = ""
	_payload_kind = ""
	_fact_value_labels.clear()
	_good_refs.clear()
	_cohort_refs.clear()
	_building_refs.clear()
	closed.emit()


func is_open() -> bool:
	return visible


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		close_dialog()
		get_viewport().set_input_as_handled()


func _clear_content() -> void:
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()


# ─── 物资与阶层卷宗构建与实时补丁 ──────────────────────────────────────

func _build_good_details(row: Dictionary, tax_context: Variant) -> void:
	# show_details 会重建整个卷宗节点；签名/模型必须清空，否则同身份重建后
	# _apply_trade_orders 会误判“数据未变”而跳过填表。
	_trade_orders_signature = ""
	_trade_orders_model = {}
	var root := GoodDossierScene.instantiate() as VBoxContainer
	_content.add_child(root)
	var overview_page := root.get_node("%OverviewPage") as VBoxContainer
	var operations_page := root.get_node("%OperationsPage") as VBoxContainer
	var notes := root.get_node("%Notes") as InspectorNoteList
	var supply_demand_bar := root.get_node("%SupplyDemandBar") as DossierDivergingBar
	var demand_supply_bars := root.get_node("%DemandSupplyBars") as DossierBarList
	var price_stock_bars := root.get_node("%PriceStockBars") as DossierBarList
	var trade_flow_bar := root.get_node("%TradeFlowBar") as DossierDivergingBar
	var trade_bars := root.get_node("%TradeBars") as DossierBarList
	var trade_empty_note := root.get_node("%TradeEmptyNote") as Label
	var orders_table := root.get_node("%TradeOrdersTable") as DossierLedgerTable
	var orders_hint := root.get_node("%TradeOrdersHint") as Label
	var orders_footer := root.get_node("%TradeOrdersFooter") as Control
	var orders_page_label := root.get_node("%TradeOrdersPage") as Label
	var orders_prev := root.get_node("%TradeOrdersPrev") as Button
	var orders_next := root.get_node("%TradeOrdersNext") as Button

	demand_supply_bars.label_width = 96.0
	demand_supply_bars.value_width = 76.0
	price_stock_bars.label_width = 96.0
	price_stock_bars.value_width = 76.0
	trade_bars.label_width = 96.0
	trade_bars.value_width = 76.0
	orders_table.set_columns(_trade_order_columns(), "", true)
	orders_table.row_height = 28.0
	orders_table.focus_mode = Control.FOCUS_NONE
	orders_table.empty_text = "本地目前没有该物资的在途商队。"
	orders_table.row_selected.connect(_on_trade_order_row_selected)
	IconButton.apply(orders_prev, &"action.back", IconButton.MEDIUM, "上一页")
	IconButton.apply(orders_next, &"action.chevron_right", IconButton.MEDIUM, "下一页")
	orders_prev.focus_mode = Control.FOCUS_NONE
	orders_next.focus_mode = Control.FOCUS_NONE
	orders_prev.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	orders_next.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	orders_prev.pressed.connect(_request_trade_orders_page.bind(-1))
	orders_next.pressed.connect(_request_trade_orders_page.bind(1))

	_fact_columns = [2]
	_good_refs = {
		"root": root,
		"overview_page": overview_page,
		"operations_page": operations_page,
		"notes": notes,
		"supply_demand_bar": supply_demand_bar,
		"demand_supply_bars": demand_supply_bars,
		"price_stock_bars": price_stock_bars,
		"trade_flow_bar": trade_flow_bar,
		"trade_bars": trade_bars,
		"trade_empty_note": trade_empty_note,
		"orders_table": orders_table,
		"orders_hint": orders_hint,
		"orders_footer": orders_footer,
		"orders_page": orders_page_label,
		"orders_prev": orders_prev,
		"orders_next": orders_next,
	}
	_section_targets["overview"] = overview_page
	_section_targets["operations"] = operations_page
	_build_tax_section("good", tax_context, row, _content)
	_apply_good_dossier_data(row, false)


func _patch_good_dossier(row: Dictionary) -> void:
	_apply_good_dossier_data(row, true)


func _apply_good_dossier_data(row: Dictionary, live_patch: bool) -> void:
	var dossier := CellInspectorViewModel.good_dossier_model(row)
	_apply_kpis(dossier.get("kpis", []), live_patch)
	var notes := _good_refs.get("notes") as InspectorNoteList
	if notes != null:
		var insights: Array = dossier.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
	var sd: Dictionary = dossier.get("supply_demand_bar", {})
	var sd_bar := _good_refs.get("supply_demand_bar") as DossierDivergingBar
	if sd_bar != null:
		sd_bar.set_values(
			String(sd.get("left_label", "本地需求")),
			float(sd.get("left_value", 0.0)),
			String(sd.get("left_text", "0")),
			String(sd.get("right_label", "本地供给")),
			float(sd.get("right_value", 0.0)),
			String(sd.get("right_text", "0"))
		)
	var ds_bars := _good_refs.get("demand_supply_bars") as DossierBarList
	if ds_bars != null:
		ds_bars.set_rows(dossier.get("demand_supply_bars", []))
	var ps_bars := _good_refs.get("price_stock_bars") as DossierBarList
	if ps_bars != null:
		ps_bars.set_rows(dossier.get("price_stock_bars", []))
	var tf: Dictionary = dossier.get("trade_flow_bar", {})
	var tf_bar := _good_refs.get("trade_flow_bar") as DossierDivergingBar
	if tf_bar != null:
		tf_bar.set_values(
			String(tf.get("left_label", "外销流出")),
			float(tf.get("left_value", 0.0)),
			String(tf.get("left_text", "0")),
			String(tf.get("right_label", "采购流入")),
			float(tf.get("right_value", 0.0)),
			String(tf.get("right_text", "0"))
		)
	var t_bars := _good_refs.get("trade_bars") as DossierBarList
	if t_bars != null:
		t_bars.set_rows(dossier.get("trade_bars", []))
	var empty_note := _good_refs.get("trade_empty_note") as Label
	if empty_note != null:
		var has_trade := float(tf.get("left_value", 0.0)) > 0.0001 \
			or float(tf.get("right_value", 0.0)) > 0.0001
		empty_note.text = "当前无在途商队与跨区贸易流水。"
		empty_note.visible = not has_trade


# ─── 物资详情 · 逐单商路 ──────────────────────────────────────────────
# 数据由 CellInspectorViewModel.trade_orders_model 生成；这里只做控件 patch，
# 不重建节点树，也不在日 tick 里自行查询/计算。

func _trade_order_columns() -> Array:
	return [
		{"id": "dir", "label": "方向", "width": 42.0},
		{"id": "counterpart", "label": "对端", "expand": true, "min_width": 78.0},
		{"id": "quantity", "label": "数量", "width": 52.0, "kind": "number"},
		{"id": "price", "label": "单价", "width": 78.0, "optional": true},
		{"id": "route", "label": "行程", "width": 82.0, "kind": "bar"},
		{"id": "status", "label": "状态", "width": 44.0, "optional": true},
	]


func _apply_trade_orders(model_value: Variant) -> void:
	var table := _good_refs.get("orders_table") as DossierLedgerTable
	if table == null:
		return
	var hint := _good_refs.get("orders_hint") as Label
	var footer := _good_refs.get("orders_footer") as Control
	var page_label := _good_refs.get("orders_page") as Label
	var prev := _good_refs.get("orders_prev") as Button
	var next := _good_refs.get("orders_next") as Button
	var model: Dictionary = model_value if model_value is Dictionary else {}
	if model.is_empty():
		_trade_orders_signature = ""
		_trade_orders_model = {}
		table.empty_text = "本地目前没有该物资的在途商队。"
		table.set_rows([])
		if hint != null:
			hint.text = "暂无贸易流水"
		if footer != null:
			footer.visible = false
		return
	if bool(model.get("pending", false)):
		# 结算中：保留上一页；现有 200ms 重试会在 committed 后拿到新页。
		if hint != null:
			hint.text = String(model.get("hint", "经济结算中，沿用上次结果。"))
		return
	if not bool(model.get("ok", false)):
		_trade_orders_signature = ""
		_trade_orders_model = {}
		table.empty_text = String(model.get("empty_text", "贸易流水暂不可用。"))
		table.set_rows([])
		if hint != null:
			hint.text = String(model.get("hint", "贸易流水暂不可用。"))
		if footer != null:
			footer.visible = false
		return
	var signature := String(model.get("signature", ""))
	if signature == _trade_orders_signature:
		return
	_trade_orders_signature = signature
	_trade_orders_model = model
	table.empty_text = String(model.get("empty_text", "本地目前没有该物资的在途商队。"))
	table.set_rows(model.get("rows", []))
	if hint != null:
		hint.text = String(model.get("hint", ""))
	if page_label != null:
		page_label.text = String(model.get("page_label", ""))
	var limit := maxi(1, int(model.get("limit", 12)))
	var total := maxi(0, int(model.get("total", 0)))
	if footer != null:
		footer.visible = total > limit
	if prev != null:
		prev.disabled = int(model.get("offset", 0)) <= 0
	if next != null:
		next.disabled = not bool(model.get("has_more", false))


func _request_trade_orders_page(step: int) -> void:
	if _trade_orders_model.is_empty():
		return
	var limit := maxi(1, int(_trade_orders_model.get("limit", 12)))
	var total := maxi(0, int(_trade_orders_model.get("total", 0)))
	var offset := int(_trade_orders_model.get("offset", 0))
	var target := offset + step * limit
	var max_offset := maxi(0, ((maxi(total, 1) - 1) / limit) * limit)
	target = clampi(target, 0, max_offset)
	if target == offset and step != 0:
		return
	trade_orders_page_requested.emit(target)


func _on_trade_order_row_selected(row_id: Variant) -> void:
	var rows_by_id: Dictionary = _trade_orders_model.get("rows_by_id", {})
	var row: Dictionary = rows_by_id.get(row_id, {})
	var cell := int(row.get("locate_cell", -1))
	if cell >= 0:
		trade_order_locate_requested.emit(cell)


# ─── 测试钩子（逐单商路） ─────────────────────────────────────────────

func trade_orders_row_count() -> int:
	var table := _good_refs.get("orders_table") as DossierLedgerTable
	return table.row_count() if table != null else 0


func trade_orders_hint_text() -> String:
	var hint := _good_refs.get("orders_hint") as Label
	return hint.text if hint != null else ""


func trade_orders_offset() -> int:
	return int(_trade_orders_model.get("offset", 0))


func trade_orders_page_text() -> String:
	var label := _good_refs.get("orders_page") as Label
	return label.text if label != null else ""


func current_trade_orders_model() -> Dictionary:
	return _trade_orders_model


func _build_cohort_details(row: Dictionary, tax_context: Variant) -> void:
	var root := CohortDossierScene.instantiate() as VBoxContainer
	_content.add_child(root)
	var overview_page := root.get_node("%OverviewPage") as VBoxContainer
	var operations_page := root.get_node("%OperationsPage") as VBoxContainer
	var notes := root.get_node("%Notes") as InspectorNoteList
	var living_strip := root.get_node("%LivingStrip") as DossierChart
	var radar_split := root.get_node("%RadarSplit") as GridContainer
	var radar := root.get_node("%SatisfactionRadar") as DossierRadarChart
	var dimension_bars := root.get_node("%DimensionBars") as DossierBarList
	var cashflow_bar := root.get_node("%CashflowBar") as DossierDivergingBar
	var income_stacked := root.get_node("%IncomeStackedBar") as DossierStackedBar
	var expense_stacked := root.get_node("%ExpenseStackedBar") as DossierStackedBar
	var summary_label := root.get_node("%SummaryLabel") as Label
	var tier_kicker := root.get_node("%TierKicker") as Label
	var demand_tier_bars := root.get_node("%DemandTierBars") as DossierBarList
	var goods_kicker := root.get_node("%GoodsKicker") as Label
	var active_demand_bars := root.get_node("%ActiveDemandBars") as DossierBarList
	var demand_empty_note := root.get_node("%DemandEmptyNote") as Label
	var inactive_note := root.get_node("%InactiveAlternativesNote") as Label

	dimension_bars.row_height = 21.0
	dimension_bars.label_width = 68.0
	dimension_bars.value_width = 50.0
	demand_tier_bars.label_width = 104.0
	demand_tier_bars.value_width = 92.0
	active_demand_bars.label_width = 114.0
	active_demand_bars.value_width = 104.0

	# 兼容既有测试对八维核心摘要 4 列网格的断言钩子。
	_fact_columns = [4]
	_cohort_refs = {
		"root": root,
		"overview_page": overview_page,
		"operations_page": operations_page,
		"notes": notes,
		"living_strip": living_strip,
		"radar_split": radar_split,
		"radar": radar,
		"dimension_bars": dimension_bars,
		"cashflow_bar": cashflow_bar,
		"income_stacked": income_stacked,
		"expense_stacked": expense_stacked,
		"summary_label": summary_label,
		"tier_kicker": tier_kicker,
		"demand_tier_bars": demand_tier_bars,
		"goods_kicker": goods_kicker,
		"active_demand_bars": active_demand_bars,
		"demand_empty_note": demand_empty_note,
		"inactive_note": inactive_note,
	}
	_section_targets["overview"] = overview_page
	_section_targets["operations"] = operations_page
	_build_tax_section("cohort", tax_context, row, _content)
	_apply_cohort_dossier_data(row, false)
	_sync_cohort_radar_split()


func _patch_cohort_dossier(row: Dictionary) -> void:
	_apply_cohort_dossier_data(row, true)
	_sync_cohort_radar_split()


func _sync_cohort_radar_split() -> void:
	var radar_split := _cohort_refs.get("radar_split") as GridContainer
	if radar_split == null or not is_instance_valid(radar_split):
		return
	var w := _content_width()
	radar_split.columns = 1 if (w > 1.0 and w < 360.0) else 2


func _apply_cohort_dossier_data(row: Dictionary, live_patch: bool) -> void:
	var dossier := CellInspectorViewModel.cohort_dossier_model(row)
	_apply_kpis(dossier.get("kpis", []), live_patch)
	var notes := _cohort_refs.get("notes") as InspectorNoteList
	if notes != null:
		var insights: Array = dossier.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
	var living_strip := _cohort_refs.get("living_strip") as Control
	if living_strip != null and living_strip.has_method("set_living_state"):
		living_strip.set_living_state(
			int(dossier.get("living_level", -1)),
			String(dossier.get("wealth_text", "—")),
			String(row.get("satisfaction", "—"))
		)
	var radar := _cohort_refs.get("radar") as DossierRadarChart
	if radar != null:
		var axes: PackedStringArray = dossier.get("radar_axes", PackedStringArray())
		var vals: PackedFloat32Array = dossier.get("radar_values", PackedFloat32Array())
		var refs: PackedFloat32Array = dossier.get("radar_reference", PackedFloat32Array())
		radar.set_values(axes, vals, refs, UITokens.DOSSIER_OXBLOOD)
	var dim_bars := _cohort_refs.get("dimension_bars") as DossierBarList
	if dim_bars != null:
		var dbars: Array = dossier.get("dimension_bars", [])
		dim_bars.set_rows(dbars)
		dim_bars.visible = not dbars.is_empty()
	var cf: Dictionary = dossier.get("cashflow_bar", {})
	var cf_bar := _cohort_refs.get("cashflow_bar") as DossierDivergingBar
	if cf_bar != null:
		cf_bar.set_values(
			String(cf.get("left_label", "人均日支")),
			float(cf.get("left_value", 0.0)),
			String(cf.get("left_text", "—")),
			String(cf.get("right_label", "人均日收")),
			float(cf.get("right_value", 0.0)),
			String(cf.get("right_text", "—"))
		)
	var inc_stacked := _cohort_refs.get("income_stacked") as DossierStackedBar
	if inc_stacked != null:
		var inc_segs: Array = dossier.get("income_segments", [])
		inc_stacked.visible = not inc_segs.is_empty()
		if not inc_segs.is_empty():
			inc_stacked.set_segments("收入构成", inc_segs,
				"%s/人" % String(row.get("income", "—")))
	var exp_stacked := _cohort_refs.get("expense_stacked") as DossierStackedBar
	if exp_stacked != null:
		var exp_segs: Array = dossier.get("expense_segments", [])
		exp_stacked.visible = not exp_segs.is_empty()
		if not exp_segs.is_empty():
			exp_stacked.set_segments("支出构成", exp_segs,
				"%s/人" % String(row.get("expense", "—")))

	var demand_summary: Dictionary = row.get("demand_summary", {})
	var summary_label := _cohort_refs.get("summary_label") as Label
	if summary_label != null:
		var total_cost := String(demand_summary.get("total_daily_cost", ""))
		summary_label.text = ("日均开销 %s/人" % total_cost) \
			if (not total_cost.is_empty() and total_cost != "—") \
			else String(demand_summary.get("value", ""))
	var tier_bars_data: Array = dossier.get("demand_tier_bars", [])
	var tier_kicker := _cohort_refs.get("tier_kicker") as Label
	var tier_bars := _cohort_refs.get("demand_tier_bars") as DossierBarList
	if tier_kicker != null:
		tier_kicker.visible = not tier_bars_data.is_empty()
	if tier_bars != null:
		tier_bars.visible = not tier_bars_data.is_empty()
		tier_bars.set_rows(tier_bars_data)
	var active_bars_data: Array = dossier.get("active_demand_bars", [])
	var goods_kicker := _cohort_refs.get("goods_kicker") as Label
	var active_bars := _cohort_refs.get("active_demand_bars") as DossierBarList
	if goods_kicker != null:
		goods_kicker.visible = not active_bars_data.is_empty()
	if active_bars != null:
		active_bars.visible = not active_bars_data.is_empty()
		active_bars.set_rows(active_bars_data)
	var empty_note := _cohort_refs.get("demand_empty_note") as Label
	if empty_note != null:
		empty_note.text = "当前无活跃物资消费。"
		empty_note.visible = active_bars_data.is_empty()
	var inactive_note := _cohort_refs.get("inactive_note") as Label
	if inactive_note != null:
		var summary_str := String(dossier.get("inactive_alternatives_summary", ""))
		inactive_note.text = summary_str
		inactive_note.visible = not summary_str.is_empty()


func _populate_inline_fact_grid(grid: GridContainer, facts: Array) -> void:
	if grid == null:
		return
	for child in grid.get_children():
		grid.remove_child(child)
		child.queue_free()
	for raw in facts:
		var fact: Dictionary = raw
		var cell := FactCellScene.instantiate() as VBoxContainer
		grid.add_child(cell)
		var label := cell.get_node("Label") as Label
		label.text = String(fact.get("label", ""))
		label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		var value := cell.get_node("Value") as Label
		value.text = String(fact.get("value", "—"))
		value.clip_text = false
		value.autowrap_mode = TextServer.AUTOWRAP_OFF
		value.custom_minimum_size.y = 18
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		value.add_theme_color_override("font_color",
			_dossier_accent(fact.get("accent", UITokens.DOSSIER_INK)))
		_fact_value_labels.append(value)


# ─── 其他详情区（建筑/自然资源/家族回退） ───────────────────────────────

func _build_building_details(row: Dictionary, tax_context: Variant = {}) -> void:
	var root := BuildingDossierScene.instantiate() as VBoxContainer
	_content.add_child(root)
	var overview_page := root.get_node("%OverviewPage") as VBoxContainer
	var operations_page := root.get_node("%OperationsPage") as VBoxContainer
	var notes := root.get_node("%Notes") as InspectorNoteList
	var capacity_bars := root.get_node("%CapacityBars") as DossierBarList
	var job_kicker := root.get_node("%JobKicker") as Label
	var job_bars := root.get_node("%JobBars") as DossierBarList
	var job_empty_note := root.get_node("%JobEmptyNote") as Label
	var production_bars := root.get_node("%ProductionBars") as DossierBarList
	var production_empty_note := root.get_node("%ProductionEmptyNote") as Label
	var unused_inputs_note := root.get_node("%UnusedInputsNote") as Label
	var finance_warning := root.get_node("%FinanceWarning") as Label
	var finance_diverging_bar := root.get_node("%FinanceDivergingBar") as DossierDivergingBar
	var revenue_stacked_bar := root.get_node("%RevenueStackedBar") as DossierStackedBar
	var cost_stacked_bar := root.get_node("%CostStackedBar") as DossierStackedBar
	var finance_note := root.get_node("%FinanceNote") as Label

	capacity_bars.label_width = 96.0
	capacity_bars.value_width = 64.0
	job_bars.label_width = 112.0
	job_bars.value_width = 64.0
	production_bars.label_width = 124.0
	production_bars.value_width = 104.0

	_fact_columns = [3]
	_building_refs = {
		"root": root,
		"overview_page": overview_page,
		"operations_page": operations_page,
		"notes": notes,
		"capacity_bars": capacity_bars,
		"job_kicker": job_kicker,
		"job_bars": job_bars,
		"job_empty_note": job_empty_note,
		"production_bars": production_bars,
		"production_empty_note": production_empty_note,
		"unused_inputs_note": unused_inputs_note,
		"finance_warning": finance_warning,
		"finance_diverging_bar": finance_diverging_bar,
		"revenue_stacked_bar": revenue_stacked_bar,
		"cost_stacked_bar": cost_stacked_bar,
		"finance_note": finance_note,
	}
	_section_targets["overview"] = overview_page
	_section_targets["operations"] = operations_page
	_build_tax_section("building", tax_context, row, _content)
	_apply_building_dossier_data(row, false)


func _patch_building_dossier(row: Dictionary) -> void:
	_apply_building_dossier_data(row, true)


func _apply_building_dossier_data(row: Dictionary, live_patch: bool) -> void:
	var dossier := CellInspectorViewModel.building_dossier_model(row)
	_apply_kpis(dossier.get("kpis", []), live_patch)
	var notes := _building_refs.get("notes") as InspectorNoteList
	if notes != null:
		var insights: Array = dossier.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
	var cap_bars := _building_refs.get("capacity_bars") as DossierBarList
	if cap_bars != null:
		var cbars: Array = dossier.get("capacity_bars", [])
		cap_bars.set_rows(cbars)
		cap_bars.visible = not cbars.is_empty()
	var jbars_data: Array = dossier.get("job_bars", [])
	var job_kicker := _building_refs.get("job_kicker") as Label
	var job_bars := _building_refs.get("job_bars") as DossierBarList
	var job_empty := _building_refs.get("job_empty_note") as Label
	if job_kicker != null:
		job_kicker.visible = not jbars_data.is_empty()
	if job_bars != null:
		job_bars.visible = not jbars_data.is_empty()
		job_bars.set_rows(jbars_data)
	if job_empty != null:
		job_empty.text = "建造中或无专职岗位配置。"
		job_empty.visible = jbars_data.is_empty()

	var pbars_data: Array = dossier.get("production_bars", [])
	var prod_bars := _building_refs.get("production_bars") as DossierBarList
	var prod_empty := _building_refs.get("production_empty_note") as Label
	var unused_note := _building_refs.get("unused_inputs_note") as Label
	if prod_bars != null:
		prod_bars.visible = not pbars_data.is_empty()
		prod_bars.set_rows(pbars_data)
	if prod_empty != null:
		prod_empty.text = "当前无日常投入或产出流水。"
		prod_empty.visible = pbars_data.is_empty()
	if unused_note != null:
		var unused_str := String(dossier.get("unused_inputs_summary", ""))
		unused_note.text = unused_str
		unused_note.visible = not unused_str.is_empty()

	var fwarn := _building_refs.get("finance_warning") as Label
	if fwarn != null:
		var warn_str := String(dossier.get("finance_warning", ""))
		fwarn.text = warn_str
		fwarn.visible = not warn_str.is_empty()
	var fd: Dictionary = dossier.get("finance_diverging_bar", {})
	var fd_bar := _building_refs.get("finance_diverging_bar") as DossierDivergingBar
	if fd_bar != null:
		fd_bar.set_values(
			String(fd.get("left_label", "本期总成本")),
			float(fd.get("left_value", 0.0)),
			String(fd.get("left_text", "0")),
			String(fd.get("right_label", "税后总收入")),
			float(fd.get("right_value", 0.0)),
			String(fd.get("right_text", "0"))
		)
	var rev_stacked := _building_refs.get("revenue_stacked_bar") as DossierStackedBar
	if rev_stacked != null:
		var rev_segs: Array = dossier.get("revenue_segments", [])
		rev_stacked.visible = not rev_segs.is_empty()
		if not rev_segs.is_empty():
			rev_stacked.set_segments("收入构成（含自用折算）", rev_segs,
				String(fd.get("right_text", "0")))
	var cost_stacked := _building_refs.get("cost_stacked_bar") as DossierStackedBar
	if cost_stacked != null:
		var cost_segs: Array = dossier.get("cost_segments", [])
		cost_stacked.visible = not cost_segs.is_empty()
		if not cost_segs.is_empty():
			cost_stacked.set_segments("成本构成", cost_segs,
				String(fd.get("left_text", "0")))
	var fnote := _building_refs.get("finance_note") as Label
	if fnote != null:
		var note_str := String(dossier.get("finance_note", ""))
		fnote.text = note_str
		fnote.visible = not note_str.is_empty()


func _build_resource_details(row: Dictionary) -> void:
	_section_targets["overview"] = _add_fact_grid(_facts_for_row("resource", row))


func _build_family_details(row: Dictionary) -> void:
	_section_targets["overview"] = _add_fact_grid(_facts_for_row("family", row))
	var people_target := _add_rows_card("家族特性", "family.house", UITokens.DOSSIER_INK,
		row.get("trait_rows", []))
	_add_rows_card("行为偏好", "growth", UITokens.DOSSIER_VERDIGRIS,
		row.get("behavior_rows", []))
	var branch_target := _add_rows_card("地块威望", "family.house", UITokens.DOSSIER_INK,
		row.get("branch_rows", []))
	var action_target := _add_branch_colonization_buttons(int(row.get("family_handle", 0)),
		row.get("branch_rows", []))
	if branch_target != null:
		people_target = branch_target
	elif action_target != null:
		people_target = action_target
	var family_effect_target := _add_rows_card("家族效果", "growth", UITokens.DOSSIER_BRASS,
		row.get("effect_rows", []))
	var effects_target := _add_rows_card("已激活加成", "growth", UITokens.DOSSIER_BRASS,
		row.get("modifier_rows", []))
	var trigger_target := _add_rows_card("累计触发", "resource", UITokens.DOSSIER_BRASS,
		row.get("trigger_rows", []))
	if family_effect_target != null:
		effects_target = family_effect_target
	elif effects_target == null:
		effects_target = trigger_target
	var people: Array = row.get("notable_person_rows", [])
	if people.is_empty():
		var empty_people := _add_muted_note("该家族目前没有重要人物。")
		if people_target == null:
			people_target = empty_people
	else:
		var notable_target := _add_rows_card("主要人物", "family.house", UITokens.DOSSIER_INK, people)
		if people_target == null:
			people_target = notable_target
	if people_target != null:
		_section_targets["operations"] = people_target
	if family_effect_target != null:
		_section_targets["effects"] = family_effect_target
	elif effects_target != null:
		_section_targets["effects"] = effects_target
	elif trigger_target != null:
		_section_targets["effects"] = trigger_target


func _add_branch_colonization_buttons(family_handle: int, branches: Array) -> Control:
	if family_handle == 0 or branches.is_empty():
		return null
	var panel := RowsCardScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.clip_contents = false
	_content.add_child(panel)
	(panel.get_node("Box/TitleRow/Icon") as IconBadge).set_semantic(
		&"family.house", UITokens.DOSSIER_OXBLOOD)
	var title := panel.get_node("Box/TitleRow/Title") as Label
	title.text = "选择开拓源分支"
	title.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	var rows := panel.get_node("Box/Rows") as VBoxContainer
	for raw in branches:
		var branch: Dictionary = raw
		var source_cell := int(branch.get("cell", -1))
		if source_cell < 0:
			continue
		var button := ActionButtonScene.instantiate() as Button
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.text = "%s · 从此城派遣" % String(branch.get(
			"name", "地块 %d" % source_cell))
		var owned: bool = _player_controller != null and \
			_player_controller.has_method("is_player_owned_cell") and \
			bool(_player_controller.is_player_owned_cell(source_cell))
		button.disabled = not owned
		button.tooltip_text = "仅玩家领土内的家族分支可以派遣" if not owned \
			else "选择一个可见的无主或本国陆地作为目标"
		button.pressed.connect(func() -> void:
			colonization_requested.emit(family_handle, source_cell))
		rows.add_child(button)
	return panel


func _delta_accent(delta: String) -> Color:
	if delta.begins_with("+"):
		return UITokens.DOSSIER_VERDIGRIS
	if delta.begins_with("-") or delta.begins_with("−"):
		return UITokens.DOSSIER_OXBLOOD
	return UITokens.DOSSIER_INK_MUTED


func _add_fact_grid(facts: Array) -> Control:
	var panel := FactGridScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(panel)
	var grid := panel.get_node("Grid") as GridContainer
	grid.columns = _fact_columns_for_width(facts.size(), _content_width())
	_fact_columns.append(grid.columns)
	_fact_grids.append(grid)
	for raw in facts:
		var fact: Dictionary = raw
		var cell := FactCellScene.instantiate() as VBoxContainer
		grid.add_child(cell)
		var label := cell.get_node("Label") as Label
		label.text = String(fact.get("label", ""))
		label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		var value := cell.get_node("Value") as Label
		value.text = String(fact.get("value", "—"))
		value.clip_text = false
		value.autowrap_mode = TextServer.AUTOWRAP_OFF
		value.custom_minimum_size.y = 18
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		value.add_theme_color_override("font_color",
			_dossier_accent(fact.get("accent", UITokens.DOSSIER_INK)))
		_fact_value_labels.append(value)
	return panel


static func _balanced_fact_columns(fact_count: int) -> int:
	if fact_count <= 1:
		return 1
	if fact_count == 2 or fact_count == 4:
		return 2
	if fact_count % 4 == 0:
		return 4
	if fact_count % 3 == 0 or fact_count % 3 == 2:
		return 3
	return 4


func _fact_columns_for_width(fact_count: int, width: float) -> int:
	var balanced := _balanced_fact_columns(fact_count)
	if width <= 1.0:
		return balanced
	if width < 220.0:
		return 1
	if width < 420.0:
		return mini(balanced, 2)
	return balanced


func _content_width() -> float:
	if _scroll != null and _scroll.size.x > 1.0:
		return _scroll.size.x
	if size.x > 1.0:
		return size.x
	return 0.0


func _on_dialog_resized() -> void:
	_sync_kpi_density()
	_sync_cohort_radar_split()
	_fit_fact_grids()


func _fit_embedded_layout() -> void:
	_sync_kpi_density()
	_sync_cohort_radar_split()
	_constrain_autowrap(_content)
	_fit_fact_grids()
	if _embedded and is_inside_tree():
		call_deferred("_fit_fact_grids")


func _constrain_autowrap(node: Node) -> void:
	if node == null:
		return
	if node is Label:
		var label := node as Label
		if label.autowrap_mode != TextServer.AUTOWRAP_OFF:
			label.custom_minimum_size.x = 0
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for child in node.get_children():
		_constrain_autowrap(child)


func _fit_fact_grids() -> void:
	if _fact_grids.is_empty():
		return
	var width := _content_width()
	if width <= 1.0:
		return
	for index in range(_fact_grids.size()):
		var grid := _fact_grids[index]
		if grid == null or not is_instance_valid(grid):
			continue
		var next_columns := _fact_columns_for_width(grid.get_child_count(), width)
		grid.columns = next_columns
		if index < _fact_columns.size():
			_fact_columns[index] = next_columns


func _add_rows_card(title_text: String, icon_key: String, accent: Color,
		rows: Array) -> Control:
	if rows.is_empty():
		return null
	var dossier_color := _dossier_accent(accent)
	var panel := RowsCardScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.clip_contents = false
	_content.add_child(panel)
	var icon := panel.get_node("Box/TitleRow/Icon") as IconBadge
	icon.set_semantic(StringName(icon_key), dossier_color)
	var title := panel.get_node("Box/TitleRow/Title") as Label
	title.text = title_text
	title.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	var row_box := panel.get_node("Box/Rows") as VBoxContainer
	for raw in rows:
		var data: Dictionary = raw
		if not bool(data.get("visible", true)):
			continue
		var line := DetailLineScene.instantiate() as VBoxContainer
		row_box.add_child(line)
		var name_label := line.get_node("Line/Name") as Label
		name_label.text = String(data.get("name", ""))
		name_label.clip_text = true
		name_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_SOFT)
		var value_text := String(data.get("value", "")).strip_edges()
		var value_label := line.get_node("Line/Value") as Label
		value_label.text = value_text
		value_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
		var detail := String(data.get("detail", "")).strip_edges()
		var value_too_long := value_text.length() > 22
		value_label.clip_text = false
		value_label.visible = not value_text.is_empty() and not value_too_long
		if value_too_long:
			if detail.is_empty():
				detail = value_text
			elif detail != value_text:
				detail = "%s\n%s" % [value_text, detail]
		var detail_label := line.get_node("Detail") as Label
		detail_label.text = detail
		detail_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
		detail_label.visible = not detail.is_empty()
		var tooltip := String(data.get("tooltip", "")).strip_edges()
		line.tooltip_text = tooltip if not tooltip.is_empty() else detail
	return panel


func _add_state_card(state: Dictionary) -> Control:
	var accent := _dossier_accent(state.get("accent", UITokens.WARN))
	var panel := StateCardScene.instantiate() as PanelContainer
	_content.add_child(panel)
	var label := panel.get_node("Box/Label") as Label
	label.text = String(state.get("label", "经营状态"))
	label.add_theme_color_override("font_color", accent)
	var detail := panel.get_node("Box/Detail") as Label
	detail.text = String(state.get("detail", ""))
	detail.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	var meta_text := String(state.get("meta", ""))
	var meta := panel.get_node("Box/Meta") as Label
	meta.text = meta_text
	meta.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	meta.visible = not meta_text.is_empty()
	return panel


func _add_finance_card(finance: Dictionary) -> Control:
	var panel := _add_fact_grid([
		{"label": String(finance.get("revenue_label", "本期收入")),
			"value": String(finance.get("revenue", "—")), "accent": UITokens.DOSSIER_VERDIGRIS},
		{"label": "本期总成本", "value": String(finance.get("cost", "—")), "accent": UITokens.DOSSIER_OXBLOOD},
		{"label": "本期盈亏", "value": String(finance.get("profit", "—")),
			"accent": UITokens.DOSSIER_VERDIGRIS if bool(finance.get("profit_positive", true)) else UITokens.DOSSIER_OXBLOOD},
	])
	var breakdown := String(finance.get("breakdown", ""))
	if not breakdown.is_empty():
		_add_muted_note(breakdown)
	var warning := String(finance.get("warning", ""))
	if not warning.is_empty():
		_add_muted_note(warning, UITokens.DOSSIER_OXBLOOD)
	return panel


func _add_muted_note(text: String, color: Color = UITokens.DOSSIER_INK_MUTED) -> Control:
	var note := NoteScene.instantiate() as Label
	note.text = text
	note.add_theme_color_override("font_color", _dossier_accent(color))
	_content.add_child(note)
	return note


func _configure_section_nav(kind: String) -> void:
	var compat_labels := {
		"overview": "概览",
		"operations": "需求" if kind == "cohort" else \
			"人物与分支" if kind == "family" else "经营" if kind == "building" \
			else "供需",
		"effects": "效果",
	}
	var visible_count := 0
	for section_id in _section_buttons:
		var button := _section_buttons[section_id] as Button
		button.text = String(compat_labels.get(section_id, section_id))
		button.visible = _section_targets.has(section_id)
		visible_count += 1 if button.visible else 0
	_section_nav.visible = visible_count > 1

	if _chapter_nav == null:
		return
	var chapters: Array = []
	if kind == "good":
		chapters = [
			{"id": "overview", "label": "供需与价格", "icon": &"metric.goods",
				"question": "本地供需是否平衡？当前价格相对成本锚偏离多少？"},
			{"id": "operations", "label": "贸易与税率", "icon": &"tax.tariff",
				"question": "跨区调入调出多少？交易税与关税如何设定？"},
		]
	elif kind == "cohort":
		chapters = [
			{"id": "overview", "label": "民生与收支", "icon": &"population.heart",
				"question": "该阶层生活水平处于哪一档？满意度短板与日常收支如何？"},
			{"id": "operations", "label": "消费与税率", "icon": &"metric.goods",
				"question": "日常支出花在哪些物资上？本阶层所得税如何设定？"},
		]
	elif kind == "building":
		chapters = [
			{"id": "overview", "label": "生产与岗位", "icon": &"economy.building.factory",
				"question": "产能出力与岗位到岗如何？有哪些投入与产出？"},
			{"id": "operations", "label": "财务与税率", "icon": &"metric.treasury",
				"question": "本期营收、自用留存与成本构成如何？营业税率如何设定？"},
		]
	else:
		var icon_map := {
			"overview": &"summary.overview",
			"operations": &"economy.building.factory",
			"effects": &"trend.up",
		}
		for section_id in ["overview", "operations", "effects"]:
			if _section_targets.has(section_id):
				chapters.append({
					"id": section_id,
					"label": String(compat_labels.get(section_id, section_id)),
					"icon": icon_map.get(section_id, &"summary.overview"),
					"question": "",
				})
	_chapter_nav.visible = chapters.size() > 1
	if chapters.size() > 1:
		_chapter_nav.set_chapters(chapters, _current_chapter)


func _on_chapter_selected(section_id: String) -> void:
	if _payload_kind in ["good", "cohort", "building"]:
		_apply_dossier_chapter(section_id, true)
		return
	if _chapter_nav != null and _chapter_nav.visible:
		_chapter_nav.select(section_id, true)
	_scroll_to_section(section_id)


func _apply_dossier_chapter(section_id: String, animate: bool) -> void:
	if _scroll != null and _current_chapter != section_id:
		_scroll_by_chapter[_current_chapter] = _scroll.scroll_vertical
	_current_chapter = section_id if (section_id == "overview" or section_id == "operations") else "overview"
	if _chapter_nav != null and _chapter_nav.visible:
		_chapter_nav.select(_current_chapter, animate)
	var refs := _good_refs if _payload_kind == "good" \
		else (_cohort_refs if _payload_kind == "cohort" else _building_refs)
	var overview_page := refs.get("overview_page") as Control
	var operations_page := refs.get("operations_page") as Control
	if overview_page != null:
		overview_page.visible = _current_chapter == "overview"
	if operations_page != null:
		operations_page.visible = _current_chapter == "operations"
	var active_page := overview_page if _current_chapter == "overview" else operations_page
	if animate and active_page != null:
		_replay_page_charts(active_page)
	if _scroll != null:
		var next_scroll := int(_scroll_by_chapter.get(_current_chapter, 0))
		_scroll.scroll_vertical = next_scroll
		if animate:
			call_deferred("_restore_scroll", next_scroll)


func _replay_page_charts(node: Node) -> void:
	if node == null:
		return
	if node is DossierChart:
		(node as DossierChart).replay_growth()
		(node as DossierChart)._start_animation()
	for child in node.get_children():
		_replay_page_charts(child)


func _scroll_to_section(section_id: String) -> void:
	if _scroll == null or not _section_targets.has(section_id):
		return
	call_deferred("_ensure_section_visible", section_id)


func _ensure_section_visible(section_id: String) -> void:
	var target := _section_targets.get(section_id) as Control
	if target != null and is_instance_valid(target):
		_scroll.ensure_control_visible(target)


func _restore_scroll(value: int) -> void:
	if _scroll != null:
		_scroll.scroll_vertical = value


# ─── 测试钩子 ────────────────────────────────────────────────────────────

func title_text() -> String:
	return _title_label.text if _title_label != null else ""


func subtitle_text() -> String:
	return _subtitle_label.text if _subtitle_label != null else ""


func fact_grid_columns() -> Array[int]:
	return _fact_columns.duplicate()


func current_chapter() -> String:
	return _current_chapter
