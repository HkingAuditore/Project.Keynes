extends Control
class_name EconomyWorkspace

const MetricCardScript = preload("res://scripts/ui/components/metric_card.gd")
const CategoryTabsScript = preload("res://scripts/ui/components/category_tabs.gd")

const PAGE_IDS := ["treasury", "income", "consumption", "business", "tariff"]
const PAGE_DEFINITIONS := {
	"treasury": {"label": "国库", "icon": &"metric.treasury", "accent": UITokens.RESOURCE},
	"income": {"label": "所得税", "icon": &"tax.income", "accent": UITokens.ACCENT},
	"consumption": {"label": "消费税", "icon": &"tax.consumption", "accent": UITokens.GOOD},
	"business": {"label": "营业税", "icon": &"tax.business", "accent": UITokens.CLIMATE},
	"tariff": {"label": "关税", "icon": &"tax.tariff", "accent": UITokens.WATER},
}
const TAX_KIND := {"income": 0, "consumption": 1, "business": 2, "import": 3, "export": 4}
const KIND_LABELS := {"import": "进口", "export": "出口"}
const CARD_SIZE := Vector2(240.0, 0.0)
const HOVER_TINT := Color(1.10, 1.08, 1.03, 1.0)
const ENTRANCE_STAGGER := 0.022
const ENTRANCE_MAX_DELAY := 0.30
# The simulation can advance dozens of days per real second. Summary cards are
# reading instruments, so coalesce those bursts while retaining the newest
# authoritative snapshot for the trailing refresh.
const LIVE_REFRESH_INTERVAL_MSEC := 200

var _cash_card: MetricCard
var _tax_card: MetricCard
var _subsidy_card: MetricCard
var _fulfillment_card: MetricCard
var _country_label: Label
var _day_label: Label
var _status_label: Label
var _search: LineEdit
var _overrides_only: Button
var _tabs: CategoryTabs
var _tab_signature := ""
var _scroll: ScrollContainer
var _flow: HFlowContainer
var _empty_label: Label
var _rows: Dictionary = {}
var _model: Dictionary = {}
var _page := "treasury"
var _pending: Dictionary = {}
var _preview_defaults: Dictionary = {}
var _sequence := 1
var _refresh_dirty := false
var _has_rendered_model := false
var _last_render_msec := 0


func _ready() -> void:
	if _cash_card != null:
		return
	set_process(false)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", UITokens.SPACE_SM)
	add_child(column)

	var header := HBoxContainer.new()
	header.custom_minimum_size.y = 28.0
	header.add_theme_constant_override("separation", UITokens.SPACE_SM)
	column.add_child(header)
	var section_badge := IconBadge.new()
	section_badge.custom_minimum_size = Vector2(24.0, 26.0)
	section_badge.set_semantic(&"tax.section", UITokens.BRASS_HIGHLIGHT)
	header.add_child(section_badge)
	var title := Label.new()
	title.text = "国家财政"
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", UITokens.font_with_weight(700))
	title.add_theme_font_size_override("font_size", UITokens.FONT_SECTION)
	header.add_child(title)
	_country_label = Label.new()
	_country_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_country_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_country_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	header.add_child(_country_label)
	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_spacer)
	_day_label = Label.new()
	_day_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_day_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_day_label.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	header.add_child(_day_label)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", UITokens.SPACE_SM)
	column.add_child(cards)
	_cash_card = _make_card(cards)
	_tax_card = _make_card(cards)
	_subsidy_card = _make_card(cards)
	_fulfillment_card = _make_card(cards)

	_tabs = CategoryTabsScript.new()
	_tabs.tab_selected.connect(_select_page)
	column.add_child(_tabs)

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", UITokens.SPACE_SM)
	column.add_child(tools)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索职业、物资或建筑"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_apply_filter.unbind(1))
	tools.add_child(_search)
	_overrides_only = _make_chip("仅看覆盖项")
	_overrides_only.toggled.connect(_apply_filter.unbind(1))
	tools.add_child(_overrides_only)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_status_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	column.add_child(_status_label)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_scroll)
	_flow = HFlowContainer.new()
	_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_flow.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
	_flow.add_theme_constant_override("v_separation", UITokens.SPACE_SM)
	_scroll.add_child(_flow)
	_empty_label = Label.new()
	_empty_label.text = "没有符合条件的项目"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.custom_minimum_size.x = 560.0
	_empty_label.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	_flow.add_child(_empty_label)
	_select_page("treasury")


func _make_card(parent: Control) -> MetricCard:
	var card: MetricCard = MetricCardScript.new()
	card.custom_minimum_size = Vector2(150.0, 72.0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(card)
	return card


func _make_chip(label: String) -> Button:
	var chip := Button.new()
	chip.text = label
	chip.toggle_mode = true
	chip.focus_mode = Control.FOCUS_NONE
	chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	chip.custom_minimum_size = Vector2(0.0, 28.0)
	chip.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	chip.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	chip.add_theme_color_override("font_hover_color", UITokens.TEXT_MAIN)
	chip.add_theme_color_override("font_pressed_color", UITokens.BRASS_HIGHLIGHT)
	chip.add_theme_stylebox_override("normal", UITokens.button_style(
		Color(0.075, 0.066, 0.052, 0.94), UITokens.PANEL_BORDER_SOFT))
	chip.add_theme_stylebox_override("hover", UITokens.button_style(
		UITokens.WALNUT_SOFT, UITokens.PANEL_BORDER))
	chip.add_theme_stylebox_override("pressed", UITokens.button_style(
		UITokens.ACCENT_SOFT, UITokens.BRASS_HIGHLIGHT, UITokens.RADIUS_SM, true))
	chip.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return chip


func set_model(model: Dictionary) -> void:
	if _cash_card == null:
		_ready()
	_preview_defaults.clear()
	_model = model
	# Opening/switching to the workspace must paint immediately. Only repeated
	# live-tick patches are coalesced.
	_apply_model(Time.get_ticks_msec())


func refresh_model(model: Dictionary) -> void:
	if _cash_card == null:
		_ready()
	_model = model
	var now := Time.get_ticks_msec()
	var live_day := int(model.get("current_day", -1))
	if _has_rendered_model and live_day >= 0 \
			and now - _last_render_msec < LIVE_REFRESH_INTERVAL_MSEC:
		_refresh_dirty = true
		set_process(true)
		return
	_apply_model(now)


func _process(_delta: float) -> void:
	if not _refresh_dirty:
		set_process(false)
		return
	var now := Time.get_ticks_msec()
	if now - _last_render_msec < LIVE_REFRESH_INTERVAL_MSEC:
		return
	_apply_model(now)


func _apply_model(now_msec: int) -> void:
	_refresh_dirty = false
	_has_rendered_model = true
	_last_render_msec = now_msec
	set_process(false)
	var treasury: Dictionary = _model.get("treasury", {})
	var fiscal: Dictionary = _model.get("fiscal", {})
	_resolve_pending_commands()
	var available := bool(_model.get("available", false))
	var collected := _sum_i64(fiscal.get("collected", PackedInt64Array()))
	var subsidy := _sum_i64(fiscal.get("subsidy_paid", PackedInt64Array()))
	var requested := _sum_i64(fiscal.get("subsidy_requested", PackedInt64Array()))
	var fulfillment := 1.0 if requested <= 0 else float(subsidy) / float(requested)
	_cash_card.set_data("国库现金",
		String(treasury.get("cash_text", "—")) if available else "—",
		String(_model.get("country_name", "玩家国家")), UITokens.RESOURCE, "", "metric.treasury")
	_tax_card.set_data("上批税收", _money(collected), "所得税 / 消费税 / 营业税",
		UITokens.BRASS_HIGHLIGHT, "", "tax.section")
	_subsidy_card.set_data("补贴实付", _money(subsidy), "由财政预留支付",
		UITokens.CLIMATE, "", "tax.income")
	_fulfillment_card.set_data("补贴兑现率", "%.1f%%" % (fulfillment * 100.0),
		"首次启用时预算建立中" if requested > 0 and subsidy == 0 else "上批申请",
		UITokens.ACCENT, "", "tax.default")
	_country_label.text = String(_model.get("country_name", ""))
	var day := int(_model.get("current_day", -1))
	_day_label.text = "第 %d 天" % (day + 1) if day >= 0 else ""
	_day_label.visible = day >= 0
	_refresh_tabs()
	_refresh_page()


func _refresh_tabs() -> void:
	var presentation: Dictionary = _model.get("tax_presentation", {})
	var treasury: Dictionary = _model.get("treasury", {})
	var signature_parts: Array[String] = []
	var tabs: Array = []
	for page in PAGE_IDS:
		var definition: Dictionary = PAGE_DEFINITIONS[page]
		var tooltip := String(definition.label)
		if page == "treasury":
			var good_count := int(treasury.get("nonzero_good_count", 0))
			tooltip = "国库 · %d 种物资" % good_count
			signature_parts.append("%s:%d" % [page, good_count])
		else:
			var page_pres: Dictionary = presentation.get(_presentation_key(page), {})
			var unlocked_count := (page_pres.get("unlocked", []) as Array).size()
			var total := int(page_pres.get("total_count", 0))
			tooltip = "%s · 已解锁 %d/%d" % [String(definition.label), unlocked_count, total]
			signature_parts.append("%s:%d:%d" % [page, unlocked_count, total])
		tabs.append({"id": page, "label": String(definition.label),
			"icon": definition.icon, "tooltip": tooltip})
	var signature := "|".join(signature_parts)
	if signature == _tab_signature and _tabs.get_child_count() > 0:
		return
	_tab_signature = signature
	_tabs.set_tabs(tabs, _page, true)


func _select_page(page: String) -> void:
	_page = page
	if _tabs != null:
		_tabs.select_tab(page)
	if _search != null:
		_search.visible = page != "treasury"
		_overrides_only.visible = page != "treasury"
	_refresh_page()
	_animate_cards_in()


# Visibility is synced from a wanted-set instead of hide-all-then-reshow, so a
# daily tick never toggles a stable card and never steals focus from a SpinBox
# the player is editing (hiding a focused control releases its focus).
func _refresh_page() -> void:
	if _flow == null or _model.is_empty():
		return
	var wanted := {}
	if _page == "treasury":
		_apply_goods((_model.get("treasury", {}) as Dictionary).get("goods", []), wanted)
		_sync_visibility(wanted)
		_set_status("")
		return
	var policy: Dictionary = _model.get("tax_policy", {})
	if not bool(policy.get("ok", false)):
		_sync_visibility(wanted)
		_empty_label.visible = false
		_set_status(String(policy.get("reason", "税收政策暂不可用")))
		return
	var presentation: Dictionary = _model.get("tax_presentation", {})
	var page_pres: Dictionary = presentation.get(_presentation_key(_page), {})
	var defaults: PackedInt32Array = policy.get("default_rates", PackedInt32Array())
	var default_card := _ensure_card(_page, "__default__", _default_title(),
		String(&"tax.default"), true)
	var default_data := {}
	for kind in _page_kinds(_page):
		var kind_id := int(TAX_KIND[kind])
		default_data[kind] = {"base": int(defaults[kind_id]),
			"effective": int(defaults[kind_id]), "has_override": false}
	_update_card(default_card, default_data)
	wanted["%s:__default__" % _page] = true
	var index_by_id := {}
	var ids := _item_ids(policy)
	for index in range(ids.size()):
		index_by_id[String(ids[index])] = index
	var kind_groups := {}
	for kind in _page_kinds(_page):
		kind_groups[kind] = policy.get(kind, {})
	var unlocked: Array = page_pres.get("unlocked", [])
	for item_value in unlocked:
		var item: Dictionary = item_value
		var stable_id := String(item.get("id", ""))
		if not index_by_id.has(stable_id):
			continue
		var index: int = index_by_id[stable_id]
		var kind_data := {}
		var complete := true
		for kind in _page_kinds(_page):
			var group: Dictionary = kind_groups[kind]
			var rates: PackedInt32Array = group.get("rates", PackedInt32Array())
			if index >= rates.size():
				complete = false
				break
			var effective: PackedInt32Array = group.get("effective_rates", rates)
			var flags: PackedByteArray = group.get("has_override", PackedByteArray())
			kind_data[kind] = {
				"base": int(rates[index]),
				"effective": int(effective[index]) if index < effective.size() \
					else int(rates[index]),
				"has_override": index < flags.size() and flags[index] != 0,
			}
		if not complete:
			continue
		var card := _ensure_card(_page, stable_id,
			String(item.get("display_name", stable_id)),
			String(item.get("icon_key", "")), false)
		_update_card(card, kind_data)
		wanted["%s:%s" % [_page, stable_id]] = true
	_sync_visibility(wanted)
	_set_status("待跨国贸易接入：当前事件数与金额恒为零" if _page == "tariff" else "", true)
	_apply_filter()


func _sync_visibility(wanted: Dictionary) -> void:
	for row_value in _rows.values():
		var card: Dictionary = row_value
		var control := card.control as Control
		var should_show := wanted.has("%s:%s" % [String(card.page), String(card.item_id)])
		if control.visible != should_show:
			control.visible = should_show


# The tariff page merges import and export onto one card per good; both kinds
# share the goods catalog, so the import lane carries the merged presentation.
func _presentation_key(page: String) -> String:
	return "import" if page == "tariff" else page


func _page_kinds(page: String) -> Array:
	return ["import", "export"] if page == "tariff" else [page]


func _kind_page(kind: String) -> String:
	return "tariff" if kind == "import" or kind == "export" else kind


func _default_title() -> String:
	return "默认进出口税率" if _page == "tariff" else "默认税率"


func _item_ids(policy: Dictionary) -> PackedStringArray:
	if _page == "income":
		return policy.get("profession_ids", PackedStringArray())
	if _page == "business":
		return policy.get("building_type_ids", PackedStringArray())
	return policy.get("good_ids", PackedStringArray())


func _ensure_card(page: String, item_id: String, label: String,
		icon_key: String, is_default: bool) -> Dictionary:
	var key := "%s:%s" % [page, item_id]
	if _rows.has(key):
		return _rows[key]
	var accent: Color = (PAGE_DEFINITIONS[page] as Dictionary).get("accent", UITokens.ACCENT)
	var panel := PanelContainer.new()
	panel.name = "Tax_%s_%s" % [page, item_id]
	panel.custom_minimum_size = CARD_SIZE
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var kinds := _page_kinds(page)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UITokens.SPACE_XS)
	panel.add_child(body)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UITokens.SPACE_SM)
	body.add_child(head)
	var badge := IconBadge.new()
	badge.custom_minimum_size = Vector2(26.0, 28.0)
	badge.set_semantic(StringName(icon_key), accent)
	head.add_child(badge)
	var name_label := Label.new()
	name_label.text = label
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_override("font", UITokens.font_with_weight(600))
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	head.add_child(name_label)
	var sub_label := Label.new()
	sub_label.visible = false
	sub_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	sub_label.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	body.add_child(sub_label)
	if is_default:
		sub_label.text = "适用于所有未单独设置的项目"
		sub_label.visible = true
	var spins := {}
	var resets := {}
	var pendings := {}
	for kind in kinds:
		var kind_row := HBoxContainer.new()
		kind_row.add_theme_constant_override("separation", UITokens.SPACE_XS)
		body.add_child(kind_row)
		if kinds.size() > 1:
			var kind_label := Label.new()
			kind_label.text = String(KIND_LABELS.get(kind, kind))
			kind_label.custom_minimum_size.x = 30.0
			kind_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			kind_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
			kind_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
			kind_row.add_child(kind_label)
		var spin := SpinBox.new()
		spin.min_value = -100
		spin.max_value = 100
		spin.step = 1
		spin.suffix = "%"
		spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spin.custom_minimum_size = Vector2(88.0, 30.0)
		spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
		spin.get_line_edit().text_submitted.connect(
			_on_rate_confirmed.bind(key, kind))
		spin.get_line_edit().focus_exited.connect(
			_on_rate_focus_exited.bind(key, kind))
		spin.value_changed.connect(_on_rate_preview.bind(key, kind))
		kind_row.add_child(spin)
		spins[kind] = spin
		var reset := Button.new()
		reset.focus_mode = Control.FOCUS_NONE
		reset.visible = false
		reset.custom_minimum_size = Vector2(24.0, 26.0)
		IconButton.apply(reset, &"action.reset", IconButton.SMALL, "重置为默认税率")
		reset.pressed.connect(_on_reset_pressed.bind(key, kind))
		kind_row.add_child(reset)
		resets[kind] = reset
		var clock_badge := IconBadge.new()
		clock_badge.custom_minimum_size = Vector2(18.0, 20.0)
		clock_badge.visible = false
		clock_badge.tooltip_text = "命令已确认，将于下一日生效"
		clock_badge.set_semantic(&"system.clock", UITokens.BRASS_HIGHLIGHT)
		kind_row.add_child(clock_badge)
		pendings[kind] = clock_badge
	_flow.add_child(panel)
	var result := {"control": panel, "name": name_label, "sub": sub_label,
		"spins": spins, "resets": resets, "pendings": pendings,
		"overridden": {}, "rates": {}, "kinds": kinds,
		"page": page, "item_id": item_id, "is_default": is_default,
		"accent": accent}
	_rows[key] = result
	_apply_card_frame(result, false)
	_watch_card_hover(panel)
	return result


func _update_card(card: Dictionary, kind_data: Dictionary) -> void:
	var signature_parts: Array[String] = []
	for kind in card.kinds:
		var data: Dictionary = kind_data.get(kind, {})
		var base := int(data.get("base", 0))
		var overridden := bool(data.get("has_override", false))
		var visual_rate := _visual_rate(card, kind, base, overridden)
		signature_parts.append("%d:%d:%d:%d:%d" % [
			base,
			visual_rate,
			int(data.get("effective", data.get("base", 0))),
			1 if overridden else 0,
			1 if _pending.has("%s:%s" % [kind, String(card.item_id)]) else 0,
		])
	var signature := "|".join(signature_parts)
	if signature == String(card.get("signature", "")):
		return
	card["signature"] = signature
	for kind in card.kinds:
		var data: Dictionary = kind_data.get(kind, {})
		var pending := _pending.has("%s:%s" % [kind, String(card.item_id)])
		((card.pendings as Dictionary)[kind] as Control).visible = pending
		if pending:
			# Awaiting next-day commit: keep the optimistic state staged at
			# submit time instead of snapping back to the stale authoritative rate.
			continue
		var base := int(data.get("base", 0))
		var effective := int(data.get("effective", base))
		var overridden := bool(data.get("has_override", false))
		var visual_rate := _visual_rate(card, kind, base, overridden)
		var spin := (card.spins as Dictionary)[kind] as SpinBox
		var line_edit := spin.get_line_edit()
		# Never overwrite the field the player is editing; _confirm_spin reads
		# the authoritative value back on focus loss / Enter.
		if not line_edit.has_focus():
			spin.set_value_no_signal(visual_rate)
			line_edit.add_theme_color_override("font_color",
				UITokens.BRASS_HIGHLIGHT \
					if overridden or visual_rate != base else UITokens.TEXT_MUTED)
		((card.resets as Dictionary)[kind] as Button).visible = overridden
		(card.overridden as Dictionary)[kind] = overridden
		(card.rates as Dictionary)[kind] = base
		if (card.kinds as Array).size() == 1 and not bool(card.is_default):
			var sub := card.sub as Label
			sub.visible = visual_rate == base and effective != base
			if sub.visible:
				sub.text = "修正后 %d%%" % effective
	_refresh_override_frame(card)


func _visual_rate(card: Dictionary, kind: String, authoritative_rate: int,
		overridden: bool) -> int:
	if bool(card.is_default) or not overridden:
		if _preview_defaults.has(kind):
			return int(_preview_defaults[kind])
		var pending_default: Dictionary = _pending.get(
			"%s:__default__" % kind, {})
		if pending_default.has("rate"):
			return int(pending_default.rate)
	return authoritative_rate


func _apply_card_frame(card: Dictionary, highlighted: bool) -> void:
	var accent: Color = card.accent
	var panel := card.control as PanelContainer
	var style := StyleBoxFlat.new()
	if bool(card.is_default):
		style.bg_color = Color(0.16, 0.12, 0.07, 0.96)
		style.border_color = Color(UITokens.BRASS_HIGHLIGHT.r,
			UITokens.BRASS_HIGHLIGHT.g, UITokens.BRASS_HIGHLIGHT.b, 0.55)
	elif highlighted:
		style.bg_color = Color(0.135, 0.104, 0.064, 0.98)
		style.border_color = Color(UITokens.BRASS_HIGHLIGHT.r,
			UITokens.BRASS_HIGHLIGHT.g, UITokens.BRASS_HIGHLIGHT.b, 0.85)
	else:
		style.bg_color = UITokens.CARD_BG
		style.border_color = Color(accent.r, accent.g, accent.b, 0.38)
	style.border_width_left = 3
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = UITokens.RADIUS_MD
	style.corner_radius_top_right = UITokens.RADIUS_MD
	style.corner_radius_bottom_left = UITokens.RADIUS_MD
	style.corner_radius_bottom_right = UITokens.RADIUS_MD
	style.content_margin_left = UITokens.SPACE_MD
	style.content_margin_top = UITokens.SPACE_SM
	style.content_margin_right = UITokens.SPACE_MD
	style.content_margin_bottom = UITokens.SPACE_SM
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.40)
	style.shadow_size = 7
	style.shadow_offset = Vector2(0.0, 3.0)
	style.anti_aliasing = true
	panel.add_theme_stylebox_override("panel", style)


func _watch_card_hover(panel: PanelContainer) -> void:
	panel.mouse_entered.connect(_lift_card.bind(panel, true))
	panel.mouse_exited.connect(_lift_card.bind(panel, false))


func _lift_card(panel: PanelContainer, entered: bool) -> void:
	if panel.has_meta("hover_tween"):
		(panel.get_meta("hover_tween") as Tween).kill()
	var tween := panel.create_tween()
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(panel, "self_modulate",
		HOVER_TINT if entered else Color.WHITE, UITokens.ANIM_FAST)
	panel.set_meta("hover_tween", tween)


# Every visible card fades in; only the stagger delay is capped, so large
# treasuries finish fast without leaving tail cards (e.g. 科技值) popping in
# with no motion at all.
func _animate_cards_in() -> void:
	if _flow == null or not is_inside_tree():
		return
	var shown := 0
	for child in _flow.get_children():
		if child == _empty_label or not (child as Control).visible:
			continue
		var control := child as Control
		control.modulate.a = 0.0
		var tween := control.create_tween()
		tween.tween_interval(minf(shown * ENTRANCE_STAGGER, ENTRANCE_MAX_DELAY))
		tween.tween_property(control, "modulate:a", 1.0, UITokens.ANIM_MED)
		shown += 1
	UIAnimation.crossfade(_scroll, UITokens.ANIM_FAST)


func _on_rate_confirmed(_text: String, key: String, kind: String) -> void:
	_confirm_spin(key, kind)


func _on_rate_focus_exited(key: String, kind: String) -> void:
	_confirm_spin(key, kind)


func _on_rate_preview(value: float, key: String, kind: String) -> void:
	var card: Dictionary = _rows.get(key, {})
	if card.is_empty() or not bool(card.is_default):
		return
	var rate := clampi(int(value), -100, 100)
	var authoritative := int((card.rates as Dictionary).get(kind, 0))
	if rate == authoritative and not _has_pending_default(kind):
		_preview_defaults.erase(kind)
	else:
		_preview_defaults[kind] = rate
	# Preview changes only presentation. The command remains confirmed on
	# Enter/focus loss and retains its next-day authoritative boundary.
	_refresh_page()


# Typing a rate is the override: a value equal to the inherited default clears
# the override instead, so no separate override toggle exists anywhere.
func _confirm_spin(key: String, kind: String) -> void:
	var card: Dictionary = _rows.get(key, {})
	if card.is_empty():
		return
	var spin := (card.spins as Dictionary)[kind] as SpinBox
	var rate := int(spin.value)
	var current := int((card.rates as Dictionary).get(kind, 0))
	var overridden := bool((card.overridden as Dictionary).get(kind, false))
	if bool(card.is_default):
		if rate != current or _preview_defaults.has(kind):
			_submit_rate(kind, String(card.item_id), rate, true)
		else:
			_preview_defaults.erase(kind)
			_refresh_page()
		return
	if not overridden and rate == _default_rate(kind):
		return
	if rate == current and not overridden:
		return
	var default_rate := _default_rate(kind)
	if rate == default_rate and overridden:
		_clear_override(kind, String(card.item_id))
	elif rate != current:
		_submit_rate(kind, String(card.item_id), rate, false)


func _default_rate(kind: String) -> int:
	if _preview_defaults.has(kind):
		return int(_preview_defaults[kind])
	var pending_default: Dictionary = _pending.get("%s:__default__" % kind, {})
	if pending_default.has("rate"):
		return int(pending_default.rate)
	var policy: Dictionary = _model.get("tax_policy", {})
	var defaults: PackedInt32Array = policy.get("default_rates", PackedInt32Array())
	var kind_id := int(TAX_KIND[kind])
	return int(defaults[kind_id]) if kind_id < defaults.size() else 0


func _on_reset_pressed(key: String, kind: String) -> void:
	var card: Dictionary = _rows.get(key, {})
	if card.is_empty():
		return
	_clear_override(kind, String(card.item_id))


func _clear_override(kind: String, item_id: String) -> void:
	var facade = _model.get("country_facade")
	if facade == null:
		return
	var result: Dictionary = facade.clear_tax_override(
		int(_model.get("country_handle", 0)),
		int(TAX_KIND[kind]), StringName(item_id), _effective_day(), _next_sequence())
	if bool(result.get("ok", false)):
		_mark_pending(kind, item_id)
		var card: Dictionary = _rows.get("%s:%s" % [_kind_page(kind), item_id], {})
		if not card.is_empty():
			var default_rate := _default_rate(kind)
			var spin := (card.spins as Dictionary)[kind] as SpinBox
			spin.set_value_no_signal(default_rate)
			spin.get_line_edit().add_theme_color_override("font_color", UITokens.TEXT_MUTED)
			(card.rates as Dictionary)[kind] = default_rate
			(card.overridden as Dictionary)[kind] = false
			((card.resets as Dictionary)[kind] as Button).visible = false
			_refresh_override_frame(card)
	else:
		_set_status(String(result.get("reason", "税率覆盖清除命令提交失败")))


func _submit_rate(kind: String, item_id: String, rate: int, is_default: bool) -> void:
	var facade = _model.get("country_facade")
	if facade == null:
		return
	var handle := int(_model.get("country_handle", 0))
	var result: Dictionary
	if is_default:
		result = facade.set_tax_default(handle, int(TAX_KIND[kind]), rate,
			_effective_day(), _next_sequence())
	else:
		result = facade.set_tax_override(handle, int(TAX_KIND[kind]),
			StringName(item_id), rate, _effective_day(), _next_sequence())
	if bool(result.get("ok", false)):
		if is_default:
			_preview_defaults.erase(kind)
		_mark_pending(kind, item_id, rate if is_default else 0)
		var card: Dictionary = _rows.get("%s:%s" % [_kind_page(kind), item_id], {})
		if not card.is_empty():
			var spin := (card.spins as Dictionary)[kind] as SpinBox
			spin.set_value_no_signal(rate)
			spin.get_line_edit().add_theme_color_override("font_color",
				UITokens.BRASS_HIGHLIGHT)
			(card.rates as Dictionary)[kind] = rate
			if not is_default:
				(card.overridden as Dictionary)[kind] = true
				((card.resets as Dictionary)[kind] as Button).visible = true
			_refresh_override_frame(card)
		if is_default:
			_refresh_page()
	else:
		if is_default:
			_preview_defaults.erase(kind)
			var card: Dictionary = _rows.get(
				"%s:__default__" % _kind_page(kind), {})
			if not card.is_empty():
				((card.spins as Dictionary)[kind] as SpinBox).set_value_no_signal(
					int((card.rates as Dictionary).get(kind, 0)))
			_refresh_page()
		_set_status(String(result.get("reason", "税率命令提交失败")))


func _refresh_override_frame(card: Dictionary) -> void:
	var any_override := false
	for value in (card.overridden as Dictionary).values():
		any_override = any_override or bool(value)
	(card.name as Label).add_theme_color_override("font_color",
		UITokens.BRASS_HIGHLIGHT.lerp(UITokens.TEXT_MAIN, 0.35) \
			if any_override else UITokens.TEXT_MAIN)
	_apply_card_frame(card, any_override)


func _mark_pending(kind: String, item_id: String,
		optimistic_rate: int = 0) -> void:
	var key := "%s:%s" % [kind, item_id]
	var policy: Dictionary = _model.get("tax_policy", {})
	_pending[key] = {
		"effective_day": _effective_day(),
		"policy_version": int(policy.get("policy_version", -1)),
	}
	if item_id == "__default__":
		(_pending[key] as Dictionary)["rate"] = optimistic_rate
	var card: Dictionary = _rows.get("%s:%s" % [_kind_page(kind), item_id], {})
	if not card.is_empty():
		((card.pendings as Dictionary)[kind] as Control).visible = true


func _has_pending_default(kind: String) -> bool:
	return _pending.has("%s:__default__" % kind)


func _resolve_pending_commands() -> void:
	var policy: Dictionary = _model.get("tax_policy", {})
	if not bool(policy.get("ok", false)):
		return
	var current_day := int(_model.get("current_day", -1))
	var current_version := int(policy.get("policy_version", -1))
	var resolved: Array[String] = []
	for key_value in _pending:
		var key := String(key_value)
		var pending: Dictionary = _pending[key]
		if current_day >= int(pending.get("effective_day", current_day + 1)) \
				and current_version > int(pending.get("policy_version", current_version)):
			resolved.append(key)
	for key in resolved:
		_pending.erase(key)
		var kind := key.get_slice(":", 0)
		var card: Dictionary = _rows.get(
			"%s:%s" % [_kind_page(kind), key.get_slice(":", 1)], {})
		if not card.is_empty() and (card.pendings as Dictionary).has(kind):
			((card.pendings as Dictionary)[kind] as Control).visible = false


func _effective_day() -> int:
	return int(_model.get("current_day", -1)) + 1


func _next_sequence() -> int:
	var result := _sequence
	_sequence += 1
	return result


func _apply_goods(goods: Array, wanted: Dictionary) -> void:
	for good_value in goods:
		var good: Dictionary = good_value
		var stable_id := String(good.get("id", ""))
		var key := "treasury:%s" % stable_id
		if not _rows.has(key):
			_rows[key] = _make_good_card(stable_id, String(good.get("icon", "")))
		var card: Dictionary = _rows[key]
		(card.name as Label).text = String(good.get("display_name", stable_id))
		(card.value as Label).text = String(good.get("quantity_text", "0"))
		wanted[key] = true
	_empty_label.text = "国库暂无物资"
	_empty_label.visible = goods.is_empty()


func _make_good_card(stable_id: String, icon_key: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "TreasuryGood_%s" % stable_id
	panel.custom_minimum_size = Vector2(210.0, 0.0)
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var style := StyleBoxFlat.new()
	style.bg_color = UITokens.CARD_BG
	style.border_color = Color(UITokens.GOOD.r, UITokens.GOOD.g, UITokens.GOOD.b, 0.34)
	style.border_width_left = 3
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = UITokens.RADIUS_MD
	style.corner_radius_top_right = UITokens.RADIUS_MD
	style.corner_radius_bottom_left = UITokens.RADIUS_MD
	style.corner_radius_bottom_right = UITokens.RADIUS_MD
	style.content_margin_left = UITokens.SPACE_MD
	style.content_margin_top = UITokens.SPACE_SM
	style.content_margin_right = UITokens.SPACE_MD
	style.content_margin_bottom = UITokens.SPACE_SM
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.40)
	style.shadow_size = 7
	style.shadow_offset = Vector2(0.0, 3.0)
	style.anti_aliasing = true
	panel.add_theme_stylebox_override("panel", style)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 2)
	panel.add_child(body)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UITokens.SPACE_SM)
	body.add_child(head)
	var badge := IconBadge.new()
	badge.custom_minimum_size = Vector2(24.0, 26.0)
	badge.set_semantic(StringName(icon_key), UITokens.GOOD)
	head.add_child(badge)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	name_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	head.add_child(name_label)
	var value_label := Label.new()
	value_label.add_theme_font_override("font", UITokens.font_with_weight(650))
	value_label.add_theme_font_size_override("font_size", 15)
	value_label.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	body.add_child(value_label)
	_flow.add_child(panel)
	_watch_card_hover(panel)
	return {"control": panel, "name": name_label, "value": value_label,
		"page": "treasury", "item_id": stable_id}


func _apply_filter() -> void:
	var needle := _search.text.strip_edges().to_lower()
	var visible_count := 0
	for row_value in _rows.values():
		var card: Dictionary = row_value
		if String(card.get("page", "")) != _page:
			continue
		var control := card.control as Control
		if bool(card.get("is_default", false)):
			control.visible = true
			visible_count += 1
			continue
		var matches := needle.is_empty() or String(card.item_id).to_lower().contains(needle) \
			or String((card.name as Label).text).to_lower().contains(needle)
		var any_override := false
		for kind in (card.overridden as Dictionary).keys():
			any_override = any_override or bool(card.overridden[kind])
		var override_ok := not _overrides_only.button_pressed or any_override
		control.visible = matches and override_ok
		if control.visible:
			visible_count += 1
	_empty_label.text = "没有符合条件的项目" if not needle.is_empty() \
		else "当前科技尚未解锁相关项目"
	_empty_label.visible = visible_count == 0


func _set_status(text: String, warn: bool = false) -> void:
	_status_label.text = text
	_status_label.visible = text != ""
	_status_label.add_theme_color_override("font_color",
		UITokens.WARN if warn else UITokens.TEXT_MUTED)


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _money(value: int) -> String:
	return UITokens.format_compact_number_cn(float(value) / 10000.0, 2)


func cash_text() -> String:
	if _cash_card == null:
		return ""
	var value_label := _cash_card.get("_value_label") as Label
	return value_label.text if value_label != null else ""


func tax_text() -> String:
	if _tax_card == null:
		return ""
	var value_label := _tax_card.get("_value_label") as Label
	return value_label.text if value_label != null else ""


func visible_good_count() -> int:
	var count := 0
	for row_value in _rows.values():
		var card: Dictionary = row_value
		if String(card.get("page", "")) == "treasury" \
				and (card.control as Control).visible:
			count += 1
	return count


func good_value_text(stable_id: String) -> String:
	var card: Dictionary = _rows.get("treasury:%s" % stable_id, {})
	return (card.value as Label).text if not card.is_empty() else ""


func good_row_instance_id(stable_id: String) -> int:
	var card: Dictionary = _rows.get("treasury:%s" % stable_id, {})
	return (card.control as Control).get_instance_id() if not card.is_empty() else 0


func select_page_for_test(page: String) -> void:
	if PAGE_IDS.has(page):
		_select_page(page)


func tax_row_count(page: String) -> int:
	var count := 0
	for row_value in _rows.values():
		var card: Dictionary = row_value
		if String(card.get("page", "")) == page:
			count += 1
	return count


func tax_row_instance_id(page: String, item_id: String) -> int:
	var card: Dictionary = _rows.get("%s:%s" % [page, item_id], {})
	return (card.control as Control).get_instance_id() if not card.is_empty() else 0


func tax_row_name_text(page: String, item_id: String) -> String:
	var card: Dictionary = _rows.get("%s:%s" % [page, item_id], {})
	return (card.name as Label).text if not card.is_empty() else ""


func tax_row_rate(page: String, item_id: String, kind: String) -> int:
	var card: Dictionary = _rows.get("%s:%s" % [page, item_id], {})
	if card.is_empty() or not (card.spins as Dictionary).has(kind):
		return 0
	return int(((card.spins as Dictionary)[kind] as SpinBox).value)


func preview_default_rate_for_test(page: String, kind: String, rate: int) -> void:
	var card: Dictionary = _rows.get("%s:__default__" % page, {})
	if not card.is_empty() and (card.spins as Dictionary).has(kind):
		((card.spins as Dictionary)[kind] as SpinBox).value = rate


func confirm_default_rate_for_test(page: String, kind: String) -> void:
	_confirm_spin("%s:__default__" % page, kind)


func pending_default_rate_for_test(kind: String) -> int:
	var pending: Dictionary = _pending.get("%s:__default__" % kind, {})
	return int(pending.get("rate", 1000))


func tax_status_text() -> String:
	return _status_label.text if _status_label != null else ""
