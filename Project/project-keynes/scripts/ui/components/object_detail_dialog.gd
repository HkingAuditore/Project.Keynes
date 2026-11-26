class_name ObjectDetailDialog
extends Control

const DetailLayout = preload("res://scripts/ui/components/object_detail_layout.gd")

const EstateDetails = preload("res://scripts/ui/components/object_estate_details.gd")

const CohortDetails = preload("res://scripts/ui/components/object_cohort_details.gd")

const GoodDetails = preload("res://scripts/ui/components/object_good_details.gd")

const LedgerFacts = preload("res://scripts/ui/components/dossier_ledger_facts.gd")
const ObjectDetailTaxGroup = preload("res://scripts/ui/components/object_detail_tax_group.gd")

const FactGridScene := preload("res://scenes/ui/object_fact_grid.tscn")
const FactCellScene := preload("res://scenes/ui/object_fact_cell.tscn")
const RowsCardScene := preload("res://scenes/ui/object_rows_card.tscn")
const DetailLineScene := preload("res://scenes/ui/object_detail_line.tscn")
const StateCardScene := preload("res://scenes/ui/object_state_card.tscn")
const NoteScene := preload("res://scenes/ui/object_note.tscn")
const ActionButtonScene := preload("res://scenes/ui/object_action_button.tscn")
const TaxSectionScene := preload("res://scenes/ui/object_tax_section.tscn")
## NativeCountryRuntime::TaxKind：income 0 / transaction 1 / business 2 / import 3 / export 4。
## 整组设值时按「当前这一节是什么」推税种，不再写死营业税（原来写死 2，
## 阶层和物资的整组入口根本出不来）。
const TAX_KIND_BY_SECTION := {"cohort": 0, "good": 1, "building": 2}
## 被查看的对象决定整组轴的主体：建筑给时代/产物/产品线/产业/生产档位，
## 物资给三层/时代/产品线/产业，阶层给阶层/产业（tax_group_map.gd 的 SUBJECT_AXES）。
const TAX_GROUP_SUBJECT_BY_KIND := {
	"cohort": "profession", "good": "good", "building": "building",
}
## 「全部」分组轴的 id，与 inspector_panel.TAX_GROUP_ALL_MODE 对齐。
const TAX_GROUP_ALL_MODE := "all_items"
const TAX_MODE_PERCENT_BP := 0
## 整组税率输入框：走场景实例化，不在脚本里造控件
## （ui_scene_structure_test.gd 的静态场景规矩；world_setup.gd:6 同款做法）。
const RateFieldScene := preload("res://scenes/ui/setup_spin.tscn")
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
## 「整组设为」的能力宿主（inspector 面板）。与 `_build_tax_section` 的 `host`
## 分开：那个只决定税节挂到哪一页，这个提供 tax_group_axes / tax_group_ids_for /
## request_tax_group_override。基线把两件事塞进同一个变量，而三次调用传的都是
## %OperationsPage 这个 VBoxContainer，守卫里的 has_method 恒假，三个档案的整组
## 入口从那时起就没渲染过。允许为 null（dialog 复用/重建时宿主可能没就绪）。
var _tax_group_host: Control = null


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
		"good": return "物资"
		"cohort": return "阶层"
		"building": return "建筑"
		"resource": return "自然资源"
		"family": return "家族分支"
		_: return ""


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
	# 可用时不写常驻说明：待生效状态由税行自己的注脚给出（见 TaxLaneEditor._refresh_note）。
	var reason := "" if bool(context.get("available", true)) \
			else String(context.get("reason", ""))
	hint.text = reason
	hint.visible = not reason.is_empty()
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
	return LedgerFacts._good_ledger_facts(row)


func _cohort_ledger_facts(row: Dictionary) -> Array:
	return LedgerFacts._cohort_ledger_facts(row)


func _facts_for_row(kind: String, row: Dictionary) -> Array:
	match kind:
		"cohort":
			return _cohort_ledger_facts(row)
		"building":
			return [
				{"label": "栋数", "value": String(row.get("count", "—")), "accent": UITokens.DOSSIER_INK},
				{"label": "状态", "value": String(row.get("status", "—")), "accent": _dossier_accent(row.get("accent", UITokens.DOSSIER_INK))},
				{"label": String(row.get("profit_label", "净额")), "value": String(row.get("profit", "—")),
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
				{"label": "创立日", "value": WorldClock.date_text_for_day(int(row.get("founded_day", 0))), "accent": UITokens.DOSSIER_INK_SOFT},
				{"label": "衰退复核", "value": "%d 次" % int(row.get("decline_reviews", 0)), "accent": UITokens.DOSSIER_INK_MUTED},
				{"label": "本地威望", "value": "%s · %s" % [
					["0", "I", "II", "III", "IV", "V"][clampi(int(row.get("prestige_level", 0)), 0, 5)],
					String(row.get("prestige_score", "0.0%"))], "accent": UITokens.DOSSIER_OXBLOOD},
			]
	return []


func _patch_fact_values(facts: Array) -> void:
	if _fact_value_labels.is_empty():
		return
	var count := mini(facts.size(), _fact_value_labels.size())
	var overflow := facts.size() - _fact_value_labels.size()
	for index in range(_fact_value_labels.size()):
		var value := _fact_value_labels[index] as Label
		if value == null or not is_instance_valid(value):
			continue
		value.visible = index < count
		if index >= count:
			continue
		var fact: Dictionary = facts[index]
		value.text = String(fact.get("value", "—"))
		value.tooltip_text = ("另有 %d 项" % overflow) \
			if (overflow > 0 and index == count - 1) else ""
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
	var reason := "" if bool(context.get("available", true)) \
			else String(context.get("reason", ""))
	hint.text = reason
	hint.visible = not reason.is_empty()
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
	# 整组调税：把一条税率一次写到全国同一组项目。
	# 组从宿主的 tax_group_axes / tax_group_ids_for 取；宿主按国家税快照给 id，
	# 不会发出「目录里有、税表里没有」那种会被整批拒的 id。
	# 与上面的单条编辑作用域不同——单条只改本格，整组改全国一大片。
	var section_tax_kind := int(TAX_KIND_BY_SECTION.get(kind, -1))
	# 能力宿主是 inspector 面板（set_tax_group_host），不是这块内容容器。
	# `editable` 必须留着：格子被锁的时候不给整组入口。
	# is_instance_valid：dialog 复用/重建时宿主可能已被释放，别在 has_method 上崩。
	var group_host := _tax_group_host
	if section_tax_kind >= 0 and editable \
			and is_instance_valid(group_host) and group_host != null \
			and group_host.has_method("tax_group_axes") \
			and group_host.has_method("tax_group_ids_for") \
			and group_host.has_method("request_tax_group_override"):
		var target_item_id := ""
		var prefill_rate := 0
		for raw_lane in item_lanes:
			var probe: Dictionary = raw_lane
			if String(probe.get("scope", "item")) != "item":
				continue
			target_item_id = String(probe.get("item_id", ""))
			if int(probe.get("mode", TAX_MODE_PERCENT_BP)) == TAX_MODE_PERCENT_BP:
				prefill_rate = int(probe.get("base", 0))
			break
		if not target_item_id.is_empty():
			_add_tax_group_controls(lanes, kind, section_tax_kind,
				target_item_id, prefill_rate, group_host)
	lanes.visible = not item_lanes.is_empty()


func _add_tax_group_controls(parent: VBoxContainer, kind: String,
		section_tax_kind: int, target_item_id: String, prefill_rate: int,
		host: Control) -> void:
	ObjectDetailTaxGroup.add_controls(parent,
		String(TAX_GROUP_SUBJECT_BY_KIND.get(kind, "building")),
		section_tax_kind, target_item_id, prefill_rate, host)


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


func set_embedded(embedded: bool = true) -> void:
	_embedded = embedded
	_apply_embedded_chrome(embedded)
	update_minimum_size()


## 谁来提供「整组设为」的能力（inspector 面板）。传 null 是合法状态：
## dialog 复用或宿主重建时可能先清空，守卫里还有 is_instance_valid 与 has_method。
func set_tax_group_host(host: Control) -> void:
	_tax_group_host = host


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
	GoodDetails._build_good_details(self, row, tax_context)


func _patch_good_dossier(row: Dictionary) -> void:
	GoodDetails._patch_good_dossier(self, row)


func _apply_good_dossier_data(row: Dictionary, live_patch: bool) -> void:
	GoodDetails._apply_good_dossier_data(self, row, live_patch)


func _trade_order_columns() -> Array:
	return GoodDetails._trade_order_columns(self)


func _apply_trade_orders(model_value: Variant) -> void:
	GoodDetails._apply_trade_orders(self, model_value)


func _request_trade_orders_page(step: int) -> void:
	GoodDetails._request_trade_orders_page(self, step)


func _on_trade_order_row_selected(row_id: Variant) -> void:
	GoodDetails._on_trade_order_row_selected(self, row_id)


func trade_orders_row_count() -> int:
	return GoodDetails.trade_orders_row_count(self)


func trade_orders_hint_text() -> String:
	return GoodDetails.trade_orders_hint_text(self)


func trade_orders_offset() -> int:
	return GoodDetails.trade_orders_offset(self)


func trade_orders_page_text() -> String:
	return GoodDetails.trade_orders_page_text(self)


func current_trade_orders_model() -> Dictionary:
	return GoodDetails.current_trade_orders_model(self)


func _build_cohort_details(row: Dictionary, tax_context: Variant) -> void:
	CohortDetails._build_cohort_details(self, row, tax_context)


func _patch_cohort_dossier(row: Dictionary) -> void:
	CohortDetails._patch_cohort_dossier(self, row)


func _sync_cohort_radar_split() -> void:
	CohortDetails._sync_cohort_radar_split(self)


func _apply_cohort_dossier_data(row: Dictionary, live_patch: bool) -> void:
	CohortDetails._apply_cohort_dossier_data(self, row, live_patch)


# ─── 其他详情区（建筑/自然资源/家族回退） ───────────────────────────────

func _build_building_details(row: Dictionary, tax_context: Variant = {}) -> void:
	EstateDetails._build_building_details(self, row, tax_context)


func _patch_building_dossier(row: Dictionary) -> void:
	EstateDetails._patch_building_dossier(self, row)


func _apply_building_dossier_data(row: Dictionary, live_patch: bool) -> void:
	EstateDetails._apply_building_dossier_data(self, row, live_patch)


func _build_resource_details(row: Dictionary) -> void:
	EstateDetails._build_resource_details(self, row)


func _build_family_details(row: Dictionary) -> void:
	EstateDetails._build_family_details(self, row)


func _add_branch_colonization_buttons(family_handle: int, branches: Array) -> Control:
	return EstateDetails._add_branch_colonization_buttons(self, family_handle, branches)


func _delta_accent(delta: String) -> Color:
	return EstateDetails._delta_accent(self, delta)


func _add_fact_grid(facts: Array) -> Control:
	return DetailLayout._add_fact_grid(self, facts)


static func _balanced_fact_columns(fact_count: int) -> int:
	return DetailLayout._balanced_fact_columns(fact_count)


func _fact_columns_for_width(fact_count: int, width: float) -> int:
	return DetailLayout._fact_columns_for_width(self, fact_count, width)


func _content_width() -> float:
	return DetailLayout._content_width(self)


func _on_dialog_resized() -> void:
	DetailLayout._on_dialog_resized(self)


func _fit_embedded_layout() -> void:
	DetailLayout._fit_embedded_layout(self)


func _constrain_autowrap(node: Node) -> void:
	DetailLayout._constrain_autowrap(self, node)


func _fit_fact_grids() -> void:
	DetailLayout._fit_fact_grids(self)


func _add_rows_card(title_text: String, icon_key: String, accent: Color,
		rows: Array) -> Control:
	return DetailLayout._add_rows_card(self, title_text, icon_key, accent, rows)


func _add_muted_note(text: String, color: Color = UITokens.DOSSIER_INK_MUTED) -> Control:
	return DetailLayout._add_muted_note(self, text, color)


func _configure_section_nav(kind: String) -> void:
	DetailLayout._configure_section_nav(self, kind)


func _on_chapter_selected(section_id: String) -> void:
	DetailLayout._on_chapter_selected(self, section_id)


func _apply_dossier_chapter(section_id: String, animate: bool) -> void:
	DetailLayout._apply_dossier_chapter(self, section_id, animate)


func _replay_page_charts(node: Node) -> void:
	DetailLayout._replay_page_charts(self, node)


func _scroll_to_section(section_id: String) -> void:
	DetailLayout._scroll_to_section(self, section_id)


func _ensure_section_visible(section_id: String) -> void:
	DetailLayout._ensure_section_visible(self, section_id)


func _restore_scroll(value: int) -> void:
	DetailLayout._restore_scroll(self, value)


# ─── 测试钩子 ────────────────────────────────────────────────────────────

func title_text() -> String:
	return _title_label.text if _title_label != null else ""


func subtitle_text() -> String:
	return _subtitle_label.text if _subtitle_label != null else ""


func fact_grid_columns() -> Array[int]:
	return _fact_columns.duplicate()


func current_chapter() -> String:
	return _current_chapter
