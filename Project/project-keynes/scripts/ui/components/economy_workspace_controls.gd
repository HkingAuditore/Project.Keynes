extends RefCounted

## Creates workspace sections and binds authored interactive controls.


static func _ready(owner: EconomyWorkspace) -> void:
	if owner._cash_card != null:
		return
	owner.set_process(false)
	owner._cash_card = owner.get_node_or_null("Viewport/Column/Cards/CashCard") as MetricCard
	owner._tax_card = owner.get_node_or_null("Viewport/Column/Cards/TaxCard") as MetricCard
	owner._subsidy_card = owner.get_node_or_null("Viewport/Column/Cards/SubsidyCard") as MetricCard
	owner._fulfillment_card = owner.get_node_or_null("Viewport/Column/Cards/FulfillmentCard") as MetricCard
	owner._country_label = owner.get_node_or_null("Viewport/Column/Header/CountryLabel") as Label
	owner._day_label = owner.get_node_or_null("Viewport/Column/Header/DayLabel") as Label
	owner._tabs = owner.get_node_or_null("Viewport/Column/Tabs") as CategoryTabs
	owner._tax_tabs = owner.get_node_or_null("Viewport/Column/TaxTabs") as CategoryTabs
	owner._insights = owner.get_node_or_null("Viewport/Column/Insights") as InsightList
	var ledger_root := "Viewport/Column/Ledger/LedgerColumn"
	owner._search = owner.get_node_or_null(ledger_root + "/Tools/Search") as LineEdit
	owner._overrides_only = owner.get_node_or_null(ledger_root + "/Tools/OverridesOnly") as Button
	owner._group_axis_picker = owner.get_node_or_null(ledger_root + "/Tools/GroupAxis") as OptionButton
	owner._expand_all_button = owner.get_node_or_null(ledger_root + "/Tools/ExpandAllGroups") as Button
	owner._status_label = owner.get_node_or_null(ledger_root + "/StatusLabel") as Label
	owner._goods_heading = owner.get_node_or_null(ledger_root + "/GoodsHeading") as Control
	owner._scroll = owner.get_node_or_null(ledger_root + "/Scroll") as ScrollContainer
	owner._default_tax_host = owner.get_node_or_null("%DefaultTaxHost") as Control
	owner._tax_group_list = owner.get_node_or_null("%TaxGroupList") as VBoxContainer
	owner._flow = owner.get_node_or_null("%Flow") as HFlowContainer
	owner._empty_label = owner.get_node_or_null("%EmptyLabel") as Label
	owner._trade_views = owner.get_node_or_null(ledger_root + "/Tools/TradeViews") as HBoxContainer
	owner._trade_goods_button = owner.get_node_or_null(ledger_root + "/Tools/TradeViews/Goods") as Button
	owner._trade_partners_button = owner.get_node_or_null(ledger_root + "/Tools/TradeViews/Partners") as Button
	owner._trade_prev = owner.get_node_or_null(ledger_root + "/Tools/TradePrev") as Button
	owner._trade_next = owner.get_node_or_null(ledger_root + "/Tools/TradeNext") as Button
	owner._trade_page_label = owner.get_node_or_null(ledger_root + "/Tools/TradePage") as Label
	owner._ledger_title = owner.get_node_or_null(ledger_root + "/LedgerHeading/Title") as Label
	owner._ledger_subtitle = owner.get_node_or_null(ledger_root + "/LedgerHeading/Subtitle") as Label
	owner._summary_heading = owner.get_node_or_null("Viewport/Column/SummaryHeading") as Control
	owner._summary_cards = owner.get_node_or_null("Viewport/Column/Cards") as Control
	owner._fiscal_page = owner.get_node_or_null(ledger_root + "/FiscalPage") as Control
	var section_badge := owner.get_node_or_null("Viewport/Column/Header/SectionIcon") as IconBadge
	if owner._cash_card == null or owner._tax_card == null or owner._subsidy_card == null \
			or owner._fulfillment_card == null or owner._country_label == null \
			or owner._day_label == null or owner._tabs == null or owner._search == null \
			or owner._overrides_only == null or owner._status_label == null \
			or owner._scroll == null or owner._flow == null or owner._empty_label == null \
			or section_badge == null:
		push_error("EconomyWorkspace 必须通过 economy_workspace.tscn 实例化。")
		return
	section_badge.set_semantic(&"tax.section", UITokens.BRASS_HIGHLIGHT)
	owner._tabs.tab_selected.connect(owner._select_page)
	if owner._tax_tabs != null:
		owner._tax_tabs.tab_selected.connect(owner._select_page)
	owner._search.text_changed.connect(owner._apply_filter.unbind(1))
	owner._overrides_only.toggled.connect(owner._apply_filter.unbind(1))
	owner._tax_groups = EconomyWorkspace.TaxGroupControllerScript.new(owner)
	owner._tax_groups.bind_toolbar(owner._group_axis_picker, owner._expand_all_button)
	if owner._trade_goods_button != null:
		owner._trade_goods_button.pressed.connect(owner._select_trade_view.bind("goods"))
	if owner._trade_partners_button != null:
		owner._trade_partners_button.pressed.connect(owner._select_trade_view.bind("partners"))
	if owner._trade_prev != null:
		owner._trade_prev.pressed.connect(owner._trade_previous_page)
	if owner._trade_next != null:
		owner._trade_next.pressed.connect(owner._trade_next_page)
	if owner._trade_prev != null:
		IconButton.apply(owner._trade_prev, &"action.back", IconButton.MEDIUM, "上一页")
	if owner._trade_next != null:
		IconButton.apply(owner._trade_next, &"action.chevron_right", IconButton.MEDIUM, "下一页")
	if owner._fiscal_page != null:
		owner._fiscal_page.set_player_controller(owner._player_controller)
		owner._fiscal_page.procurement_committed.connect(owner._on_procurement_committed)
		owner._fiscal_page.military_budget_committed.connect(
			owner._on_military_budget_committed)
	owner._draft_timer = Timer.new()
	owner._draft_timer.one_shot = true
	owner._draft_timer.wait_time = EconomyWorkspace.DRAFT_COMMIT_DELAY_SEC
	owner._draft_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	owner._draft_timer.timeout.connect(owner._on_draft_commit_timeout)
	owner.add_child(owner._draft_timer)
	# 触摸档：把页签、关闭、搜索框、税率行、滚动条一次性抬到 44dp（桌面档 no-op）。
	# 之后动态生成的税卡/贸易行由 child_entered_tree 继续兜住。
	EconomyWorkspace.TouchUI.watch(owner)
	# 手机纵向只有 873 设计像素：默认就收掉摘要卡与洞察条，把高度让给可滚动的账本。
	if EconomyWorkspace.TouchUI.is_short_viewport():
		owner.set_compact(true)
	owner._select_page("treasury")
