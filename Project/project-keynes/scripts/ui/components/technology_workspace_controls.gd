extends RefCounted

## Builds the authored technology workspace and binds its controls.


static func _ready(owner: TechnologyWorkspace) -> void:
	if owner._tree != null:
		return
	owner.set_process(false)
	var required_paths := {
		"policy_panel": "Root/Main/PolicyPanel",
		"dial": "Root/Main/PolicyPanel/Scroll/Body/Allocation",
		"budget": "Root/Main/PolicyPanel/Scroll/Body/Budget",
		"available": "Root/Main/Available",
		"tree": "Root/Main/Tree",
		"overview": "Root/Main/Overview",
		"detail_host": "Root/Main/DetailHost",
		"detail": "Root/Main/DetailHost/Body/Detail",
		"development_title": "Root/Main/PolicyPanel/Scroll/Body/DevelopmentTitle",
		"development_list": "Root/Main/PolicyPanel/Scroll/Body/DevelopmentList",
	}
	owner._policy_panel = owner.get_node_or_null(required_paths.policy_panel) as PanelContainer
	owner._dial = owner.get_node_or_null(required_paths.dial) as Control
	owner._budget = owner.get_node_or_null(required_paths.budget) as Control
	owner._available = owner.get_node_or_null(required_paths.available) as Control
	owner._tree = owner.get_node_or_null(required_paths.tree) as Control
	owner._overview = owner.get_node_or_null(required_paths.overview) as Control
	owner._detail_host = owner.get_node_or_null(required_paths.detail_host) as PanelContainer
	owner._policy_rail = owner.get_node_or_null("Root/Main/PolicyRail") as Button
	owner._detail_rail = owner.get_node_or_null("Root/Main/DetailRail") as Button
	owner._policy_close = owner.get_node_or_null("Root/Main/PolicyPanel/Scroll/Body/Header/Close") as Button
	owner._detail_close = owner.get_node_or_null("Root/Main/DetailHost/Body/Header/Close") as Button
	owner._detail = owner.get_node_or_null(required_paths.detail) as Control
	owner._main = owner.get_node_or_null("Root/Main") as Control
	owner._mode_nav = owner.get_node_or_null("Root/Toolbar/Row/ModeNav") as DossierChapterNav
	owner._era_plate = owner.get_node_or_null("Root/Toolbar/Row/EraPlate") as Control
	owner._prev_era = owner.get_node_or_null("Root/Toolbar/Row/EraPlate/EraRow/PrevEra") as Button
	owner._next_era = owner.get_node_or_null("Root/Toolbar/Row/EraPlate/EraRow/NextEra") as Button
	owner._era_label = owner.get_node_or_null("Root/Toolbar/Row/EraPlate/EraRow/EraLabel") as Label
	owner._search = owner.get_node_or_null("Root/Toolbar/Row/Search") as LineEdit
	owner._detail_header = owner.get_node_or_null("Root/Main/DetailHost/Body/Header") as Control
	if owner._policy_panel == null or owner._dial == null or owner._budget == null \
			or owner._available == null or owner._tree == null or owner._overview == null or owner._detail == null \
			or owner._detail_host == null or owner._main == null or owner._mode_nav == null \
			or owner._era_plate == null or owner._prev_era == null \
			or owner._next_era == null or owner._era_label == null or owner._search == null:
		var missing := PackedStringArray()
		for key in required_paths:
			if owner.get_node_or_null(required_paths[key]) == null:
				missing.append(String(required_paths[key]))
		for extra in ["Root/Toolbar/Row/ModeNav",
				"Root/Toolbar/Row/EraPlate/EraRow/PrevEra",
				"Root/Toolbar/Row/EraPlate/EraRow/NextEra",
				"Root/Toolbar/Row/EraPlate/EraRow/EraLabel",
				"Root/Toolbar/Row/Search"]:
			if owner.get_node_or_null(extra) == null:
				missing.append(extra)
		push_error("TechnologyWorkspace 必须通过 technology_workspace.tscn 实例化；缺失节点：%s" \
			% ", ".join(missing))
		return
	for key in TechnologyWorkspace.KPI_IDS:
		var card := owner.get_node_or_null("Root/KpiBand/Row/%s" % String(key)) as DossierKpiCard
		if card != null:
			owner._kpi_cards[String(key)] = card
	var last_card := owner._kpi_cards.get(TechnologyWorkspace.KPI_IDS[TechnologyWorkspace.KPI_IDS.size() - 1]) as DossierKpiCard
	if last_card != null:
		last_card.show_divider = false
	# DossierChapterNav's _init defaults (fill width) override scene values, and
	# a fill-width nav would resize whenever the era stepper toggles.
	owner._mode_nav.custom_minimum_size = Vector2(TechnologyWorkspace.MODE_NAV_WIDTH, DossierChapterNav.HEIGHT)
	owner._mode_nav.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	owner._mode_nav.set_chapters([
		{"id": "available", "label": "可研究", "icon": &"technology.state.available", "question": ""},
		{"id": "focus", "label": "科技树", "icon": &"country.technology", "question": ""},
		{"id": "overview", "label": "总览", "icon": &"technology.milestone", "question": ""},
	], "available")
	owner._mode_nav.chapter_selected.connect(owner._on_mode_chapter_selected)
	for domain in range(TechnologyWorkspace.DOMAIN_COUNT):
		var header := owner.get_node("Root/Main/PolicyPanel/Scroll/Body/Domain%d" % domain) as HBoxContainer
		var zone := owner.get_node("Root/Main/PolicyPanel/Scroll/Body/Zone%d" % domain)
		owner._queue_headers.append({"icon": header.get_node("Icon"), "name": header.get_node("Name"), "share": header.get_node("Share")})
		zone.configure(domain)
		zone.move_requested.connect(owner._move_in_queue)
		owner._queue_zones.append(zone)
		owner._queue_rows.append([])
	owner._dial.weights_previewed.connect(owner._on_weights_previewed)
	owner._dial.weights_committed.connect(owner._on_weights_committed)
	owner._budget.open_budget_requested.connect(owner._on_open_budget_requested)
	owner._available.technology_selected.connect(owner._on_available_selected)
	owner._available.technology_activated.connect(owner._on_tree_activated)
	owner._available.show_in_tree_requested.connect(owner._focus_technology)
	owner._available.enqueue_requested.connect(owner._enqueue)
	owner._available.remove_requested.connect(owner._remove_from_queue)
	owner._tree.technology_selected.connect(owner._on_tree_selected)
	owner._tree.technology_activated.connect(owner._on_tree_activated)
	owner._tree.portal_requested.connect(owner._focus_technology)
	owner._overview.cell_activated.connect(owner._on_overview_cell_activated)
	owner._detail.enqueue_requested.connect(owner._enqueue)
	owner._detail.remove_requested.connect(owner._remove_from_queue)
	owner._prev_era.pressed.connect(func() -> void: owner._shift_era(-1))
	owner._next_era.pressed.connect(func() -> void: owner._shift_era(1))
	owner._search.text_submitted.connect(owner._on_search_submitted)
	IconButton.apply(owner._prev_era, &"action.back", IconButton.SMALL, "上一个已知时代")
	IconButton.apply(owner._next_era, &"action.chevron_right", IconButton.SMALL, "下一个已知时代")
	IconButton.apply(owner._policy_rail, &"action.chevron_right", IconButton.MEDIUM, "打开研究管理")
	IconButton.apply(owner._detail_rail, &"action.back", IconButton.MEDIUM, "打开科技详情")
	IconButton.apply(owner._policy_close, &"action.close", IconButton.SMALL, "收起研究管理")
	IconButton.apply(owner._detail_close, &"action.close", IconButton.SMALL, "收起科技详情")
	owner._policy_rail.pressed.connect(owner._set_policy_open.bind(true))
	owner._detail_rail.pressed.connect(owner._set_detail_open.bind(true))
	owner._policy_close.pressed.connect(owner._set_policy_open.bind(false))
	owner._detail_close.pressed.connect(owner._set_detail_open.bind(false))
	var relocate := owner.get_node("Root/Toolbar/Row/Relocate") as Button
	IconButton.apply(relocate, &"system.target", IconButton.SMALL, "重新定位研究前沿")
	relocate.pressed.connect(owner._apply_default_focus)
	TechnologyWorkspace.TouchUI.watch(owner)
	if TechnologyWorkspace.TouchUI.is_short_viewport():
		owner._update_effective_compact()
	else:
		owner._apply_column_layout()
