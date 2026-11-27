extends RefCounted

## Coordinates the inspector tax rows and their pending receipts.


## 税率编辑收进页尾的折叠「税务」节：默认收起，节头直接给出当前税率，
## 展开后才是可编辑的税档。_page_tax_section 指向整个折叠节，
## 打开对象详情时整节隐藏（对象详情自带对象级税档）。
##
## 多个税档（市场页的交易 / 进口 / 出口）在节内再各占一个可折叠子节：
## 三个税种一次全摊开会把页尾拉得很长，玩家通常只调其中一条。
static func _build_page_tax_section(panel, context: Dictionary) -> void:
	panel._page_tax_editors.clear()
	panel._page_tax_lane_summaries.clear()
	panel._page_tax_section = null
	panel._reset_tax_button = null
	panel._tax_page_cell = int(context.get("cell", -1))
	var defaults: Array = context.get("default_lanes", [])
	if defaults.is_empty():
		return
	var body: VBoxContainer = panel._add_collapsible_section({
		"id": "page_tax", "title": panel._page_tax_title(panel._current_tab),
		"icon": "tax.section", "accent": UITokens.BRASS_HIGHLIGHT,
		"collapsed": true, "summary": panel._tax_summary(defaults),
	})
	panel._page_tax_section = body.get_parent() as Control
	var section := panel.TaxSectionScene.instantiate() as VBoxContainer
	body.add_child(section)
	(section.get_node("Head") as Control).visible = false
	var editable := bool(context.get("editable", false))
	var hint := section.get_node("Hint") as Label
	if not bool(context.get("available", true)):
		var reason := String(context.get("reason", ""))
		hint.text = reason
		hint.visible = not reason.is_empty()
	elif not editable:
		hint.text = "仅可查看该国当前政策。"
		hint.visible = true
	else:
		# 可用时不写常驻说明：默认税率与待生效状态各自由税行自己给出。
		hint.text = ""
		hint.visible = false
	var lanes := section.get_node("Lanes") as VBoxContainer
	if defaults.size() <= 1:
		for raw in defaults:
			var lane: Dictionary = raw
			panel._add_page_tax_lane(lanes, lane)
	else:
		for raw in defaults:
			var lane: Dictionary = raw
			panel._add_page_tax_lane_subsection(lanes, lane)
	lanes.visible = not defaults.is_empty()
	panel._reset_tax_button = panel.ActionButtonScene.instantiate() as Button
	panel._reset_tax_button.text = "重置本栏税收设置"
	panel._reset_tax_button.tooltip_text = "清除此栏税种在本地的默认税率和全部单项覆盖，恢复沿用国家政策。"
	panel._reset_tax_button.pressed.connect(panel._request_category_tax_reset)
	body.add_child(panel._reset_tax_button)
	panel._update_reset_tax_button()
	panel._sync_page_tax_visibility()


## 单条税档：实例化一行并登记，草稿 / 待生效状态沿用既有那一套。
static func _add_page_tax_lane(panel, parent: VBoxContainer, lane: Dictionary) -> void:
	var editor := panel.TaxLaneScene.instantiate() as TaxLaneEditor
	parent.add_child(editor)
	editor.set_data(lane)
	panel._restore_lane_pending(editor, lane)
	panel._page_tax_editors.append(editor)



static func _tax_lane_icon(panel, kind: String) -> StringName:
	var icons := {
		"income": &"tax.income",
		"consumption": &"tax.consumption",
		"business": &"tax.business",
		"import": &"tax.tariff",
		"export": &"tax.tariff",
	}
	return StringName(icons.get(kind, &"tax.section"))



static func _page_tax_title(panel, tab_id: String) -> String:
	return {
		"population": "此地所得税",
	"market": "此地交易税与关税",
		"buildings": "此地营业税",
	}.get(tab_id, "此地税率")



static func _tax_summary(panel, lanes: Array) -> String:
	var parts := PackedStringArray()
	var adjusted := false
	for lane_value in lanes:
		var lane: Dictionary = lane_value
		var label := String(lane.get("kind_label", "")).trim_prefix("此地")
		parts.append("%s %s" % [label, TaxLaneEditor._format_value(
			int(lane.get("base", 0)), int(lane.get("mode", 0)))])
		adjusted = adjusted or bool(lane.get("has_override", false))
	var text := " · ".join(parts) if parts.size() <= 1 \
		else "%s 等 %d 项" % [parts[0], parts.size()]
	return "%s · %s" % [text, "已调整" if adjusted else "沿用国家"]



static func _restore_lane_pending(panel, editor: TaxLaneEditor, lane: Dictionary) -> void:
	panel.InspectorTaxDrafts._restore_lane_pending(panel._pending_tax, panel._tax_key, editor, lane)



static func _rebuild_tax_editor_registry(panel) -> void:
	panel._tax_editors.clear()
	panel._register_tax_editors(panel._page_tax_editors)
	if panel._object_detail_dialog != null and panel._object_detail_dialog.visible:
		panel._register_tax_editors(panel._object_detail_dialog.tax_editors())
	panel._sync_page_tax_visibility()



static func _sync_page_tax_visibility(panel) -> void:
	if panel._page_tax_section == null:
		return
	var inspecting: bool = panel._object_detail_dialog != null and panel._object_detail_dialog.visible
	panel._page_tax_section.visible = not inspecting



static func _apply_page_tax_patch(panel, context: Dictionary) -> void:
	var defaults: Array = context.get("default_lanes", [])
	var by_kind := {}
	for lane_value in defaults:
		var lane: Dictionary = lane_value
		by_kind[String(lane.get("kind", ""))] = lane
	for editor_value in panel._page_tax_editors:
		var editor := editor_value as TaxLaneEditor
		if editor == null:
			continue
		var kind := String(editor.lane_data().get("kind", ""))
		if by_kind.has(kind):
			var lane: Dictionary = by_kind[kind]
			editor.set_data(lane)
			panel._restore_lane_pending(editor, lane)
			var sub_summary := panel._page_tax_lane_summaries.get(kind) as Label
			if is_instance_valid(sub_summary):
				sub_summary.text = TaxLaneEditor._format_value(
					int(lane.get("base", 0)), int(lane.get("mode", 0)))
				sub_summary.visible = not sub_summary.text.is_empty()
	var outer_refs: Dictionary = panel._section_refs.get("page_tax", {})
	var outer_summary := outer_refs.get("summary") as Label
	if is_instance_valid(outer_summary) and not defaults.is_empty():
		outer_summary.text = panel._tax_summary(defaults)
		outer_summary.visible = not outer_summary.text.is_empty()



static func _register_tax_editors(panel, editors: Array) -> void:
	for editor_value in editors:
		panel._register_tax_editor(editor_value as TaxLaneEditor)



static func _register_tax_editor(panel, editor: TaxLaneEditor) -> void:
	if editor == null:
		return
	if not editor.override_requested.is_connected(panel._on_tax_override_requested):
		editor.override_requested.connect(panel._on_tax_override_requested)
	if not editor.reset_requested.is_connected(panel._on_tax_reset_requested):
		editor.reset_requested.connect(panel._on_tax_reset_requested)
	var key := editor.editor_key(panel._cell_index)
	var refs: Array = panel._tax_editors.get(key, [])
	if not refs.has(editor):
		refs.append(editor)
	panel._tax_editors[key] = refs
	if panel._pending_tax.has(key):
		var pending: Dictionary = panel._pending_tax[key]
		editor.mark_pending(int(pending.get(
			"rate", editor.lane_data().get("base", 0))))


## 对象详情 / 地方面板的整组轴：与总面板同源（tax_group_map.gd 的 SUBJECT_AXES），
## 末尾再挂一条「全部」——它直接取国家税快照的整份 id，不经过目录。
## subject 由调用方按被查看的对象给：建筑 / 物资 / 职业各一组轴。
static func tax_group_axes(panel, subject: String = "building") -> Array:
	var axes: Array = panel.InspectorTaxGroups.tax_group_axes(subject)
	axes.append({"id": panel.TAX_GROUP_ALL_MODE, "label": "全部",
		"hint": "该国这个税种下的全部项目"})
	return axes



static func tax_group_ids_for(panel, mode: String, item_id: String,
		subject: String = "building") -> Dictionary:
	return panel.InspectorTaxGroups.resolve_group_ids_for(
		panel._player_controller, panel._tax_page_cell, mode, item_id, subject)



static func request_tax_group_override(panel, kind: int, item_ids: PackedStringArray,
		rate_basis_points: int, assessment_mode: int = 0) -> Dictionary:
	return panel.InspectorTaxGroups.submit_group_override(
		panel._player_controller, kind, item_ids, rate_basis_points, assessment_mode)



static func _on_tax_override_requested(panel,
		scope: String,
		kind: String,
		item_id: String,
		rate: int,
		mode: int = 0
) -> void:
	if panel._player_controller == null or panel._cell_index < 0:
		return
	var kind_id := int(panel.TAX_KIND_IDS.get(kind, -1))
	if kind_id < 0:
		return
	var command := &"country.tax.cell.set_default" \
		if scope == "default" else &"country.tax.cell.set_override"
	var args := {
		"cell": panel._cell_index,
		"kind": kind_id,
		"rate_basis_points": rate,
		"tax_assessment_mode": mode,
	}
	if scope != "default":
		args["item_id"] = StringName(item_id)
	var result: Dictionary = panel._player_controller.request_command(command, args)
	var key: String = panel._tax_key(kind, item_id if scope != "default" else "default")
	if bool(result.get("ok", false)):
		panel._mark_tax_pending(key, rate, result, "set", mode)
	else:
		panel._resolve_tax_editor_key(key)



static func _on_tax_reset_requested(panel, scope: String, kind: String, item_id: String) -> void:
	if panel._player_controller == null or panel._cell_index < 0:
		return
	var kind_id := int(panel.TAX_KIND_IDS.get(kind, -1))
	if kind_id < 0:
		return
	var command := &"country.tax.cell.clear_default" \
		if scope == "default" else &"country.tax.cell.clear_override"
	var args := {"cell": panel._cell_index, "kind": kind_id}
	if scope != "default":
		args["item_id"] = StringName(item_id)
	var result: Dictionary = panel._player_controller.request_command(command, args)
	var key: String = panel._tax_key(kind, item_id if scope != "default" else "default")
	if bool(result.get("ok", false)):
		var refs: Array = panel._tax_editors.get(key, [])
		var rate := 0
		if not refs.is_empty():
			rate = int((refs[0] as TaxLaneEditor).lane_data().get("default_rate", 0))
		panel._mark_tax_pending(key, rate, result, "clear")
	else:
		panel._resolve_tax_editor_key(key)



static func _mark_tax_pending(panel, key: String, rate: int, receipt: Dictionary, op: String,
		mode: int = 0) -> void:
	panel._pending_tax[key] = {
		"effective_day": int(receipt.get("effective_day", -1)),
		"sequence": int(receipt.get("sequence", -1)),
		"policy_version": int(panel._tax_context.get("policy_version", -1)),
		"rate": rate,
		"mode": mode,
		"op": op,
	}
	for editor_value in panel._tax_editors.get(key, []):
		(editor_value as TaxLaneEditor).mark_pending(rate, mode)



static func show_tax_rejection(panel, result: Dictionary) -> void:
	if int(result.get("cell", -1)) != panel._cell_index:
		return
	for key: String in panel._pending_tax.keys():
		if int(panel._pending_tax[key].get("sequence", -1)) != int(result.get("sequence", -2)):
			continue
		panel._pending_tax.erase(key)
		panel._resolve_tax_editor_key(key)
		for editor: TaxLaneEditor in panel._tax_editors.get(key, []):
			editor.show_rejection(String(result.get("message", "")))
		return



static func _resolve_tax_pending(panel, context: Dictionary, category: Dictionary = {}) -> void:
	var current_day := int(context.get("current_day", -1))
	var policy_version := int(context.get("policy_version", -1))
	var resolved: Array[String] = []
	for key_value in panel._pending_tax.keys():
		var key := String(key_value)
		var pending: Dictionary = panel._pending_tax[key]
		if current_day < int(pending.get("effective_day", current_day + 1)) \
				or policy_version <= int(pending.get("policy_version", policy_version)):
			continue
		if not panel.InspectorTaxDrafts._pending_visible_in_snapshot(key, pending, context, category):
			continue
		resolved.append(key)
	for key in resolved:
		panel._pending_tax.erase(key)
		panel._resolve_tax_editor_key(key)



static func _resolve_tax_editor_key(panel, key: String) -> void:
	for editor_value in panel._tax_editors.get(key, []):
		(editor_value as TaxLaneEditor).resolve_pending()



static func _tax_key(panel, kind: String, item_key: String) -> String:
	return "cell:%d/%s/%s" % [panel._cell_index, kind, item_key]



static func _update_reset_tax_button(panel) -> void:
	if not is_instance_valid(panel._reset_tax_button):
		return
	panel._reset_tax_button.visible = bool(panel._tax_context.get("editable", false))
	panel._reset_tax_button.disabled = (panel._tax_context.get("reset_targets", []) as Array).is_empty()



static func _request_category_tax_reset(panel) -> void:
	if not bool(panel._tax_context.get("editable", false)):
		return
	var targets: Array = panel._tax_context.get("reset_targets", [])
	if targets.is_empty():
		return
	panel._tax_reset_request = {"cell": panel._cell_index, "tab": panel._current_tab,
		"targets": targets.duplicate(true)}
	panel._clear_tax_confirmation.title = "重置本栏税收设置"
	panel._clear_tax_confirmation.dialog_text = (
		"将清除本格%s的默认税率和全部单项覆盖，恢复沿用国家政策。"
		% panel._page_tax_title(panel._current_tab).trim_prefix("此地"))
	panel._clear_tax_confirmation.popup_centered(Vector2i(480, 220))



static func _on_category_tax_reset_confirmed(panel) -> void:
	var request: Dictionary = panel._tax_reset_request
	panel._tax_reset_request = {}
	if int(request.get("cell", -1)) != panel._cell_index \
			or String(request.get("tab", "")) != panel._current_tab \
			or not bool(panel._tax_context.get("editable", false)):
		return
	for target in request.get("targets", []):
		panel._on_tax_reset_requested(String(target.scope), String(target.kind), String(target.item_id))
