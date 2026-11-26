extends RefCounted

## Binds the authored colonization planner controls and signals.


static func _ready(owner: ColonizationPlannerPanel) -> void:
	if owner._list != null:
		return
	owner._title = owner.get_node_or_null("%Title") as Label
	owner._subtitle = owner.get_node_or_null("%Subtitle") as Label
	owner._status = owner.get_node_or_null("%StatusLabel") as Label
	owner._tabs = owner.get_node_or_null("%CategoryTabs") as CategoryTabs
	owner._list = owner.get_node_or_null("%QuoteList") as VBoxContainer
	owner._population_row = owner.get_node_or_null("%PopulationRow") as HBoxContainer
	owner._population_label = owner.get_node_or_null("%PopulationLabel") as Label
	owner._population = owner.get_node_or_null("%PopulationSpin") as SpinBox
	owner._feedback = owner.get_node_or_null("%FeedbackLabel") as Label
	owner._start = owner.get_node_or_null("%StartButton") as Button
	owner._expedition_cancel = owner.get_node("%ExpeditionCancelButton") as Button
	owner._expedition_cancel.pressed.connect(func() -> void:
		if owner._selected_expedition != 0:
			owner.cancel_requested.emit(owner._selected_expedition))
	owner._source_city = owner.get_node_or_null("%SourceCity") as OptionButton
	owner._search = owner.get_node("%FamilySearch") as LineEdit
	owner._sort = owner.get_node("%FamilySort") as OptionButton
	owner._workflow = owner.get_node("%Workflow") as Label
	owner._target_button = owner.get_node("%TargetButton") as Button
	owner._preview_title = owner.get_node("%PreviewTitle") as Label
	owner._preview_metrics = owner.get_node("%PreviewMetrics") as Label
	owner._preview_traits = owner.get_node("%PreviewTraits") as Label
	owner._preview_preferences = owner.get_node("%PreviewPreferences") as Label
	owner._preview_effects = owner.get_node("%PreviewEffects") as Label
	owner._preview_route = owner.get_node("%PreviewRoute") as Label
	# Legacy text mirrors remain available to tests and external readers, but the
	# visual hierarchy uses the dossier cards instead of stacking hidden labels.
	for mirror in [owner._preview_metrics, owner._preview_traits, owner._preview_preferences, owner._preview_effects, owner._preview_route]:
		mirror.visible = false
	owner._footer_selection = owner.get_node("%FooterSelection") as Label
	owner._hover_timer = owner.get_node("%HoverTimer") as Timer
	owner._hover_timer.timeout.connect(owner._show_hover_preview)
	owner._search.text_changed.connect(func(_text: String) -> void: owner._apply_list_filter_sort())
	owner._sort.add_item("可派人数", 0)
	owner._sort.add_item("威望", 1)
	owner._sort.add_item("名称", 2)
	owner._sort.item_selected.connect(func(_index: int) -> void:
		owner._display_order.clear()
		owner._apply_list_filter_sort())
	owner._target_button.pressed.connect(owner.begin_target_selection)
	var close_button := owner.get_node_or_null("%CloseButton") as Button
	if owner._title == null or owner._subtitle == null or owner._status == null or owner._tabs == null \
			or owner._list == null or owner._population_row == null or owner._population_label == null or owner._population == null \
			or owner._feedback == null or owner._start == null or owner._source_city == null or close_button == null:
		push_error("ColonizationPlannerPanel 必须通过 colonization_planner_panel.tscn 实例化。")
		return
	owner.theme_type_variation = &"PKArchivePanel"
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(owner.close_panel)
	owner._tabs.set_tabs([
		{"id": "quotes", "label": "可派遣", "icon": "family.house",
			"tooltip": "可派往此地的家族", "accent": UITokens.ACCENT},
		{"id": "expeditions", "label": "进行中", "icon": "action.history",
			"tooltip": "筹备中和已出发的开拓队", "accent": UITokens.CLIMATE},
	], "quotes", true)
	owner._tabs.tab_selected.connect(owner._on_tab_selected)
	owner._population.value_changed.connect(func(_value: float) -> void:
		owner._refresh_selected_kit()
		if owner._hover_family.is_empty() and not owner._selected_quote.is_empty() and owner._preview_family > 0:
			owner._show_family_preview(owner._selected_quote))
	owner._start.pressed.connect(owner._submit_selected)
	owner._source_city.item_selected.connect(owner._on_source_city_selected)
	owner._bind_atlas_shell()
	if owner.is_inside_tree():
		owner.get_viewport().size_changed.connect(owner._layout_left_panel)
	owner._layout_left_panel()
	owner.visible = false
