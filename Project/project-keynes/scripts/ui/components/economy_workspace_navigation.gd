extends RefCounted

## Coordinates economy chapters and their budget controls.


static func _refresh_tabs(owner: EconomyWorkspace) -> void:
	var treasury: Dictionary = owner._model.get("treasury", {})
	var signature_parts: Array[String] = []
	var tabs: Array = []
	for page in EconomyWorkspace.TOP_PAGE_IDS:
		if owner._embedded and page == "trade":
			continue
		var definition: Dictionary = EconomyWorkspace.PAGE_DEFINITIONS[page]
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
	if signature == owner._tab_signature and owner._tabs.get_child_count() > 0:
		owner._tabs.select_tab(owner._top_page_for(owner._page))
		return
	owner._tab_signature = signature
	owner._tabs.set_tabs(tabs, owner._top_page_for(owner._page), true)



static func _refresh_tax_tabs(owner: EconomyWorkspace) -> void:
	if owner._tax_tabs == null:
		return
	var tax_open := owner._is_tax_page(owner._page)
	owner._tax_tabs.visible = tax_open
	if not tax_open:
		return
	var presentation: Dictionary = owner._model.get("tax_presentation", {})
	var signature_parts: Array[String] = []
	var tabs: Array = []
	for page in EconomyWorkspace.TAX_PAGE_IDS:
		var definition: Dictionary = EconomyWorkspace.PAGE_DEFINITIONS[page]
		var page_pres: Dictionary = presentation.get(page, {})
		var unlocked_count := (page_pres.get("unlocked", []) as Array).size()
		var total := int(page_pres.get("total_count", 0))
		signature_parts.append("%s:%d:%d" % [page, unlocked_count, total])
		tabs.append({"id": page, "label": String(definition.label),
			"icon": definition.icon,
			"tooltip": "%s · 已解锁 %d/%d" % [String(definition.label), unlocked_count, total]})
	var signature := "|".join(signature_parts)
	if signature == owner._tax_tab_signature and owner._tax_tabs.get_child_count() > 0:
		owner._tax_tabs.select_tab(owner._page)
		return
	owner._tax_tab_signature = signature
	owner._tax_tabs.set_tabs(tabs, owner._page, true)



static func _select_page(owner: EconomyWorkspace, page: String) -> void:
	if page == "tax":
		page = owner._page if owner._is_tax_page(owner._page) else "income"
	if owner._is_tax_page(page):
		owner._last_tax_page = page
	owner._page = page
	owner._apply_summary_visibility()
	if owner._tabs != null:
		owner._tabs.select_tab(owner._top_page_for(page))
	if owner._tax_tabs != null:
		owner._refresh_tax_tabs()
		owner._tax_tabs.visible = owner._is_tax_page(page)
		if owner._tax_tabs.visible:
			owner._tax_tabs.select_tab(page)
	if owner._search != null:
		owner._search.visible = owner._is_tax_page(page)
		owner._overrides_only.visible = owner._is_tax_page(page)
	if owner._tax_groups != null:
		owner._tax_groups.sync_toolbar_visibility(owner._is_tax_page(page), owner._group_axis_picker, owner._expand_all_button)
	if owner._trade_views != null:
		owner._trade_views.visible = page == "trade"
		owner._trade_prev.visible = page == "trade"
		owner._trade_next.visible = page == "trade"
		owner._trade_page_label.visible = page == "trade"
	if owner._insights != null:
		owner._insights.visible = page == "treasury" and not owner._compact
	if owner._ledger_title != null:
		var definition: Dictionary = EconomyWorkspace.PAGE_DEFINITIONS.get(page, {})
		owner._ledger_title.text = String(definition.get("label", "财政"))
		owner._ledger_subtitle.text = owner._page_description(page)
		owner._ledger_subtitle.visible = not owner._ledger_subtitle.text.is_empty()
	owner._apply_budget_visibility(page)
	owner._refresh_page()
	owner._refresh_treasury_insights()
	owner._refresh_budget()
	owner._animate_cards_in()



static func _top_page_for(owner: EconomyWorkspace, page: String) -> String:
	return "tax" if owner._is_tax_page(page) else page


## 预算卷宗只在「国库」页出现：上半部调份额，下半部仍是国库物资列表。
## 两者共用账本区，不再互斥，所以玩家不必先记住「预算在另一个页签里」。
static func _apply_budget_visibility(owner: EconomyWorkspace, page: String) -> void:
	var show_budget := page == "treasury" and owner._fiscal_page != null
	if owner._goods_heading != null:
		owner._goods_heading.visible = page == "treasury"
	if owner._fiscal_page != null:
		var was_visible := owner._fiscal_page.visible
		owner._fiscal_page.visible = show_budget
		# 打开：滑入 + 淡入（180ms）。切页是玩家动作而非模拟事件，
		# 不做额外节流；减动效偏好直接跳过。
		if show_budget and not was_visible:
			owner._play_fiscal_entrance()
		if show_budget:
			owner._apply_budget_model()
	# 国库页的物资卡片只占一行，把账本剩余高度全让给预算卷宗；
	# 税制 / 贸易页仍要一整块可滚动的主列表。
	if owner._scroll != null:
		if show_budget:
			owner._scroll.size_flags_vertical = Control.SIZE_FILL
			owner._scroll.custom_minimum_size = Vector2(0.0, 88.0)
		else:
			owner._scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
			owner._scroll.custom_minimum_size = Vector2(0.0, 0.0)
	if owner._status_label != null:
		owner._status_label.visible = owner._status_label.text != ""


## 预算卷宗入场：整块滑入淡入。只对页面本身做一次，不逐板块错峰——
## 板块里有可拖控件，错峰期间的可点击区域会和视觉位置错开。
static func _play_fiscal_entrance(owner: EconomyWorkspace) -> void:
	if owner._fiscal_page == null or UIAnimation.reduced_motion():
		return
	UIAnimation.fade_slide_in(owner._fiscal_page, Vector2(22.0, 0.0), 0.18)



static func _apply_budget_model(owner: EconomyWorkspace) -> void:
	if owner._fiscal_page == null:
		return
	owner._fiscal_page.set_compact(owner._compact)
	# 分区只在首次进入时构建；之后切回沿用同一批节点，只刷新读数，
	# 这样滑条不会因为来回切页签被销毁重建。
	owner._fiscal_page.set_model(owner._model, false)


## 测试入口：财政页（未实例化时为 null）。
static func fiscal_page(owner: EconomyWorkspace) -> Control:
	return owner._fiscal_page



static func _is_tax_page(owner: EconomyWorkspace, page: String) -> bool:
	return EconomyWorkspace.TAX_PAGE_IDS.has(page)



static func _page_description(owner: EconomyWorkspace, page: String) -> String:
	return "预算调配 · 国库物资" if page == "treasury" else ""
