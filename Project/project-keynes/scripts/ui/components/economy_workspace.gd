extends Control
class_name EconomyWorkspace

const MetricCardScript = preload("res://scripts/ui/components/metric_card.gd")

const PAGE_IDS := ["treasury", "income", "consumption", "business", "import", "export"]
const PAGE_LABELS := ["国库", "所得税", "消费税", "营业税", "进口关税", "出口关税"]
const TAX_KIND := {"income": 0, "consumption": 1, "business": 2, "import": 3, "export": 4}

var _cash_card: MetricCard
var _tax_card: MetricCard
var _subsidy_card: MetricCard
var _fulfillment_card: MetricCard
var _status_label: Label
var _goods_count_label: Label
var _search: LineEdit
var _overrides_only: CheckBox
var _scroll: ScrollContainer
var _rows_box: VBoxContainer
var _empty_label: Label
var _default_row: Dictionary = {}
var _tab_buttons: Dictionary = {}
var _rows: Dictionary = {}
var _model: Dictionary = {}
var _page := "treasury"
var _pending: Dictionary = {}
var _sequence := 1


func _ready() -> void:
	if _cash_card != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", UITokens.SPACE_SM)
	add_child(column)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", UITokens.SPACE_SM)
	column.add_child(cards)
	_cash_card = _make_card(cards)
	_tax_card = _make_card(cards)
	_subsidy_card = _make_card(cards)
	_fulfillment_card = _make_card(cards)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", UITokens.SPACE_XS)
	column.add_child(tabs)
	for index in range(PAGE_IDS.size()):
		var button := Button.new()
		button.text = PAGE_LABELS[index]
		button.toggle_mode = true
		button.pressed.connect(_select_page.bind(PAGE_IDS[index]))
		tabs.add_child(button)
		_tab_buttons[PAGE_IDS[index]] = button

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", UITokens.SPACE_SM)
	column.add_child(tools)
	_search = LineEdit.new()
	_search.placeholder_text = "搜索职业、物资或建筑"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_apply_filter.unbind(1))
	tools.add_child(_search)
	_overrides_only = CheckBox.new()
	_overrides_only.text = "仅看覆盖项"
	_overrides_only.toggled.connect(_apply_filter.unbind(1))
	tools.add_child(_overrides_only)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	column.add_child(_status_label)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", UITokens.SPACE_XS)
	_scroll.add_child(_rows_box)

	_goods_count_label = Label.new()
	_goods_count_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_rows_box.add_child(_goods_count_label)
	_empty_label = Label.new()
	_empty_label.text = "没有符合条件的项目"
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
	_rows_box.add_child(_empty_label)
	_select_page("treasury")


func _make_card(parent: Control) -> MetricCard:
	var card: MetricCard = MetricCardScript.new()
	card.custom_minimum_size = Vector2(150.0, 72.0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(card)
	return card


func set_model(model: Dictionary) -> void:
	refresh_model(model)


func refresh_model(model: Dictionary) -> void:
	if _cash_card == null:
		_ready()
	_model = model
	var treasury: Dictionary = model.get("treasury", {})
	var fiscal: Dictionary = model.get("fiscal", {})
	_resolve_pending_commands()
	var available := bool(model.get("available", false))
	var collected := _sum_i64(fiscal.get("collected", PackedInt64Array()))
	var subsidy := _sum_i64(fiscal.get("subsidy_paid", PackedInt64Array()))
	var requested := _sum_i64(fiscal.get("subsidy_requested", PackedInt64Array()))
	var fulfillment := 1.0 if requested <= 0 else float(subsidy) / float(requested)
	_cash_card.set_data("国库现金",
		String(treasury.get("cash_text", "—")) if available else "—",
		String(model.get("country_name", "玩家国家")), UITokens.RESOURCE, "", "treasury")
	_tax_card.set_data("上批税收", _money(collected), "所得税 / 消费税 / 营业税",
		UITokens.BRASS_HIGHLIGHT, "", "treasury")
	_subsidy_card.set_data("补贴实付", _money(subsidy), "由财政预留支付",
		UITokens.CLIMATE, "", "treasury")
	_fulfillment_card.set_data("补贴兑现率", "%.1f%%" % (fulfillment * 100.0),
		"首次启用时预算建立中" if requested > 0 and subsidy == 0 else "上批申请",
		UITokens.ACCENT, "", "treasury")
	_refresh_page()


func _select_page(page: String) -> void:
	_page = page
	for id in _tab_buttons:
		(_tab_buttons[id] as Button).button_pressed = id == page
	if _search != null:
		_search.visible = page != "treasury"
		_overrides_only.visible = page != "treasury"
	_refresh_page()


func _refresh_page() -> void:
	if _rows_box == null or _model.is_empty():
		return
	_hide_all_rows()
	if _page == "treasury":
		_default_row = {}
		_apply_goods((_model.get("treasury", {}) as Dictionary).get("goods", []))
		_status_label.text = ""
		return
	var policy: Dictionary = _model.get("tax_policy", {})
	if not bool(policy.get("ok", false)):
		_status_label.text = String(policy.get("reason", "税收政策暂不可用"))
		return
	var kind := int(TAX_KIND[_page])
	var defaults: PackedInt32Array = policy.get("default_rates", PackedInt32Array())
	_default_row = _ensure_tax_row(_page, "__default__", "默认税率", true)
	_update_tax_row(_default_row, int(defaults[kind]), int(defaults[kind]), false, true)
	var group: Dictionary = policy.get(_page, {})
	var ids: PackedStringArray = _item_ids(policy, _page)
	var rates: PackedInt32Array = group.get("rates", PackedInt32Array())
	var effective: PackedInt32Array = group.get("effective_rates", rates)
	var flags: PackedByteArray = group.get("has_override", PackedByteArray())
	for index in range(mini(ids.size(), rates.size())):
		var stable_id := String(ids[index])
		var row := _ensure_tax_row(_page, stable_id, _display_name(stable_id), false)
		_update_tax_row(row, int(rates[index]),
			int(effective[index]) if index < effective.size() else int(rates[index]),
			index < flags.size() and flags[index] != 0, false)
	_status_label.text = "待跨国贸易接入：当前事件数与金额恒为零" \
		if _page == "import" or _page == "export" else ""
	_apply_filter()


func _item_ids(policy: Dictionary, page: String) -> PackedStringArray:
	if page == "income":
		return policy.get("profession_ids", PackedStringArray())
	if page == "business":
		return policy.get("building_type_ids", PackedStringArray())
	return policy.get("good_ids", PackedStringArray())


func _ensure_tax_row(page: String, item_id: String, label: String,
		is_default: bool) -> Dictionary:
	var key := "%s:%s" % [page, item_id]
	if _rows.has(key):
		var cached: Dictionary = _rows[key]
		(cached.control as Control).visible = true
		return cached
	var panel := PanelContainer.new()
	panel.name = "Tax_%s_%s" % [page, item_id]
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		UITokens.CARD_BG, Color(UITokens.RESOURCE.r, UITokens.RESOURCE.g,
			UITokens.RESOURCE.b, 0.35)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	panel.add_child(row)
	var name_label := Label.new()
	name_label.text = label
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var effective_label := Label.new()
	effective_label.custom_minimum_size.x = 116.0
	effective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(effective_label)
	var override := CheckBox.new()
	override.text = "覆盖"
	override.visible = not is_default
	override.toggled.connect(_on_override_toggled.bind(page, item_id))
	row.add_child(override)
	var spin := SpinBox.new()
	spin.min_value = -100
	spin.max_value = 100
	spin.step = 1
	spin.suffix = "%"
	spin.custom_minimum_size.x = 104.0
	spin.get_line_edit().text_submitted.connect(
		_on_rate_confirmed.bind(page, item_id, is_default))
	spin.get_line_edit().focus_exited.connect(
		_on_rate_focus_exited.bind(page, item_id, is_default))
	row.add_child(spin)
	var pending := Label.new()
	pending.text = "次日生效"
	pending.visible = false
	pending.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	row.add_child(pending)
	_rows_box.add_child(panel)
	var result := {"control": panel, "name": name_label, "effective": effective_label,
		"override": override, "spin": spin, "pending": pending,
		"page": page, "item_id": item_id, "is_default": is_default}
	_rows[key] = result
	return result


func _update_tax_row(row: Dictionary, base_rate: int, effective_rate: int,
		has_override: bool, is_default: bool) -> void:
	var override := row.override as CheckBox
	var spin := row.spin as SpinBox
	override.set_pressed_no_signal(has_override)
	spin.set_value_no_signal(base_rate)
	(row.effective as Label).text = "有效 %d%%" % effective_rate
	(row.pending as Label).visible = _pending.has(
		"%s:%s" % [String(row.page), String(row.item_id)])
	spin.editable = is_default or has_override
	(row.control as Control).visible = true


func _on_override_toggled(enabled: bool, page: String, item_id: String) -> void:
	var row: Dictionary = _rows.get("%s:%s" % [page, item_id], {})
	if row.is_empty():
		return
	if enabled:
		_submit_rate(page, item_id, int((row.spin as SpinBox).value), false)
	else:
		var facade = _model.get("country_facade")
		if facade != null:
			var result: Dictionary = facade.clear_tax_override(
				int(_model.get("country_handle", 0)),
				int(TAX_KIND[page]), StringName(item_id), _effective_day(), _next_sequence())
			if bool(result.get("ok", false)):
				_mark_pending(page, item_id)
			else:
				_status_label.text = String(result.get(
					"reason", "税率覆盖清除命令提交失败"))
	(row.spin as SpinBox).editable = enabled


func _on_rate_confirmed(_text: String, page: String, item_id: String,
		is_default: bool) -> void:
	_confirm_row(page, item_id, is_default)


func _on_rate_focus_exited(page: String, item_id: String,
		is_default: bool) -> void:
	_confirm_row(page, item_id, is_default)


func _confirm_row(page: String, item_id: String, is_default: bool) -> void:
	var row: Dictionary = _rows.get("%s:%s" % [page, item_id], {})
	if row.is_empty() or (not is_default and not (row.override as CheckBox).button_pressed):
		return
	_submit_rate(page, item_id, int((row.spin as SpinBox).value), is_default)


func _submit_rate(page: String, item_id: String, rate: int, is_default: bool) -> void:
	var facade = _model.get("country_facade")
	if facade == null:
		return
	var handle := int(_model.get("country_handle", 0))
	var result: Dictionary
	if is_default:
		result = facade.set_tax_default(handle, int(TAX_KIND[page]), rate,
			_effective_day(), _next_sequence())
	else:
		result = facade.set_tax_override(handle, int(TAX_KIND[page]),
			StringName(item_id), rate, _effective_day(), _next_sequence())
	if bool(result.get("ok", false)):
		_mark_pending(page, item_id)
	else:
		_status_label.text = String(result.get("reason", "税率命令提交失败"))


func _mark_pending(page: String, item_id: String) -> void:
	var key := "%s:%s" % [page, item_id]
	var policy: Dictionary = _model.get("tax_policy", {})
	_pending[key] = {
		"effective_day": _effective_day(),
		"policy_version": int(policy.get("policy_version", -1)),
	}
	var row: Dictionary = _rows.get(key, {})
	if not row.is_empty():
		(row.pending as Label).visible = true


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
		var row: Dictionary = _rows.get(key, {})
		if not row.is_empty():
			(row.pending as Label).visible = false


func _effective_day() -> int:
	return int(_model.get("current_day", -1)) + 1


func _next_sequence() -> int:
	var result := _sequence
	_sequence += 1
	return result


func _apply_goods(goods: Array) -> void:
	for good_value in goods:
		var good: Dictionary = good_value
		var stable_id := String(good.get("id", ""))
		var key := "treasury:%s" % stable_id
		if not _rows.has(key):
			_rows[key] = _make_good_row(stable_id)
		var row: Dictionary = _rows[key]
		(row.control as Control).visible = true
		(row.name as Label).text = String(good.get("display_name", stable_id))
		(row.value as Label).text = String(good.get("quantity_text", "0"))
	_goods_count_label.text = "%d 种非零物资" % goods.size()
	_goods_count_label.visible = true
	_empty_label.visible = goods.is_empty()


func _make_good_row(stable_id: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.name = "TreasuryGood_%s" % stable_id
	var row := HBoxContainer.new()
	panel.add_child(row)
	var name_label := Label.new()
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var value_label := Label.new()
	value_label.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	row.add_child(value_label)
	_rows_box.add_child(panel)
	return {"control": panel, "name": name_label, "value": value_label,
		"page": "treasury", "item_id": stable_id}


func _apply_filter() -> void:
	var needle := _search.text.strip_edges().to_lower()
	var visible_count := 0
	for row_value in _rows.values():
		var row: Dictionary = row_value
		if String(row.get("page", "")) != _page:
			continue
		var control := row.control as Control
		if bool(row.get("is_default", false)):
			control.visible = true
			visible_count += 1
			continue
		var matches := needle.is_empty() or String(row.item_id).to_lower().contains(needle) \
			or String((row.name as Label).text).to_lower().contains(needle)
		var override_ok := not _overrides_only.button_pressed \
			or (row.override as CheckBox).button_pressed
		control.visible = matches and override_ok
		if control.visible:
			visible_count += 1
	_empty_label.visible = visible_count == 0
	_goods_count_label.visible = false


func _hide_all_rows() -> void:
	for row_value in _rows.values():
		(row_value.control as Control).visible = false
	_empty_label.visible = true
	_goods_count_label.visible = false


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _money(value: int) -> String:
	return UITokens.format_compact_number_cn(float(value) / 10000.0, 2)


func _display_name(stable_id: String) -> String:
	return stable_id.replace("_", " ").capitalize()


func cash_text() -> String:
	if _cash_card == null:
		return ""
	var value_label := _cash_card.get("_value_label") as Label
	return value_label.text if value_label != null else ""


func visible_good_count() -> int:
	var count := 0
	for row_value in _rows.values():
		var row: Dictionary = row_value
		if String(row.get("page", "")) == "treasury" \
				and (row.control as Control).visible:
			count += 1
	return count


func good_value_text(stable_id: String) -> String:
	var row: Dictionary = _rows.get("treasury:%s" % stable_id, {})
	return (row.value as Label).text if not row.is_empty() else ""


func good_row_instance_id(stable_id: String) -> int:
	var row: Dictionary = _rows.get("treasury:%s" % stable_id, {})
	return (row.control as Control).get_instance_id() if not row.is_empty() else 0


func select_page_for_test(page: String) -> void:
	if PAGE_IDS.has(page):
		_select_page(page)


func tax_row_count(page: String) -> int:
	var count := 0
	for row_value in _rows.values():
		var row: Dictionary = row_value
		if String(row.get("page", "")) == page:
			count += 1
	return count


func tax_row_instance_id(page: String, item_id: String) -> int:
	var row: Dictionary = _rows.get("%s:%s" % [page, item_id], {})
	return (row.control as Control).get_instance_id() if not row.is_empty() else 0


func tax_status_text() -> String:
	return _status_label.text if _status_label != null else ""
