extends Control
class_name EconomyWorkspace

const TaxCommands = preload("res://scripts/ui/components/economy_tax_commands.gd")

const TaxCards = preload("res://scripts/ui/components/economy_tax_cards.gd")

const WorkspacePage = preload("res://scripts/ui/components/economy_workspace_page.gd")

const WorkspaceNavigation = preload("res://scripts/ui/components/economy_workspace_navigation.gd")

const BudgetCommands = preload("res://scripts/ui/components/economy_budget_commands.gd")

const WorkspaceControls = preload("res://scripts/ui/components/economy_workspace_controls.gd")

const TradePresentation = preload("res://scripts/ui/components/economy_workspace_trade.gd")
const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const NationalProcurementSliderScript = preload("res://scripts/ui/components/national_procurement_slider.gd")
const FiscalBudgetPageScript = preload("res://scripts/ui/components/fiscal_budget_page.gd")
const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const TaxCardScene := preload("res://scenes/ui/economy_tax_card.tscn")
const TaxLaneScene := preload("res://scenes/ui/economy_tax_lane.tscn")
const TaxGroupControllerScript := preload("res://scripts/ui/components/economy_tax_group_controller.gd")
const TouchValueFieldScript := preload("res://scripts/ui/components/touch_value_field.gd")
const TreasuryGoodScene := preload("res://scenes/ui/treasury_good_card.tscn")
const TradeRowScene := preload("res://scenes/ui/economy_trade_row.tscn")

# 预算调配不再单独占一个页签：它直接挂在「国库」页上半部，下面是国库物资。
const PAGE_IDS := ["treasury", "income", "consumption", "business", "trade"]
const TOP_PAGE_IDS := ["treasury", "tax", "trade"]
const TAX_PAGE_IDS := ["income", "consumption", "business"]
const PAGE_DEFINITIONS := {
	"treasury": {"label": "国库", "icon": &"metric.treasury", "accent": UITokens.RESOURCE},
	"tax": {"label": "税制", "icon": &"tax.section", "accent": UITokens.BRASS_HIGHLIGHT},
	"income": {"label": "所得税", "icon": &"tax.income", "accent": UITokens.ACCENT},
	"consumption": {"label": "物资税", "icon": &"tax.consumption", "accent": UITokens.GOOD},
	"business": {"label": "营业税", "icon": &"tax.business", "accent": UITokens.CLIMATE},
	"trade": {"label": "贸易", "icon": &"metric.trade", "accent": UITokens.ACCENT},
}
const TAX_KIND := {"income": 0, "consumption": 1, "business": 2, "import": 3, "export": 4}
const KIND_LABELS := {"consumption": "交易", "import": "进口", "export": "出口"}
const TAX_MODE_PERCENT_BP := 0
const TAX_MODE_ABSOLUTE := 1
const TAX_ABSOLUTE_MIN := -1000000000
const TAX_ABSOLUTE_MAX := 1000000000
const CARD_SIZE := Vector2(280.0, 0.0)
const ENTRANCE_STAGGER := 0.022
const ENTRANCE_MAX_DELAY := 0.30
const LIVE_REFRESH_INTERVAL_MSEC := 200
const DRAFT_COMMIT_DELAY_SEC := 0.18
const SUMMARY_CARD_SIZE := Vector2(180.0, 78.0)
const SUMMARY_CARD_SIZE_COMPACT := Vector2(112.0, 60.0)

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
var _default_tax_host: Control
var _tax_group_list: VBoxContainer
var _flow: HFlowContainer
var _empty_label: Label
var _goods_heading: Control
var _group_axis_picker: OptionButton
var _expand_all_button: Button
var _tax_groups = null
var _trade_views: HBoxContainer
var _trade_goods_button: Button
var _trade_partners_button: Button
var _trade_prev: Button
var _trade_next: Button
var _trade_page_label: Label
var _ledger_title: Label
var _ledger_subtitle: Label
var _summary_heading: Control
var _summary_cards: Control
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
# Keep the value the player just submitted visible until a committed policy
# snapshot explicitly reflects it.  Worker/UI snapshots can cross one another
# around the effective day; relying on _pending alone allowed an older snapshot
# to repaint the input after focus had already left it.
var _submitted_tax: Dictionary = {}
var _preview_defaults: Dictionary = {}
var _draft_overrides: Dictionary = {}
var _draft_timer: Timer
var _draft_commit_key := ""
var _draft_commit_kind := ""
var _player_controller = null
var _refresh_dirty := false
var _has_rendered_model := false
var _last_render_msec := 0
var _compact := false
var _embedded := false
var _last_tax_page := "income"
## 预算卷宗：国库页上半部，国库份额 / 科技 / 时代收购 / 开拓 / 军事统一调整区。
var _fiscal_page: Control


func _ready() -> void:
	WorkspaceControls._ready(self)


func set_model(model: Dictionary) -> void:
	if _cash_card == null:
		_ready()
	_preview_defaults.clear()
	_draft_overrides.clear()
	_submitted_tax.clear()
	_stop_draft_timer()
	for row_value in _rows.values():
		if row_value is Dictionary:
			(row_value as Dictionary)["signature"] = ""
	_model = model
	# Opening/switching to the workspace must paint immediately. Only repeated
	# live-tick patches are coalesced.
	_apply_model(Time.get_ticks_msec())


func set_player_controller(controller) -> void:
	_player_controller = controller
	if _fiscal_page != null:
		_fiscal_page.set_player_controller(controller)


## 嵌入国民经济卷宗时：外壳负责国库 / 税收导航，只保留税种页签。
func set_embedded(embedded: bool) -> void:
	if _cash_card == null:
		_ready()
	_embedded = embedded
	_tabs.visible = not embedded
	var header := get_node_or_null("Viewport/Column/Header") as Control
	if header != null:
		header.visible = not embedded
	_tab_signature = ""
	if embedded and _page == "trade":
		_select_page("treasury")
	elif not _model.is_empty():
		_refresh_tabs()


func select_embedded_chapter(chapter_id: String) -> void:
	if chapter_id == "tax":
		_select_page(_last_tax_page)
	elif chapter_id == "treasury":
		_select_page("treasury")


func set_compact(compact: bool) -> void:
	# 触摸档：手机横屏逻辑高只有 873，摘要卡 + 洞察条 + 88 像素的页签栏会挤掉国库列表，
	# 所以恒走紧凑版（只留页签与可滚动的账本）。
	_compact = compact or TouchUI.is_short_viewport()
	_apply_summary_visibility()
	if _insights != null:
		_insights.visible = not compact
	var card_size := SUMMARY_CARD_SIZE_COMPACT if _compact else SUMMARY_CARD_SIZE
	for card in [_cash_card, _tax_card, _subsidy_card, _fulfillment_card]:
		if card != null:
			card.custom_minimum_size = card_size
			card.set_compact(_compact)
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED if _compact \
			else ScrollContainer.SCROLL_MODE_AUTO


## 国库页收起顶部「财政摘要」四张卡：税收 / 补贴 / 兑现率与预算调配无关，
## 让出来的高度正好够预算卷宗把四块共同额度和军事信封一屏铺开。
## 税制与贸易页仍照常显示摘要。
func _apply_summary_visibility() -> void:
	var show := not _compact and _page != "treasury"
	if _summary_heading != null:
		_summary_heading.visible = show
	if _summary_cards != null:
		_summary_cards.visible = show


func scroll_container() -> ScrollContainer:
	return get_node("Viewport") as ScrollContainer if _compact else _scroll


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
	var reserved := _sum_i64(fiscal.get("subsidy_reserved", PackedInt64Array()))
	var cumulative_subsidy := _sum_i64(fiscal.get(
		"cumulative_subsidy_paid", PackedInt64Array()))
	var fulfillment := 1.0 if requested <= 0 else float(subsidy) / float(requested)
	_cash_card.set_data("国库现金",
		String(treasury.get("cash_text", "—")) if available else "—",
		String(_model.get("country_name", "玩家国家")), UITokens.RESOURCE, "", "metric.treasury",
		true)
	_tax_card.set_data("昨日税收", _money(collected), "所得税 / 交易税 / 营业税",
		UITokens.BRASS_HIGHLIGHT, "", "tax.section", true)
	var subsidy_gap := maxi(0, requested - subsidy)
	_subsidy_card.set_data("补贴缺口", _money(subsidy_gap),
		"本批实付 %s · 累计实付 %s" % [_money(subsidy), _money(cumulative_subsidy)],
		UITokens.CLIMATE if subsidy_gap <= 0 else UITokens.RISK, "", "tax.income", true)
	_fulfillment_card.set_data("补贴兑现率", "%.1f%%" % (fulfillment * 100.0),
		("未预留，等待国库预算" if requested > 0 and subsidy == 0 and reserved == 0
		 else "昨日申请 · 预留 %s" % _money(reserved)),
		UITokens.ACCENT, "", "tax.default")
	_country_label.text = String(_model.get("country_name", ""))
	var day := int(_model.get("current_day", -1))
	_day_label.text = WorldClock.date_text_for_day(day) if day >= 0 else ""
	_day_label.visible = day >= 0
	_refresh_tabs()
	_refresh_tax_tabs()
	_refresh_page()
	if _page == "trade":
		_apply_trade_summary_cards()
	_refresh_treasury_insights()
	_refresh_budget()


## 预算卷宗与国库物资共用同一页：每日 tick 只把最新读数推给卷宗，
## 不重建节点（玩家手里的滑条不能被刷新销毁）。
func _refresh_budget() -> void:
	if _fiscal_page == null or _page != "treasury":
		return
	_fiscal_page.set_player_controller(_player_controller)
	_fiscal_page.refresh_live(_model)


## 提交国家购买政策。era/colonization 传 -1 表示本次不改该通道
## （仍在自动分配的通道由预算卷宗传 -1，避免被钉成手动份额）。
func _on_procurement_committed(treasury_share_bp: int, research_share_bp := -1,
		era_share_bp := -1, colonization_share_bp := -1) -> void:
	BudgetCommands._on_procurement_committed(self, treasury_share_bp, research_share_bp, era_share_bp, colonization_share_bp)


func _on_military_budget_committed(total_bp: int, wage_bp: int, upkeep_bp: int,
		procurement_bp: int) -> void:
	BudgetCommands._on_military_budget_committed(self, total_bp, wage_bp, upkeep_bp, procurement_bp)


func _refresh_tabs() -> void:
	WorkspaceNavigation._refresh_tabs(self)


func _refresh_tax_tabs() -> void:
	WorkspaceNavigation._refresh_tax_tabs(self)


func _select_page(page: String) -> void:
	WorkspaceNavigation._select_page(self, page)


func _top_page_for(page: String) -> String:
	return WorkspaceNavigation._top_page_for(self, page)


func _apply_budget_visibility(page: String) -> void:
	WorkspaceNavigation._apply_budget_visibility(self, page)


func _play_fiscal_entrance() -> void:
	WorkspaceNavigation._play_fiscal_entrance(self)


func _apply_budget_model() -> void:
	WorkspaceNavigation._apply_budget_model(self)


func fiscal_page() -> Control:
	return WorkspaceNavigation.fiscal_page(self)


func _is_tax_page(page: String) -> bool:
	return WorkspaceNavigation._is_tax_page(self, page)


func _page_description(page: String) -> String:
	return WorkspaceNavigation._page_description(self, page)


# Visibility is synced from a wanted-set instead of hide-all-then-reshow, so a
# daily tick never toggles a stable card and never steals focus from a SpinBox
# the player is editing (hiding a focused control releases its focus).
func _refresh_page() -> void:
	WorkspacePage._refresh_page(self)


func _select_trade_view(view: String) -> void:
	WorkspacePage._select_trade_view(self, view)


func _trade_previous_page() -> void:
	WorkspacePage._trade_previous_page(self)


func _trade_next_page() -> void:
	WorkspacePage._trade_next_page(self)


func _trade_cache_key() -> String:
	return WorkspacePage._trade_cache_key(self)


func _trade_good_name(good_index: int) -> String:
	return WorkspacePage._trade_good_name(self, good_index)


func _trade_partner_name(handle: int, slot: int) -> String:
	return WorkspacePage._trade_partner_name(self, handle, slot)


func _refresh_trade_page(wanted: Dictionary) -> void:
	WorkspacePage._refresh_trade_page(self, wanted)


func _ensure_trade_row(key: String) -> Dictionary:
	return WorkspacePage._ensure_trade_row(self, key)


func _apply_trade_summary_cards() -> void:
	WorkspacePage._apply_trade_summary_cards(self)


func _apply_default_summary_cards() -> void:
	WorkspacePage._apply_default_summary_cards(self)


func _sync_visibility(wanted: Dictionary) -> void:
	WorkspacePage._sync_visibility(self, wanted)


func _page_kinds(page: String) -> Array:
	return WorkspacePage._page_kinds(self, page)


func _kind_page(kind: String) -> String:
	return WorkspacePage._kind_page(self, kind)


func _default_title() -> String:
	return WorkspacePage._default_title(self)


func _pad_title(label: String, kind_label: Label) -> String:
	return WorkspacePage._pad_title(self, label, kind_label)


func _pad_mode(key: String, kind: String) -> int:
	return WorkspacePage._pad_mode(self, key, kind)


func _apply_tax_mode(card: Dictionary, kind: String, spin: SpinBox, mode: int) -> void:
	WorkspacePage._apply_tax_mode(self, card, kind, spin, mode)


func _item_ids(policy: Dictionary) -> PackedStringArray:
	return WorkspacePage._item_ids(self, policy)


func _basis_points_array(preferred, fallback) -> PackedInt32Array:
	return WorkspacePage._basis_points_array(self, preferred, fallback)


func _group_basis_points(group: Dictionary, key: String,
		fallback: PackedInt32Array = PackedInt32Array()) -> PackedInt32Array:
	return TaxCards._group_basis_points(self, group, key, fallback)


func _set_spin_basis_points(spin: SpinBox, rate_basis_points: int,
		mode: int = TAX_MODE_PERCENT_BP) -> void:
	TaxCards._set_spin_basis_points(self, spin, rate_basis_points, mode)


func _configure_spin_for_mode(spin: SpinBox, mode: int) -> void:
	TaxCards._configure_spin_for_mode(self, spin, mode)


func _set_lane_money_icon(spin: SpinBox, shown: bool) -> void:
	TaxCards._set_lane_money_icon(self, spin, shown)


func _card_mode(card: Dictionary, kind: String, fallback: int = TAX_MODE_PERCENT_BP) -> int:
	return TaxCards._card_mode(self, card, kind, fallback)


func _on_mode_selected(index: int, key: String, kind: String) -> void:
	TaxCards._on_mode_selected(self, index, key, kind)


func _ensure_card(page: String, item_id: String, label: String,
		icon_key: String, is_default: bool, item_kinds: Array = []) -> Dictionary:
	return TaxCards._ensure_card(self, page, item_id, label, icon_key, is_default, item_kinds)


func _update_card(card: Dictionary, kind_data: Dictionary) -> void:
	TaxCards._update_card(self, card, kind_data)


func _tax_submission_reflected(card: Dictionary, kind: String,
		data: Dictionary, submitted: Dictionary) -> bool:
	return TaxCards._tax_submission_reflected(self, card, kind, data, submitted)


func _visual_rate(card: Dictionary, kind: String, authoritative_rate: int,
			 overridden: bool) -> int:
	return TaxCards._visual_rate(self, card, kind, authoritative_rate, overridden)


func _format_rate(rate_basis_points: int) -> String:
	return TaxCards._format_rate(self, rate_basis_points)


func _apply_card_frame(card: Dictionary, highlighted: bool) -> void:
	TaxCards._apply_card_frame(self, card, highlighted)


func _watch_card_hover(_panel: PanelContainer) -> void:
	TaxCards._watch_card_hover(self, _panel)


func _refresh_treasury_insights() -> void:
	if _insights == null:
		return
	_insights.visible = _page == "treasury" and not _compact
	if not _insights.visible:
		return
	var fiscal: Dictionary = _model.get("fiscal", {})
	var subsidy := _sum_i64(fiscal.get("subsidy_paid", PackedInt64Array()))
	var requested := _sum_i64(fiscal.get("subsidy_requested", PackedInt64Array()))
	var reserved := _sum_i64(fiscal.get("subsidy_reserved", PackedInt64Array()))
	var gap := maxi(0, requested - subsidy)
	var items: Array = []
	if gap > 0:
		items.append({
			"id": "subsidy_gap",
			"text": ("补贴申请已记账 %s；本次结算未预留，后续按国库可用预算兑现。" % _money(gap)
				if reserved <= 0 else "补贴缺口 %s，当前预留不足。" % _money(gap)),
			"accent": UITokens.RISK,
			"icon": "tax.income",
		})
	# 非税支出：国库现金付给本地商人，不在五类税种的补贴实付里，所以国库页要
	# 逐项说明这笔钱是为科研、开拓还是工程付的。
	var non_tax_ids = fiscal.get("non_tax_outflow_kinds", PackedStringArray())
	var non_tax_values = fiscal.get("non_tax_outflow", PackedInt64Array())
	for index in range(mini(non_tax_ids.size(), non_tax_values.size())):
		var amount := maxi(0, int(non_tax_values[index]))
		if amount <= 0:
			continue
		var meta := {}
		for candidate in EconomyDossierViewModel.NON_TAX_OUTFLOW_KINDS:
			if String(candidate.id) == String(non_tax_ids[index]):
				meta = candidate
				break
		items.append({
			"id": String(non_tax_ids[index]),
			"text": "本批%s %s · %s" % [
				String(meta.get("label", "非税支出")), _money(amount),
				String(meta.get("note", "国库付给本地商人。"))],
			"accent": UITokens.RISK,
			"icon": String(meta.get("icon", "metric.treasury")),
		})
	# 贸易顺逆差与「去市场档案查看」属修饰性说明，改由贸易页数据本身表达。
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


func _on_rate_confirmed(text: String, key: String, kind: String,
		mode_override: int = -1) -> void:
	TaxCommands._on_rate_confirmed(self, text, key, kind, mode_override)


func _on_rate_text_changed(text: String, key: String, kind: String) -> void:
	TaxCommands._on_rate_text_changed(self, text, key, kind)


func _on_rate_focus_entered(key: String, kind: String) -> void:
	TaxCommands._on_rate_focus_entered(self, key, kind)


func _on_rate_focus_exited(key: String, kind: String) -> void:
	TaxCommands._on_rate_focus_exited(self, key, kind)


func _on_rate_preview(value: float, key: String, kind: String) -> void:
	TaxCommands._on_rate_preview(self, value, key, kind)


func _schedule_draft_commit(key: String, kind: String) -> void:
	TaxCommands._schedule_draft_commit(self, key, kind)


func _stop_draft_timer() -> void:
	TaxCommands._stop_draft_timer(self)


func _on_draft_commit_timeout() -> void:
	TaxCommands._on_draft_commit_timeout(self)


func _item_draft_key(kind: String, item_id: String) -> String:
	return TaxCommands._item_draft_key(self, kind, item_id)


func _confirm_spin(key: String, kind: String) -> void:
	TaxCommands._confirm_spin(self, key, kind)


func _default_mode(kind: String) -> int:
	return TaxCommands._default_mode(self, kind)


func _default_rate(kind: String) -> int:
	return TaxCommands._default_rate(self, kind)


func _on_reset_pressed(key: String, kind: String) -> void:
	TaxCommands._on_reset_pressed(self, key, kind)


func _clear_override(kind: String, item_id: String) -> void:
	TaxCommands._clear_override(self, kind, item_id)


func _submit_rate(kind: String, item_id: String, rate: int, is_default: bool,
		mode: int = TAX_MODE_PERCENT_BP) -> void:
	TaxCommands._submit_rate(self, kind, item_id, rate, is_default, mode)


func _refresh_override_frame(card: Dictionary) -> void:
	TaxCommands._refresh_override_frame(self, card)


func _mark_pending(kind: String, item_id: String,
		optimistic_rate: int = 0, op: String = "set",
		mode: int = TAX_MODE_PERCENT_BP) -> void:
	TaxCommands._mark_pending(self, kind, item_id, optimistic_rate, op, mode)


func _has_pending_default(kind: String) -> bool:
	return TaxCommands._has_pending_default(self, kind)


func _resolve_pending_commands() -> void:
	TaxCommands._resolve_pending_commands(self)


func _policy_reflects_pending(key: String, pending: Dictionary) -> bool:
	return TaxCommands._policy_reflects_pending(self, key, pending)


func _effective_day() -> int:
	return TaxCommands._effective_day(self)


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
	_empty_label.visible = false


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
	if _tax_groups == null:
		return
	var raw_search := _search.text.strip_edges()
	_tax_groups.apply_filter(_page, raw_search.to_lower(), raw_search,
		_overrides_only.button_pressed, _rows, _expand_all_button, _empty_label)


func _set_status(text: String, warn: bool = false) -> void:
	_status_label.text = text
	_status_label.visible = text != ""
	_status_label.add_theme_color_override("font_color",
		UITokens.WARN if warn else UITokens.ARCHIVE_INK_MUTED)


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
	return int(round(((card.spins as Dictionary)[kind] as SpinBox).value))


func preview_item_rate_for_test(page: String, item_id: String, kind: String, rate: int) -> void:
	var card: Dictionary = _rows.get("%s:%s" % [page, item_id], {})
	if card.is_empty() or not (card.spins as Dictionary).has(kind):
		return
	((card.spins as Dictionary)[kind] as SpinBox).set_value_no_signal(float(rate))
	_draft_overrides[_item_draft_key(kind, item_id)] = \
		TaxLaneEditor.percent_to_basis_points(float(rate))
	_stop_draft_timer()


func confirm_item_rate_for_test(page: String, item_id: String, kind: String) -> void:
	_confirm_spin("%s:%s" % [page, item_id], kind)


func preview_default_rate_for_test(page: String, kind: String, rate: int) -> void:
	var card: Dictionary = _rows.get("%s:__default__" % page, {})
	if not card.is_empty() and (card.spins as Dictionary).has(kind):
		((card.spins as Dictionary)[kind] as SpinBox).value = float(rate)


func confirm_default_rate_for_test(page: String, kind: String) -> void:
	_confirm_spin("%s:__default__" % page, kind)


func pending_default_rate_for_test(kind: String) -> int:
	var pending: Dictionary = _pending.get("%s:__default__" % kind, {})
	return int(round(TaxLaneEditor.basis_points_to_percent(
		int(pending.get("rate", 100000)))))


func tax_status_text() -> String:
	return _status_label.text if _status_label != null else ""
