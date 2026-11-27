extends RefCounted

## Coordinates the inspector detail workspaces and split layout.


static func set_construction_model(panel, model: Dictionary) -> void:
	panel._construction_model = model
	if panel._construction_workspace != null:
		panel._construction_workspace.set_model(panel._construction_model)



static func set_construction_feedback(panel, message: String, ok: bool) -> void:
	panel._construction_feedback = message
	panel._construction_ok = ok
	if panel._construction_workspace != null:
		panel._construction_workspace.set_feedback(message, ok)



static func building_workspace_open(panel) -> bool:
	return panel._construction_workspace != null and panel._construction_workspace.visible


## 官营建筑命令被拒时解锁军事页的动作键（成功的命令保持禁用，等模型画出「在建」）。
static func release_military_ledger_busy(panel) -> void:
	if panel._military_ledger != null:
		panel._military_ledger.release_busy()


## 官营建筑命令的回执：写在军事台账刚按下那一行上。营造反馈条只在营造窗口
## 打开时可见，地块档案这一页如果也只写那边，被拒的命令就完全没有回音。
static func set_military_ledger_feedback(panel, message: String, ok: bool) -> void:
	if panel._military_ledger != null:
		panel._military_ledger.show_feedback(message, ok)



static func set_military_army_feedback(panel, message: String, ok: bool) -> void:
	if panel._military_ledger != null:
		panel._military_ledger.show_army_feedback(message, ok)


## 次日结算 / 打开窗口后重发同一张目录页的请求（查询身份由窗口自己记住）。
static func request_construction_refresh(panel) -> void:
	if panel._construction_workspace != null and panel._construction_workspace.visible:
		panel._construction_workspace.request_refresh()


## ── 军务档案（部队 / 战线页）──────────────────────────────────────────
## 与对象详情同级：占用 DetailShell，让右栏变宽，并按宽度决定是否保留地块目录列。
static func show_military_dossier(panel, payload: Dictionary) -> void:
	if payload.is_empty() or panel._military_dossier == null:
		return
	panel._set_family_chrome(false)
	panel._object_detail_dialog.visible = false
	panel._family_workspace.hide_immediately()
	panel._construction_workspace.visible = false
	panel._military_dossier.visible = true
	panel._military_dossier.set_model(payload)
	panel._show_detail_shell()



static func refresh_military_dossier(panel, payload: Dictionary) -> void:
	if payload.is_empty() or panel._military_dossier == null or not panel._military_dossier.visible:
		return
	panel._military_dossier.set_model(payload)



static func military_dossier_open(panel) -> bool:
	return panel._military_dossier != null and panel._military_dossier.visible



static func military_dossier_identity(panel) -> String:
	return panel._military_dossier.identity() if panel._military_dossier != null else ""



static func update_military_arm_order(panel, state: Dictionary) -> void:
	if panel._military_dossier != null:
		panel._military_dossier.set_order_state(state)



static func set_military_dossier_feedback(panel, message: String, ok: bool) -> void:
	if panel._military_dossier != null:
		panel._military_dossier.show_feedback(message, ok)


## 没有地块档案可看时收起目录列：军务档案独占面板。
static func set_directory_available(panel, available: bool) -> void:
	if available == panel._directory_available:
		return
	panel._directory_available = available
	panel._sync_split_layout()



static func show_object_detail(panel, payload: Dictionary) -> void:
	if payload.is_empty() or panel._object_detail_dialog == null:
		return
	panel._set_family_chrome(false)
	if panel._military_dossier != null:
		panel._military_dossier.visible = false
	panel._construction_workspace.visible = false
	panel._family_workspace.hide_immediately()
	panel._deferred_object_detail_payload.clear()
	panel._object_detail_dialog.visible = true
	panel._object_detail_dialog.show_details(payload)
	panel._rebuild_tax_editor_registry()
	panel._show_detail_shell()



static func show_family_workspace(panel, payload: Dictionary, animate: bool = true) -> void:
	if payload.is_empty() or panel._family_workspace == null:
		return
	var was_open: bool = panel.family_workspace_open()
	panel._set_family_chrome(true)
	panel._deferred_object_detail_payload.clear()
	panel._object_detail_dialog.visible = false
	if panel._military_dossier != null:
		panel._military_dossier.visible = false
	panel._construction_workspace.visible = false
	panel._family_workspace.show_family(payload, animate)
	if not was_open:
		panel._show_detail_shell()



static func refresh_family_workspace(panel, payload: Dictionary) -> void:
	if payload.is_empty() or panel._family_workspace == null \
			or not panel._family_workspace.visible:
		return
	panel._family_workspace.set_model(payload)



static func family_workspace_open(panel) -> bool:
	return panel._family_workspace != null and panel._family_workspace.visible



static func refresh_object_detail(panel, payload: Dictionary) -> void:
	if payload.is_empty() or panel._object_detail_dialog == null \
			or not panel._object_detail_dialog.visible:
		return
	if not panel._object_detail_dialog.refresh_details(payload):
		panel._deferred_object_detail_payload = payload.duplicate(true)
		return
	panel._deferred_object_detail_payload.clear()
	panel._rebuild_tax_editor_registry()



static func _on_object_tax_editing_finished(panel) -> void:
	if panel._deferred_object_detail_payload.is_empty():
		return
	panel.call_deferred("_apply_deferred_object_detail_refresh")



static func _apply_deferred_object_detail_refresh(panel) -> void:
	if panel._deferred_object_detail_payload.is_empty() \
			or panel._object_detail_dialog == null or not panel._object_detail_dialog.visible:
		return
	var payload: Dictionary = panel._deferred_object_detail_payload
	if not panel._object_detail_dialog.refresh_details(payload):
		return
	panel._deferred_object_detail_payload.clear()
	panel._rebuild_tax_editor_registry()



static func _request_object_detail(panel, request: Dictionary) -> void:
	var row_id := String(request.get("row_id", ""))
	for list in [panel._cohort_list, panel._market_list, panel._building_list, panel._resource_list, panel._family_list]:
		if list != null and list.has_method("set_selected"):
			list.set_selected(row_id)
	panel.object_details_requested.emit(request)



static func close_detail(panel, notify: bool = true) -> void:
	panel._deferred_object_detail_payload.clear()
	panel._detail_change_notify = notify
	if panel._family_workspace != null and panel._family_workspace.visible:
		if notify:
			panel._family_workspace.request_close()
		else:
			panel._family_workspace.hide_immediately()
			panel._on_detail_closed()
	elif panel._object_detail_dialog != null and panel._object_detail_dialog.visible:
		panel._object_detail_dialog.close_dialog()
	else:
		panel._on_detail_closed()



static func detail_open(panel) -> bool:
	return panel._detail_shell != null and panel._detail_shell.visible



static func set_compact_detail_mode(panel, compact: bool) -> void:
	panel._compact_detail = compact
	panel._sync_split_layout()


static func set_list_wing_enabled(panel, enabled: bool) -> void:
	if panel._list_wing_enabled == enabled:
		panel._sync_split_layout()
		return
	panel._list_wing_enabled = enabled
	if panel._has_list_wing and not panel._model.is_empty():
		panel._render_content(false)
	else:
		panel._sync_split_layout()


## 建筑页签里的「营造新建筑」纸笺。页签每日重建时只刷新这句话，报价留给
## 真正打开营造窗口的那一次请求。
static func _build_construction_entry(panel, host: Control, entry_data: Dictionary) -> void:
	if entry_data.has("visible") and not bool(entry_data.get("visible", true)):
		return
	var entry := panel.ConstructionEntryScene.instantiate() as PanelContainer
	(entry.get_node("Row/Icon") as IconBadge).set_semantic(
		&"economy.building", UITokens.DOSSIER_BRASS)
	var title := entry.get_node("Row/Text/Title") as Label
	title.text = String(entry_data.get("title", "营造新建筑"))
	var hint := entry.get_node_or_null("Row/Text/Hint") as Label
	if hint != null:
		var hint_text := String(entry_data.get("hint", ""))
		hint.text = hint_text
		hint.visible = not hint_text.is_empty()
		panel._construction_entry_hint = hint
	var open_button := entry.get_node("Row/OpenButton") as Button
	var available := bool(entry_data.get("available", false))
	open_button.disabled = not available
	open_button.tooltip_text = "" if available \
		else String(entry_data.get("message", "只能在玩家领土内营造。"))
	open_button.pressed.connect(panel._open_building_workspace)
	host.add_child(entry)



static func _open_building_workspace(panel) -> void:
	panel._set_family_chrome(false)
	panel._object_detail_dialog.visible = false
	panel._family_workspace.hide_immediately()
	if panel._military_dossier != null:
		panel._military_dossier.visible = false
	if int(panel._construction_model.get("cell", -1)) != panel._cell_index:
		panel._construction_model = {}
	panel._construction_workspace.visible = true
	panel._construction_workspace.set_model(panel._construction_model)
	panel._rebuild_tax_editor_registry()
	panel._show_detail_shell()
	# 打开时就按上一次的查询身份取数（首次打开由 VM 选默认部门）。
	var query: Dictionary = panel._construction_model.get("query", {})
	panel.construction_page_requested.emit(String(query.get("sector", "")),
		String(query.get("search", "")), String(query.get("sort", "recommended")),
		int(query.get("offset", 0)))



static func _show_detail_shell(panel) -> void:
	panel._detail_shell.visible = true
	panel._sync_split_layout()
	panel._list_wing_notified = has_list_wing(panel)
	panel.detail_visibility_changed.emit(true)



static func _on_detail_closed(panel) -> void:
	if panel._detail_shell == null:
		return
	var was_open: bool = panel._detail_shell.visible
	var restore_family_focus: bool = panel._family_chrome_active and panel._detail_change_notify
	panel._object_detail_dialog.visible = false
	panel._family_workspace.hide_immediately()
	if panel._military_dossier != null:
		panel._military_dossier.visible = false
	panel._construction_workspace.visible = false
	panel._detail_shell.visible = false
	panel._set_family_chrome(false)
	panel._sync_split_layout()
	panel._list_wing_notified = has_list_wing(panel)
	panel._inspector_root.visible = true
	if restore_family_focus and panel._family_list != null:
		panel._family_list.focus_selected()
	for list in [panel._cohort_list, panel._market_list, panel._building_list, panel._resource_list, panel._family_list]:
		if list != null and list.has_method("set_selected"):
			list.set_selected("")
	if was_open:
		panel.detail_visibility_changed.emit(false)
	panel._detail_change_notify = true
	panel._rebuild_tax_editor_registry()



static func _set_family_chrome(panel, active: bool) -> void:
	if panel._family_chrome_active == active:
		return
	panel._family_chrome_active = active
	if active:
		# 只撤掉左侧详情的重复外框；右侧地块档案保留原有材质和边距。
		if panel._detail_shell != null:
			panel._detail_shell.add_theme_stylebox_override(&"panel", panel._empty_panel_style)
	else:
		if panel._detail_shell != null:
			panel._detail_shell.remove_theme_stylebox_override(&"panel")



static func _sync_split_layout(panel) -> void:
	if panel._inspector_root == null or panel._detail_shell == null:
		return
	var split := panel._inspector_root.get_parent() as Control
	if split != null:
		split.clip_contents = not panel._family_chrome_active
	var inspecting: bool = panel._detail_shell.visible
	panel._detail_shell.clip_contents = not panel._family_chrome_active
	var wing_visible: bool = panel._list_shell != null and panel._has_list_wing \
		and panel._list_wing_enabled and not inspecting \
		and panel._directory_available
	if panel._list_shell != null:
		panel._list_shell.visible = wing_visible
		panel._list_shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel._list_shell.size_flags_stretch_ratio = 1.0
	var has_left: bool = inspecting or wing_visible
	# 家族栏始终保留右侧目录；普通对象详情仍沿用窄窗独占策略。
	var family_open: bool = panel._family_workspace != null and panel._family_workspace.visible
	var can_split: bool = family_open or (not panel._compact_detail \
		and (panel.size.x >= panel.SPLIT_DETAIL_MIN_WIDTH or wing_visible))
	var show_dossier: bool = (not inspecting or can_split) and panel._directory_available
	panel._inspector_root.visible = show_dossier
	panel._inspector_root.size_flags_horizontal = Control.SIZE_FILL if has_left \
		else Control.SIZE_EXPAND_FILL
	panel._inspector_root.size_flags_stretch_ratio = 0.0 if has_left else 1.0
	panel._detail_shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel._detail_shell.size_flags_stretch_ratio = 1.0


static func has_list_wing(panel) -> bool:
	return panel._has_list_wing and not panel.detail_open() and panel._directory_available


static func list_wing_open(panel) -> bool:
	return panel._list_shell != null and panel._list_shell.visible


static func _notify_list_wing_changed(panel) -> void:
	var active := has_list_wing(panel)
	if active == panel._list_wing_notified:
		return
	panel._list_wing_notified = active
	panel.list_wing_visibility_changed.emit(active)
