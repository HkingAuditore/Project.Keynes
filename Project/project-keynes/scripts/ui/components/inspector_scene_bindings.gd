extends RefCounted

## Finds and checks the scene-owned controls used by the inspector.


static func bind(panel) -> Button:
	panel._kicker_label = panel.get_node_or_null("%KickerLabel") as Label
	panel._title_label = panel.get_node_or_null("%TitleLabel") as Label
	panel._subtitle_label = panel.get_node_or_null("%SubtitleLabel") as Label
	panel._titles_box = panel.get_node_or_null("%Titles") as Control
	panel._summary_band = panel.get_node_or_null("%Summary") as Control
	var kpi_row: Node = panel.get_node_or_null("%KpiRow")
	panel._kpi_cards.clear()
	if kpi_row != null:
		for child in kpi_row.get_children():
			if child is DossierKpiCard:
				(child as Control).custom_minimum_size = Vector2(80.0, DossierKpiCard.HEIGHT)
				panel._kpi_cards.append(child)
	panel._chapter_nav = panel.get_node_or_null("%ChapterNav") as DossierChapterNav
	panel._scroll = panel.get_node_or_null("%Scroll") as ScrollContainer
	panel._content_box = panel.get_node_or_null("%ContentBox") as VBoxContainer
	panel._list_shell = panel.get_node_or_null("%ListShell") as PanelContainer
	panel._list_scroll = panel.get_node_or_null("%ListScroll") as ScrollContainer
	panel._list_content = panel.get_node_or_null("%ListContent") as VBoxContainer
	panel._inspector_root = panel.get_node_or_null("%InspectorRoot") as VBoxContainer
	panel._detail_shell = panel.get_node_or_null("%DetailShell") as PanelContainer
	panel._object_detail_dialog = panel.get_node_or_null("%ObjectDetail") as ObjectDetailDialog
	panel._family_workspace = panel.get_node_or_null("%FamilyWorkspace") as FamilyWorkspace
	panel._military_dossier = panel.get_node_or_null("%MilitaryDossier") as MilitaryDossier
	panel._construction_workspace = panel.get_node_or_null("%BuildingWorkspace") as BuildingWorkspace
	panel._clear_tax_confirmation = panel.get_node_or_null("%ClearTaxConfirmation") as ConfirmationDialog
	panel._colonization_button = panel.get_node_or_null("%ColonizationButton") as Button
	var close_button := panel.get_node_or_null("%CloseButton") as Button
	if panel._title_label == null or panel._subtitle_label == null or panel._kicker_label == null \
			or panel._kpi_cards.size() != 4 or panel._chapter_nav == null or panel._scroll == null \
			or panel._content_box == null or close_button == null or panel._detail_shell == null \
			or panel._object_detail_dialog == null or panel._family_workspace == null \
			or panel._construction_workspace == null:
		push_error("InspectorPanel 必须通过 inspector_panel.tscn 实例化。")
		return null
	return close_button
