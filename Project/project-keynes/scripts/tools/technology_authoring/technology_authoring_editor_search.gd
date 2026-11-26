extends RefCounted

## Indexes technology search and manages the filtered outline and table.

static func _populate_filters(editor: TechnologyAuthoringEditor) -> void:
	editor._fill_option(editor._era_filter, editor._service.model.meta_array("eras"))
	editor._fill_option(editor._domain_filter, editor._service.model.meta_array("domains"))
	var families: Array = editor._service.model.meta_array("backbones") \
		+ editor._service.model.meta_array("branch_families")
	editor._fill_option(editor._family_filter, families)
	editor._role_filter.clear()
	editor._role_filter.add_item("%s（角色）" % TechnologyAuthoringEditor.ALL_LABEL, 0)
	var roles := editor.distinct_values("network_role")
	for index in range(roles.size()):
		editor._role_filter.add_item(String(roles[index]), index + 1)


static func _fill_option(editor: TechnologyAuthoringEditor, option: OptionButton, rows: Array) -> void:
	option.clear()
	option.add_item(TechnologyAuthoringEditor.ALL_LABEL, 0)
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		option.add_item("%s（%s）" % [String(row.get("display_name", "")),
			String(row.get("id", ""))], index + 1)
		option.set_item_metadata(index + 1, String(row.get("id", "")))


static func _selected_filter(editor: TechnologyAuthoringEditor, option: OptionButton) -> String:
	var index := option.get_selected()
	if index <= 0:
		return ""
	var metadata: Variant = option.get_item_metadata(index)
	return String(metadata) if metadata != null else option.get_item_text(index)


static func _apply_filters(editor: TechnologyAuthoringEditor) -> void:
	var started := Time.get_ticks_usec()
	var needle := editor._search.text.strip_edges().to_lower()
	var era := editor._selected_filter(editor._era_filter)
	var domain := editor._selected_filter(editor._domain_filter)
	var family := editor._selected_filter(editor._family_filter)
	var role := editor._role_filter.get_item_text(editor._role_filter.get_selected()) \
		if editor._role_filter.get_selected() > 0 else ""
	var problems_only := editor._problem_only.button_pressed
	editor._filtered = not needle.is_empty() or not era.is_empty() or not domain.is_empty() \
		or not family.is_empty() or not role.is_empty() or problems_only
	editor._match_ids.clear()
	for node_value in editor._service.model.nodes():
		var row: Dictionary = node_value
		var id := String(row.get("id", ""))
		if not era.is_empty() and String(row.get("era_id", "")) != era:
			continue
		if not domain.is_empty() and String(row.get("domain_id", "")) != domain:
			continue
		if not family.is_empty() and String(row.get("branch_family_id", "")) != family:
			continue
		if not role.is_empty() and String(row.get("network_role", "")) != role:
			continue
		if problems_only and not editor._findings_by_node.has(id):
			continue
		if not needle.is_empty() and not editor._matches_text(id, needle):
			continue
		editor._match_ids[id] = true
	editor._last_filter_msec = float(Time.get_ticks_usec() - started) / 1000.0
	editor._canvas.call("set_matches", editor._match_ids, editor._filtered)
	editor._rebuild_outline()
	editor._refresh_table_visibility()


## Real text search across identity, player text, effects and unlocked content,
## replacing the prototype's cosmetic dimming.
##
## The haystack is precomputed per technology because rebuilding it inside the
## keystroke loop cost more than 10ms across 369 nodes, which is felt as lag
## while typing.


static func _matches_text(editor: TechnologyAuthoringEditor, id: String, needle: String) -> bool:
	return String(editor._search_blobs.get(id, "")).contains(needle)


static func _rebuild_search_index(editor: TechnologyAuthoringEditor) -> void:
	editor._search_blobs.clear()
	for node_value in editor._service.model.nodes():
		editor._write_search_blob(String((node_value as Dictionary).get("id", "")))


static func _write_search_blob(editor: TechnologyAuthoringEditor, id: String) -> void:
	var row := editor._service.model.node(id)
	if row.is_empty():
		editor._search_blobs.erase(id)
		return
	var parts := PackedStringArray([id])
	for key in ["display_name", "effect_summary", "reveal_summary", "terminal_reason",
			"opportunity_cost", "network_role", "node_role", "effect_profile",
			"branch_family_id"]:
		parts.append(String(row.get(key, "")))
	for term_value in row.get("modifier_terms", []):
		var term: Dictionary = term_value
		parts.append(String(term.get("stat", "")))
		parts.append(String(term.get("subject_id", "")))
		parts.append(String(term.get("subject_display_name", "")))
	for effect_value in row.get("content_effects", []):
		var effect: Dictionary = effect_value
		parts.append(String(effect.get("id", "")))
		parts.append(String(effect.get("display_name", "")))
	for entry_value in editor._service.index.unlocks_by_technology.get(id, []):
		var entry: Dictionary = entry_value
		parts.append(String(entry.id))
		parts.append(String(entry.display_name))
	editor._search_blobs[id] = "\u0001".join(parts).to_lower()


static func _rebuild_outline(editor: TechnologyAuthoringEditor) -> void:
	editor._outline.clear()
	var root := editor._outline.create_item()
	for era_value in editor._service.model.meta_array("eras"):
		var era: Dictionary = era_value
		var era_id := String(era.get("id", ""))
		var members: Array[Dictionary] = []
		for node_value in editor._service.model.nodes():
			var row: Dictionary = node_value
			if String(row.get("era_id", "")) != era_id:
				continue
			var id := String(row.get("id", ""))
			if editor._filtered and not editor._match_ids.has(id):
				continue
			members.append(row)
		if members.is_empty():
			continue
		var era_item := editor._outline.create_item(root)
		era_item.set_text(0, "%s（%d）" % [String(era.get("display_name", era_id)),
			members.size()])
		era_item.set_selectable(0, false)
		era_item.set_collapsed(members.size() > 24)
		for row in members:
			var id := String(row.get("id", ""))
			var item := editor._outline.create_item(era_item)
			item.set_text(0, "%s  %s" % [String(row.get("display_name", id)),
				id.trim_prefix("tech.")])
			item.set_metadata(0, id)
			var severity := String(editor._severity_by_node.get(id, ""))
			if severity == "error":
				item.set_custom_color(0, UITokens.RISK)
			elif severity == "warning":
				item.set_custom_color(0, UITokens.WARN)


static func _rebuild_table(editor: TechnologyAuthoringEditor) -> void:
	editor._table.clear()
	editor._table_items.clear()
	var root := editor._table.create_item()
	for node_value in editor._service.model.nodes():
		var row: Dictionary = node_value
		var item := editor._table.create_item(root)
		editor._table_items[String(row.get("id", ""))] = item
		editor._write_table_row(item, row)


static func _write_table_row(editor: TechnologyAuthoringEditor, item: TreeItem, row: Dictionary) -> void:
	var id := String(row.get("id", ""))
	item.set_metadata(0, id)
	item.set_text(0, id)
	item.set_text(1, String(row.get("display_name", "")))
	item.set_editable(1, true)
	item.set_text(2, String(row.get("era_id", "")))
	item.set_text(3, String(row.get("domain_id", "")))
	item.set_text(4, String(row.get("branch_family_id", "")))
	item.set_cell_mode(5, TreeItem.CELL_MODE_RANGE)
	item.set_range_config(5, 0.0, 100000000.0, 100.0)
	item.set_range(5, float(row.get("cost_points", 0.0)))
	item.set_editable(5, true)
	item.set_text(6, String(row.get("network_role", "")))
	item.set_text(7, str((row.get("modifier_terms", []) as Array).size()))
	item.set_text(8, str((row.get("content_effects", []) as Array).size()))
	var problems: Array = editor._findings_by_node.get(id, [])
	item.set_text(9, str(problems.size()))
	var severity := String(editor._severity_by_node.get(id, ""))
	for column in range(TechnologyAuthoringEditor.TABLE_COLUMNS.size()):
		if severity == "error":
			item.set_custom_color(column, UITokens.RISK)
		elif severity == "warning":
			item.set_custom_color(column, UITokens.WARN)
		else:
			item.clear_custom_color(column)


static func _refresh_table_visibility(editor: TechnologyAuthoringEditor) -> void:
	for id in editor._table_items:
		var item: TreeItem = editor._table_items[id]
		item.visible = not editor._filtered or editor._match_ids.has(id)


## Applies a search term as if it were typed, for scripted checks.
