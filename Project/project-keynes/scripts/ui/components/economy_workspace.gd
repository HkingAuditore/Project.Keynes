extends Control
class_name EconomyWorkspace

const TaxCardScene := preload("res://scenes/ui/economy_tax_card.tscn")
const TaxLaneScene := preload("res://scenes/ui/economy_tax_lane.tscn")
const TreasuryGoodScene := preload("res://scenes/ui/treasury_good_card.tscn")
const TradeRowScene := preload("res://scenes/ui/economy_trade_row.tscn")

const PAGE_IDS := ["treasury", "income", "consumption", "business", "tariff", "trade"]
const TOP_PAGE_IDS := ["treasury", "tax", "trade"]
const TAX_PAGE_IDS := ["income", "consumption", "business", "tariff"]
const PAGE_DEFINITIONS := {
	"treasury": {"label": "国库", "icon": &"metric.treasury", "accent": UITokens.RESOURCE},
	"tax": {"label": "税制", "icon": &"tax.section", "accent": UITokens.BRASS_HIGHLIGHT},
	"income": {"label": "所得税", "icon": &"tax.income", "accent": UITokens.ACCENT},
	"consumption": {"label": "消费税", "icon": &"tax.consumption", "accent": UITokens.GOOD},
	"business": {"label": "营业税", "icon": &"tax.business", "accent": UITokens.CLIMATE},
	"tariff": {"label": "关税", "icon": &"tax.tariff", "accent": UITokens.WATER},
	"trade": {"label": "贸易", "icon": &"metric.trade", "accent": UITokens.ACCENT},
}
const TAX_KIND := {"income": 0, "consumption": 1, "business": 2, "import": 3, "export": 4}
const KIND_LABELS := {"import": "进口", "export": "出口"}
const CARD_SIZE := Vector2(240.0, 0.0)
const ENTRANCE_STAGGER := 0.022
const ENTRANCE_MAX_DELAY := 0.30
# The simulation can advance dozens of days per real second. Summary cards are
# reading instruments, so coalesce those bursts while retaining the newest
# authoritative snapshot for the trailing refresh.
const LIVE_REFRESH_INTERVAL_MSEC := 200
const SUMMARY_CARD_SIZE := Vector2(150.0, 72.0)
const SUMMARY_CARD_SIZE_COMPACT := Vector2(104.0, 56.0)

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
var _tax_tabs: CategoryTabs
var _insights: InsightList
var _tab_signature := ""
var _tax_tab_signature := ""
var _scroll: ScrollContainer
var _flow: HFlowContainer
var _empty_label: Label
var _trade_views: HBoxContainer
var _trade_goods_button: Button
var _trade_partners_button: Button
var _trade_prev: Button
var _trade_next: Button
var _trade_page_label: Label
var _rows: Dictionary = {}
var _trade_rows: Dictionary = {}
var _model: Dictionary = {}
var _page := "treasury"
var _trade_view := "goods"
var _trade_offset := 0
var _trade_revision := -1
var _trade_cache: Dictionary = {}
var _partner_name_cache: Dictionary = {}
var _pending: Dictionary = {}
var _preview_defaults: Dictionary = {}
var _player_controller = null
var _refresh_dirty := false
var _has_rendered_model := false
var _last_render_msec := 0
var _compact := false


func _ready() -> void:
	if _cash_card != null:
		return
	set_process(false)
	_cash_card = get_node_or_null("Column/Cards/CashCard") as MetricCard
	_tax_card = get_node_or_null("Column/Cards/TaxCard") as MetricCard
	_subsidy_card = get_node_or_null("Column/Cards/SubsidyCard") as MetricCard
	_fulfillment_card = get_node_or_null("Column/Cards/FulfillmentCard") as MetricCard
	_country_label = get_node_or_null("Column/Header/CountryLabel") as Label
	_day_label = get_node_or_null("Column/Header/DayLabel") as Label
	_tabs = get_node_or_null("Column/Tabs") as CategoryTabs
	_tax_tabs = get_node_or_null("Column/TaxTabs") as CategoryTabs
	_insights = get_node_or_null("Column/Insights") as InsightList
	_search = get_node_or_null("Column/Tools/Search") as LineEdit
	_overrides_only = get_node_or_null("Column/Tools/OverridesOnly") as Button
	_status_label = get_node_or_null("Column/StatusLabel") as Label
	_scroll = get_node_or_null("Column/Scroll") as ScrollContainer
	_flow = get_node_or_null("Column/Scroll/Flow") as HFlowContainer
	_empty_label = get_node_or_null("Column/Scroll/Flow/EmptyLabel") as Label
	_trade_views = get_node_or_null("Column/Tools/TradeViews") as HBoxContainer
	_trade_goods_button = get_node_or_null("Column/Tools/TradeViews/Goods") as Button
	_trade_partners_button = get_node_or_null("Column/Tools/TradeViews/Partners") as Button
	_trade_prev = get_node_or_null("Column/Tools/TradePrev") as Button
	_trade_next = get_node_or_null("Column/Tools/TradeNext") as Button
	_trade_page_label = get_node_or_null("Column/Tools/TradePage") as Label
	var section_badge := get_node_or_null("Column/Header/SectionIcon") as IconBadge
	if _cash_card == null or _tax_card == null or _subsidy_card == null \
			or _fulfillment_card == null or _country_label == null \
			or _day_label == null or _tabs == null or _search == null \
			or _overrides_only == null or _status_label == null \
			or _scroll == null or _flow == null or _empty_label == null \
			or section_badge == null:
		push_error("EconomyWorkspace 必须通过 economy_workspace.tscn 实例化。")
		return
	section_badge.set_semantic(&"tax.section", UITokens.BRASS_HIGHLIGHT)
	_tabs.tab_selected.connect(_select_page)
	if _tax_tabs != null:
		_tax_tabs.tab_selected.connect(_select_page)
	_search.text_changed.connect(_apply_filter.unbind(1))
	_overrides_only.toggled.connect(_apply_filter.unbind(1))
	if _trade_goods_button != null:
		_trade_goods_button.pressed.connect(_select_trade_view.bind("goods"))
	if _trade_partners_button != null:
		_trade_partners_button.pressed.connect(_select_trade_view.bind("partners"))
	if _trade_prev != null:
		_trade_prev.pressed.connect(_trade_previous_page)
	if _trade_next != null:
		_trade_next.pressed.connect(_trade_next_page)
	if _trade_prev != null:
		IconButton.apply(_trade_prev, &"action.back", IconButton.MEDIUM, "上一页")
	if _trade_next != null:
		IconButton.apply(_trade_next, &"action.chevron_right", IconButton.MEDIUM, "下一页")
	_select_page("treasury")


func set_model(model: Dictionary) -> void:
	if _cash_card == null:
		_ready()
	_preview_defaults.clear()
	_model = model
	# Opening/switching to the workspace must paint immediately. Only repeated
	# live-tick patches are coalesced.
	_apply_model(Time.get_ticks_msec())


func set_player_controller(controller) -> void:
	_player_controller = controller


func set_compact(compact: bool) -> void:
	_compact = compact
	var card_size := SUMMARY_CARD_SIZE_COMPACT if compact else SUMMARY_CARD_SIZE
	for card in [_cash_card, _tax_card, _subsidy_card, _fulfillment_card]:
		if card != null:
			card.custom_minimum_size = card_size
			card.set_compact(compact)


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
	_partner_name_cache[0] = String(_model.get("country_name", "玩家国家"))
	_resolve_pending_commands()
	var available := bool(_model.get("available", false))
	var collected := _sum_i64(fiscal.get("collected", PackedInt64Array()))
	var subsidy := _sum_i64(fiscal.get("subsidy_paid", PackedInt64Array()))
	var requested := _sum_i64(fiscal.get("subsidy_requested", PackedInt64Array()))
	var fulfillment := 1.0 if requested <= 0 else float(subsidy) / float(requested)
	_cash_card.set_data("国库现金",
		String(treasury.get("cash_text", "—")) if available else "—",
		String(_model.get("country_name", "玩家国家")), UITokens.RESOURCE, "", "metric.treasury")
	_tax_card.set_data("昨日税收", _money(collected), "所得税 / 消费税 / 营业税",
		UITokens.BRASS_HIGHLIGHT, "", "tax.section")
	var subsidy_gap := maxi(0, requested - subsidy)
	_subsidy_card.set_data("补贴缺口", _money(subsidy_gap),
		"实付 %s" % _money(subsidy),
		UITokens.CLIMATE if subsidy_gap <= 0 else UITokens.RISK, "", "tax.income")
	_fulfillment_card.set_data("补贴兑现率", "%.1f%%" % (fulfillment * 100.0),
		"首次启用时预算建立中" if requested > 0 and subsidy == 0 else "昨日申请",
		UITokens.ACCENT, "", "tax.default")
	_country_label.text = String(_model.get("country_name", ""))
	var day := int(_model.get("current_day", -1))
	_day_label.text = "第 %d 天" % (day + 1) if day >= 0 else ""
	_day_label.visible = day >= 0
	_refresh_tabs()
	_refresh_tax_tabs()
	_refresh_page()
	if _page == "trade":
		_apply_trade_summary_cards()
	_refresh_treasury_insights()


func _refresh_tabs() -> void:
	var treasury: Dictionary = _model.get("treasury", {})
	var signature_parts: Array[String] = []
	var tabs: Array = []
	for page in TOP_PAGE_IDS:
		var definition: Dictionary = PAGE_DEFINITIONS[page]
		var tooltip := String(definition.label)
		if page == "trade":
			tooltip = "贸易"
			signature_parts.append("trade")
		elif page == "treasury":
			var good_count := int(treasury.get("nonzero_good_count", 0))
			tooltip = "国库 · %d 种物资" % good_count
			signature_parts.append("%s:%d" % [page, good_count])
		else:
			tooltip = "税制"
			signature_parts.append("tax")
		tabs.append({"id": page, "label": String(definition.label),
			"icon": definition.icon, "tooltip": tooltip})
	var signature := "|".join(signature_parts)
	if signature == _tab_signature and _tabs.get_child_count() > 0:
		_tabs.select_tab(_top_page_for(_page))
		return
	_tab_signature = signature
	_tabs.set_tabs(tabs, _top_page_for(_page), true)


func _refresh_tax_tabs() -> void:
	if _tax_tabs == null:
		return
	var tax_open := _is_tax_page(_page)
	_tax_tabs.visible = tax_open
	if not tax_open:
		return
	var presentation: Dictionary = _model.get("tax_presentation", {})
	var signature_parts: Array[String] = []
	var tabs: Array = []
	for page in TAX_PAGE_IDS:
		var definition: Dictionary = PAGE_DEFINITIONS[page]
		var page_pres: Dictionary = presentation.get(_presentation_key(page), {})
		var unlocked_count := (page_pres.get("unlocked", []) as Array).size()
		var total := int(page_pres.get("total_count", 0))
		signature_parts.append("%s:%d:%d" % [page, unlocked_count, total])
		tabs.append({"id": page, "label": String(definition.label),
			"icon": definition.icon,
			"tooltip": "%s · 已解锁 %d/%d" % [String(definition.label), unlocked_count, total]})
	var signature := "|".join(signature_parts)
	if signature == _tax_tab_signature and _tax_tabs.get_child_count() > 0:
		_tax_tabs.select_tab(_page)
		return
	_tax_tab_signature = signature
	_tax_tabs.set_tabs(tabs, _page, true)


func _select_page(page: String) -> void:
	if page == "tax":
		page = _page if _is_tax_page(_page) else "income"
	_page = page
	if _tabs != null:
		_tabs.select_tab(_top_page_for(page))
	if _tax_tabs != null:
		_refresh_tax_tabs()
		_tax_tabs.visible = _is_tax_page(page)
		if _tax_tabs.visible:
			_tax_tabs.select_tab(page)
	if _search != null:
		_search.visible = _is_tax_page(page)
		_overrides_only.visible = _is_tax_page(page)
	if _trade_views != null:
		_trade_views.visible = page == "trade"
		_trade_prev.visible = page == "trade"
		_trade_next.visible = page == "trade"
		_trade_page_label.visible = page == "trade"
	if _insights != null:
		_insights.visible = page == "treasury"
	_refresh_page()
	_refresh_treasury_insights()
	_animate_cards_in()


func _top_page_for(page: String) -> String:
	return "tax" if _is_tax_page(page) else page


func _is_tax_page(page: String) -> bool:
	return TAX_PAGE_IDS.has(page)


# Visibility is synced from a wanted-set instead of hide-all-then-reshow, so a
# daily tick never toggles a stable card and never steals focus from a SpinBox
# the player is editing (hiding a focused control releases its focus).
func _refresh_page() -> void:
	if _flow == null or _model.is_empty():
		return
	var wanted := {}
	if _page == "trade":
		_refresh_trade_page(wanted)
		_sync_visibility(wanted)
		return
	_apply_default_summary_cards()
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
	_set_status("")
	_apply_filter()


func _select_trade_view(view: String) -> void:
	if view != "goods" and view != "partners":
		return
	_trade_view = view
	_trade_offset = 0
	if _trade_goods_button != null:
		_trade_goods_button.button_pressed = view == "goods"
	if _trade_partners_button != null:
		_trade_partners_button.button_pressed = view == "partners"
	_refresh_page()


func _trade_previous_page() -> void:
	_trade_offset = maxi(0, _trade_offset - 32)
	_refresh_page()


func _trade_next_page() -> void:
	var cached: Dictionary = _trade_cache.get(_trade_cache_key(), {})
	if not bool(cached.get("has_more", false)):
		return
	_trade_offset += 32
	_refresh_page()


func _trade_cache_key() -> String:
	return "%s:%d" % [_trade_view, _trade_offset]


func _trade_good_name(good_index: int) -> String:
	var economy = _model.get("economy_facade", null)
	if economy != null and economy.has_method("good_display_name"):
		return String(economy.good_display_name(good_index))
	var good_ids: PackedStringArray = _model.get("trade_summary", {}).get(
		"good_ids", PackedStringArray())
	return String(good_ids[good_index]) if good_index >= 0 and good_index < good_ids.size() \
		else "物资 %d" % good_index


func _trade_partner_name(handle: int, slot: int) -> String:
	if handle > 0 and _partner_name_cache.has(handle):
		return String(_partner_name_cache[handle])
	var facade = _model.get("country_facade", null)
	if facade != null and handle > 0 and facade.has_method("snapshot"):
		var snapshot: Dictionary = facade.snapshot(handle)
		if bool(snapshot.get("ok", false)):
			var name := String(snapshot.get("country_name",
				snapshot.get("display_name", "")))
			if not name.is_empty():
				_partner_name_cache[handle] = name
				return name
	return "国家 %d" % slot


func _refresh_trade_page(wanted: Dictionary) -> void:
	_apply_trade_summary_cards()
	var economy = _model.get("economy_facade", null)
	var country_handle := int(_model.get("country_handle", 0))
	if economy == null or country_handle <= 0 or not economy.has_method(
			"country_trade_snapshot"):
		_empty_label.text = "贸易数据暂不可用"
		_empty_label.visible = true
		_set_status("国家贸易查询暂不可用", true)
		return
	var summary: Dictionary = _model.get("trade_summary", {})
	var revision := int(summary.get("revision", -1))
	if revision != _trade_revision:
		_trade_revision = revision
		_trade_cache.clear()
	var cache_key := _trade_cache_key()
	var page: Dictionary = _trade_cache.get(cache_key, {})
	if page.is_empty():
		page = economy.country_trade_snapshot(country_handle, _trade_view,
			_trade_offset, 32)
		if bool(page.get("ok", false)):
			_trade_cache[cache_key] = page
	if not bool(page.get("ok", false)):
		_empty_label.text = String(page.get("reason", "贸易数据暂不可用"))
		_empty_label.visible = true
		_set_status("", false)
		return
	var total := int(page.get("total", 0))
	var begin := int(page.get("offset", _trade_offset))
	var has_more := bool(page.get("has_more", false))
	_trade_offset = begin
	_trade_page_label.text = "%d-%d / %d" % [
		begin + 1 if total > 0 else 0,
		mini(begin + 32, total), total]
	_trade_prev.disabled = begin <= 0
	_trade_next.disabled = not has_more
	var row_count := 0
	if _trade_view == "goods":
		var goods: PackedInt32Array = page.get("goods", PackedInt32Array())
		var imports: PackedInt64Array = page.get("import_quantity", PackedInt64Array())
		var exports: PackedInt64Array = page.get("export_quantity", PackedInt64Array())
		var import_base: PackedInt64Array = page.get("import_base", PackedInt64Array())
		var export_base: PackedInt64Array = page.get("export_base", PackedInt64Array())
		var import_tariff: PackedInt64Array = page.get("import_tariff", PackedInt64Array())
		var export_tariff: PackedInt64Array = page.get("export_tariff", PackedInt64Array())
		var cumulative_imports: PackedInt64Array = page.get(
			"cumulative_import_quantity", PackedInt64Array())
		var cumulative_exports: PackedInt64Array = page.get(
			"cumulative_export_quantity", PackedInt64Array())
		var cumulative_import_base: PackedInt64Array = page.get(
			"cumulative_import_base", PackedInt64Array())
		var cumulative_export_base: PackedInt64Array = page.get(
			"cumulative_export_base", PackedInt64Array())
		var cumulative_import_tariff: PackedInt64Array = page.get(
			"cumulative_import_tariff", PackedInt64Array())
		var cumulative_export_tariff: PackedInt64Array = page.get(
			"cumulative_export_tariff", PackedInt64Array())
		for index in range(goods.size()):
			var key := "goods:%d" % int(goods[index])
			var row := _ensure_trade_row(key)
			var imported := int(imports[index]) if index < imports.size() else 0
			var exported := int(exports[index]) if index < exports.size() else 0
			var import_value := int(import_base[index]) if index < import_base.size() else 0
			var export_value := int(export_base[index]) if index < export_base.size() else 0
			var tariff := int(import_tariff[index]) if index < import_tariff.size() else 0
			tariff += int(export_tariff[index]) if index < export_tariff.size() else 0
			var all_imported := int(cumulative_imports[index]) \
				if index < cumulative_imports.size() else 0
			var all_exported := int(cumulative_exports[index]) \
				if index < cumulative_exports.size() else 0
			var all_import_value := int(cumulative_import_base[index]) \
				if index < cumulative_import_base.size() else 0
			var all_export_value := int(cumulative_export_base[index]) \
				if index < cumulative_export_base.size() else 0
			var all_tariff := int(cumulative_import_tariff[index]) \
				if index < cumulative_import_tariff.size() else 0
			all_tariff += int(cumulative_export_tariff[index]) \
				if index < cumulative_export_tariff.size() else 0
			(row.name as Label).text = _trade_good_name(int(goods[index]))
			(row.detail as Label).text = "累计 %s / %s" % [
				_money(all_import_value), _money(all_export_value)]
			(row.quantity as Label).text = "%d / %d" % [imported, exported]
			(row.base as Label).text = _money(import_value + export_value)
			(row.tariff as Label).text = _money(tariff)
			(row.control as Control).tooltip_text = \
				"上一批：进口 %s，出口 %s，关税净额 %s\n累计：进口 %s（%d），出口 %s（%d），关税净额 %s" % [
					_money(import_value), _money(export_value), _money(tariff),
					_money(all_import_value), all_imported,
					_money(all_export_value), all_exported, _money(all_tariff)]
			wanted[key] = true
			row_count += 1
	else:
		var partners: PackedInt32Array = page.get("partners", PackedInt32Array())
		var handles: PackedInt64Array = page.get("partner_handles", PackedInt64Array())
		var imports: PackedInt64Array = page.get("import_quantity", PackedInt64Array())
		var exports: PackedInt64Array = page.get("export_quantity", PackedInt64Array())
		var import_base: PackedInt64Array = page.get("import_base", PackedInt64Array())
		var export_base: PackedInt64Array = page.get("export_base", PackedInt64Array())
		var orders: PackedInt64Array = page.get("order_count", PackedInt64Array())
		var cumulative_imports: PackedInt64Array = page.get(
			"cumulative_import_quantity", PackedInt64Array())
		var cumulative_exports: PackedInt64Array = page.get(
			"cumulative_export_quantity", PackedInt64Array())
		var cumulative_import_base: PackedInt64Array = page.get(
			"cumulative_import_base", PackedInt64Array())
		var cumulative_export_base: PackedInt64Array = page.get(
			"cumulative_export_base", PackedInt64Array())
		var cumulative_orders: PackedInt64Array = page.get(
			"cumulative_order_count", PackedInt64Array())
		for index in range(partners.size()):
			var slot := int(partners[index])
			var handle := int(handles[index]) if index < handles.size() else 0
			var key := "partners:%d" % handle if handle > 0 else "partners:slot:%d" % slot
			var row := _ensure_trade_row(key)
			var imported := int(imports[index]) if index < imports.size() else 0
			var exported := int(exports[index]) if index < exports.size() else 0
			var import_value := int(import_base[index]) if index < import_base.size() else 0
			var export_value := int(export_base[index]) if index < export_base.size() else 0
			var all_imported := int(cumulative_imports[index]) \
				if index < cumulative_imports.size() else 0
			var all_exported := int(cumulative_exports[index]) \
				if index < cumulative_exports.size() else 0
			var all_import_value := int(cumulative_import_base[index]) \
				if index < cumulative_import_base.size() else 0
			var all_export_value := int(cumulative_export_base[index]) \
				if index < cumulative_export_base.size() else 0
			var all_orders := int(cumulative_orders[index]) \
				if index < cumulative_orders.size() else 0
			(row.name as Label).text = _trade_partner_name(handle, slot)
			(row.detail as Label).text = "订单 %d · 累计 %d" % [
				int(orders[index]) if index < orders.size() else 0, all_orders]
			(row.quantity as Label).text = "%d / %d" % [imported, exported]
			(row.base as Label).text = _money(import_value + export_value)
			(row.tariff as Label).text = "净额 %s" % _money(export_value - import_value)
			(row.control as Control).tooltip_text = \
				"上一批：进口 %s，出口 %s\n累计：进口 %s（%d），出口 %s（%d），净出口 %s" % [
					_money(import_value), _money(export_value),
					_money(all_import_value), all_imported,
					_money(all_export_value), all_exported,
					_money(all_export_value - all_import_value)]
			wanted[key] = true
			row_count += 1
	_empty_label.text = "暂无跨国贸易记录" if total == 0 else ""
	_empty_label.visible = row_count == 0
	_set_status("")


func _ensure_trade_row(key: String) -> Dictionary:
	if _trade_rows.has(key):
		return _trade_rows[key]
	var panel := TradeRowScene.instantiate() as PanelContainer
	panel.name = "Trade_%s" % key.replace(":", "_")
	var badge := panel.get_node("Body/Icon") as IconBadge
	badge.set_semantic(&"metric.trade", UITokens.ACCENT)
	_flow.add_child(panel)
	_watch_card_hover(panel)
	var result := {"control": panel,
		"name": panel.get_node("Body/Name") as Label,
		"detail": panel.get_node("Body/Detail") as Label,
		"quantity": panel.get_node("Body/Quantity") as Label,
		"base": panel.get_node("Body/Base") as Label,
		"tariff": panel.get_node("Body/Tariff") as Label,
		"page": "trade", "item_id": key}
	_trade_rows[key] = result
	return result


func _apply_trade_summary_cards() -> void:
	var summary: Dictionary = _model.get("trade_summary", {})
	var available := bool(summary.get("ok", false))
	var imports := int(summary.get("previous_import_base", 0))
	var exports := int(summary.get("previous_export_base", 0))
	var net := int(summary.get("previous_net_export_base", exports - imports))
	var tariff := int(summary.get("previous_tariff_net_income", 0))
	var cumulative_imports := int(summary.get("cumulative_import_base", 0))
	var cumulative_exports := int(summary.get("cumulative_export_base", 0))
	var cumulative_tariff := int(summary.get("cumulative_tariff_net_income", 0))
	_tax_card.set_data("昨日进口额", _money(imports), "累计 %s" % _money(cumulative_imports),
		UITokens.GOOD, "", "metric.trade")
	_subsidy_card.set_data("昨日出口额", _money(exports), "累计 %s" % _money(cumulative_exports),
		UITokens.RESOURCE, "", "metric.trade")
	_fulfillment_card.set_data("昨日净出口", _money(net), "累计 %s" % _money(
		cumulative_exports - cumulative_imports),
		UITokens.ACCENT, "", "metric.trade")
	_cash_card.set_data("关税净收入", _money(tariff) if available else "—",
		"累计 %s" % _money(cumulative_tariff), UITokens.BRASS_HIGHLIGHT, "", "tax.tariff")


func _apply_default_summary_cards() -> void:
	var treasury: Dictionary = _model.get("treasury", {})
	var fiscal: Dictionary = _model.get("fiscal", {})
	var available := bool(_model.get("available", false))
	var collected := _sum_i64(fiscal.get("collected", PackedInt64Array()))
	var subsidy := _sum_i64(fiscal.get("subsidy_paid", PackedInt64Array()))
	var requested := _sum_i64(fiscal.get("subsidy_requested", PackedInt64Array()))
	var fulfillment := 1.0 if requested <= 0 else float(subsidy) / float(requested)
	_cash_card.set_data("国库现金",
		String(treasury.get("cash_text", "—")) if available else "—",
		String(_model.get("country_name", "玩家国家")), UITokens.RESOURCE, "", "metric.treasury")
	_tax_card.set_data("昨日税收", _money(collected), "所得税 / 消费税 / 营业税",
		UITokens.BRASS_HIGHLIGHT, "", "tax.section")
	var subsidy_gap := maxi(0, requested - subsidy)
	_subsidy_card.set_data("补贴缺口", _money(subsidy_gap),
		"实付 %s" % _money(subsidy),
		UITokens.CLIMATE if subsidy_gap <= 0 else UITokens.RISK, "", "tax.income")
	_fulfillment_card.set_data("补贴兑现率", "%.1f%%" % (fulfillment * 100.0),
		"首次启用时预算建立中" if requested > 0 and subsidy == 0 else "昨日申请",
		UITokens.ACCENT, "", "tax.default")


func _sync_visibility(wanted: Dictionary) -> void:
	for row_value in _rows.values():
		var card: Dictionary = row_value
		var control := card.control as Control
		var should_show := wanted.has("%s:%s" % [String(card.page), String(card.item_id)])
		if control.visible != should_show:
			control.visible = should_show
	for row_value in _trade_rows.values():
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
	var panel := TaxCardScene.instantiate() as PanelContainer
	panel.name = "Tax_%s_%s" % [page, item_id]
	panel.custom_minimum_size = CARD_SIZE
	var kinds := _page_kinds(page)
	var badge := panel.get_node("Body/Head/Icon") as IconBadge
	badge.set_semantic(StringName(icon_key), accent)
	var name_label := panel.get_node("Body/Head/Name") as Label
	name_label.text = label
	name_label.add_theme_font_override("font", UITokens.font_with_weight(600))
	var sub_label := panel.get_node("Body/Sub") as Label
	if is_default:
		sub_label.text = "未单独设置的项目适用"
		sub_label.visible = true
	var spins := {}
	var resets := {}
	var pendings := {}
	var lane_host := panel.get_node("Body/Lanes") as VBoxContainer
	for kind in kinds:
		var kind_row := TaxLaneScene.instantiate() as HBoxContainer
		lane_host.add_child(kind_row)
		var kind_label := kind_row.get_node("Kind") as Label
		kind_label.text = String(KIND_LABELS.get(kind, kind))
		kind_label.visible = kinds.size() > 1
		var spin := kind_row.get_node("Spin") as SpinBox
		spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
		spin.get_line_edit().text_submitted.connect(
			_on_rate_confirmed.bind(key, kind))
		spin.get_line_edit().focus_exited.connect(
			_on_rate_focus_exited.bind(key, kind))
		spin.value_changed.connect(_on_rate_preview.bind(key, kind))
		spins[kind] = spin
		var reset := kind_row.get_node("Reset") as Button
		IconButton.apply(reset, &"action.reset", IconButton.SMALL, "重置为默认税率")
		reset.pressed.connect(_on_reset_pressed.bind(key, kind))
		resets[kind] = reset
		var clock_badge := kind_row.get_node("Pending") as IconBadge
		clock_badge.set_semantic(&"system.clock", UITokens.BRASS_HIGHLIGHT)
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
	var panel := card.control as PanelContainer
	panel.theme_type_variation = &"PKDialog" \
		if bool(card.is_default) or highlighted else &"PKMetricCard"


func _watch_card_hover(_panel: PanelContainer) -> void:
	pass


func _refresh_treasury_insights() -> void:
	if _insights == null:
		return
	_insights.visible = _page == "treasury"
	if not _insights.visible:
		return
	var fiscal: Dictionary = _model.get("fiscal", {})
	var trade_summary: Dictionary = _model.get("trade_summary", {})
	var subsidy := _sum_i64(fiscal.get("subsidy_paid", PackedInt64Array()))
	var requested := _sum_i64(fiscal.get("subsidy_requested", PackedInt64Array()))
	var gap := maxi(0, requested - subsidy)
	var imports := int(trade_summary.get("previous_import_base", 0))
	var exports := int(trade_summary.get("previous_export_base", 0))
	var net := int(trade_summary.get("previous_net_export_base", exports - imports))
	var items: Array = []
	if gap > 0:
		items.append({
			"id": "subsidy_gap",
			"text": "补贴缺口 %s，国库现金可能不够兑现。" % _money(gap),
			"accent": UITokens.RISK,
			"icon": "tax.income",
		})
	if net < 0:
		items.append({
			"id": "trade_deficit",
			"text": "贸易逆差 %s。" % _money(-net),
			"accent": UITokens.RISK,
			"icon": "metric.trade",
		})
	elif net > 0:
		items.append({
			"id": "trade_surplus",
			"text": "贸易顺差 %s。" % _money(net),
			"accent": UITokens.GOOD,
			"icon": "metric.trade",
		})
	if items.size() < 4:
		items.append({
			"id": "market_shortage_hint",
			"text": "物资短缺请到各地市场档案查看。",
			"accent": UITokens.TEXT_MUTED,
			"icon": "resource",
		})
	_insights.set_items(items.slice(0, 4))


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
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		&"country.tax.clear_override", {
			"kind": int(TAX_KIND[kind]), "item_id": StringName(item_id)})
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
	if _player_controller == null:
		return
	var result: Dictionary
	if is_default:
		result = _player_controller.request_command(&"country.tax.set_default", {
			"kind": int(TAX_KIND[kind]), "rate_percent": rate})
	else:
		result = _player_controller.request_command(&"country.tax.set_override", {
			"kind": int(TAX_KIND[kind]), "item_id": StringName(item_id),
			"rate_percent": rate})
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
	var panel := TreasuryGoodScene.instantiate() as PanelContainer
	panel.name = "TreasuryGood_%s" % stable_id
	var badge := panel.get_node("Body/Head/Icon") as IconBadge
	badge.set_semantic(StringName(icon_key), UITokens.GOOD)
	var name_label := panel.get_node("Body/Head/Name") as Label
	var value_label := panel.get_node("Body/Value") as Label
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
