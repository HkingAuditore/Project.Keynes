extends RefCounted

## 国家财政总面板的「按组折叠税卡」控制器。
##
## 每个分组是一张自带税行的可折叠卡片：
## - 折叠态：直接把整组当成一个对象编辑（支持百分比/定额、混合态提示、一键重置整组）；
## - 展开态：在其下方显示组内各个具体税卡，支持逐项微调；
## - 提交走 country.tax.set_override_group / country.tax.clear_override_group，
##   自动按 256 条分块，保证不超内核单批上限。

const TaxGroupScene := preload("res://scenes/ui/economy_tax_group.tscn")
const TaxLaneScene := preload("res://scenes/ui/economy_tax_lane.tscn")
const TouchUI = preload("res://scripts/ui/touch_ui.gd")
const TouchValueFieldScript := preload("res://scripts/ui/components/touch_value_field.gd")
const TaxGrouping := preload("res://scripts/ui/components/economy_tax_grouping.gd")

const TAX_GROUP_BATCH_LIMIT := 256
const TAX_MODE_PERCENT_BP := 0
const TAX_MODE_ABSOLUTE := 1

var _workspace = null
var _groups_by_key: Dictionary = {}
var _axis_by_page: Dictionary = {}
var _expanded_by_key: Dictionary = {}
var _active_page_groups: Array = []
var _axis_signature := ""
var _syncing_axis := false


func _init(workspace) -> void:
	_workspace = workspace


func bind_toolbar(axis_picker: OptionButton, expand_button: Button) -> void:
	if axis_picker != null:
		axis_picker.item_selected.connect(_on_axis_selected)
	if expand_button != null:
		expand_button.pressed.connect(_on_toggle_expand_all)


func sync_toolbar_visibility(is_tax_page: bool, axis_picker: OptionButton,
		expand_button: Button) -> void:
	if axis_picker != null:
		axis_picker.visible = is_tax_page
	if expand_button != null:
		expand_button.visible = is_tax_page


func current_axis(page: String) -> String:
	var axes := TaxGrouping.axes_for_page(page, not _building_columns().is_empty())
	if axes.is_empty():
		return TaxGrouping.AXIS_FLAT
	var saved := String(_axis_by_page.get(page, ""))
	for axis_value in axes:
		if String((axis_value as Dictionary).get("id", "")) == saved:
			return saved
	var fallback := String((axes[0] as Dictionary).get("id", TaxGrouping.AXIS_FLAT))
	_axis_by_page[page] = fallback
	return fallback


func set_axis_for_test(page: String, axis_id: String) -> void:
	_axis_by_page[page] = axis_id
	_axis_signature = ""
	if _workspace != null:
		_workspace._refresh_page()


func set_group_expanded_for_test(page: String, group_id: String, expanded: bool) -> void:
	var key := "%s::%s" % [page, group_id]
	_expanded_by_key[key] = expanded
	if _workspace != null:
		_workspace._apply_filter()


func group_keys_for_test() -> Array:
	var out: Array = []
	for g in _active_page_groups:
		out.append(String((g as Dictionary).get("key", "")))
	return out


func group_node_for_test(page: String, group_id: String) -> Dictionary:
	return _groups_by_key.get("%s::%s" % [page, group_id], {})


func hide_all_groups(default_host: Control = null, group_list: Control = null,
		flow: Control = null, rows: Dictionary = {}) -> void:
	for entry_value in _groups_by_key.values():
		var entry: Dictionary = entry_value
		var root := entry.control as Control
		if root != null and root.visible:
			root.visible = false
	_active_page_groups.clear()
	if default_host != null:
		for child in default_host.get_children():
			if flow != null:
				_reparent_card(child as Control, flow)
		default_host.visible = false
	if group_list != null:
		group_list.visible = false
		var g_scroll := group_list.get_parent() as Control
		if g_scroll != null:
			g_scroll.visible = false
	if flow != null:
		flow.visible = true
		var f_scroll := flow.get_parent() as Control
		if f_scroll != null:
			f_scroll.visible = true
	if flow != null and not rows.is_empty():
		for card_value in rows.values():
			var card: Dictionary = card_value
			if bool(card.get("is_default", false)):
				_reparent_card(card.control as Control, flow)


func refresh_active_headers(page: String, rows: Dictionary) -> void:
	for entry_value in _active_page_groups:
		var entry: Dictionary = entry_value
		if String(entry.page) == page:
			_refresh_group_header(entry, page, rows)


func refresh_toolbar(page: String, axis_picker: OptionButton, expand_button: Button) -> void:
	var axes := TaxGrouping.axes_for_page(page, not _building_columns().is_empty())
	var active_axis := current_axis(page)
	if axis_picker != null:
		var sig_parts := PackedStringArray()
		for axis_value in axes:
			sig_parts.append(String((axis_value as Dictionary).get("id", "")))
		var sig := "%s|%s" % [page, "|".join(sig_parts)]
		if sig != _axis_signature:
			_axis_signature = sig
			_syncing_axis = true
			axis_picker.clear()
			for idx in range(axes.size()):
				var axis: Dictionary = axes[idx]
				axis_picker.add_item(String(axis.get("label", "")))
				axis_picker.set_item_tooltip(idx, String(axis.get("hint", "")))
				axis_picker.set_item_metadata(idx, String(axis.get("id", "")))
			_syncing_axis = false
		for idx in range(axis_picker.item_count):
			if String(axis_picker.get_item_metadata(idx)) == active_axis:
				if axis_picker.selected != idx:
					_syncing_axis = true
					axis_picker.select(idx)
					_syncing_axis = false
				break
		axis_picker.visible = not axes.is_empty()
	if expand_button != null:
		var is_grouped := active_axis != TaxGrouping.AXIS_FLAT and not _active_page_groups.is_empty()
		expand_button.visible = is_grouped
		if is_grouped:
			expand_button.text = "全部折叠" if _any_group_expanded() else "全部展开"


## 同步本页分组节点：分组模式下默认卡进 default_host、分组卡纵向进 group_list；
## 不分组时归位到 flow。
func sync_groups(page: String, wanted: Dictionary, default_host: Control,
		group_list: VBoxContainer, flow: HFlowContainer,
		rows: Dictionary, axis_picker: OptionButton, expand_button: Button) -> void:
	var card_ids := _wanted_item_ids(page, wanted)
	var axis_id := current_axis(page)
	var groups := TaxGrouping.build_groups(page, axis_id, card_ids, rows, _building_columns())
	_active_page_groups.clear()
	var default_card: Dictionary = rows.get("%s:__default__" % page, {})
	if groups.is_empty():
		hide_all_groups(default_host, group_list, flow, rows)
		for item_id in card_ids:
			var card: Dictionary = rows.get("%s:%s" % [page, String(item_id)], {})
			if not card.is_empty():
				_reparent_card(card.control as Control, flow)
		refresh_toolbar(page, axis_picker, expand_button)
		return
	if default_host != null:
		var d_ctrl: Control = default_card.control as Control if not default_card.is_empty() else null
		# 只把其他页残留的默认卡移回 flow；当前页默认卡若已在 default_host 内，
		# 绝不可先移出再移回，否则每日 tick 刷新会剥夺 SpinBox 焦点、刷掉玩家正在输入的数值。
		for child in default_host.get_children():
			if child != d_ctrl:
				_reparent_card(child as Control, flow)
		if d_ctrl != null:
			if d_ctrl.get_parent() != default_host:
				_reparent_card(d_ctrl, default_host)
			d_ctrl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			if not d_ctrl.visible:
				d_ctrl.visible = true
		var show_default := d_ctrl != null
		if default_host.visible != show_default:
			default_host.visible = show_default
	if group_list != null:
		group_list.visible = true
		var g_scroll := group_list.get_parent() as Control
		if g_scroll != null:
			g_scroll.visible = true
	if flow != null:
		flow.visible = false
		var f_scroll := flow.get_parent() as Control
		if f_scroll != null:
			f_scroll.visible = false
	var active_keys := {}
	for group_value in groups:
		var group: Dictionary = group_value
		var group_id := String(group["id"])
		var key := "%s::%s" % [page, group_id]
		var item_ids: PackedStringArray = group["item_ids"]
		var kinds := _group_kinds(page, item_ids, rows)
		var entry := _ensure_group(key, page, group_id, String(group["label"]), kinds,
			group_list if group_list != null else flow)
		entry["item_ids"] = item_ids
		entry["label"] = String(group["label"])
		(entry.title as Label).text = String(group["label"])
		var members_flow := entry.members as HFlowContainer
		for item_id in item_ids:
			var card: Dictionary = rows.get("%s:%s" % [page, String(item_id)], {})
			if not card.is_empty():
				_reparent_card(card.control as Control, members_flow)
		_refresh_group_header(entry, page, rows)
		active_keys[key] = true
		_active_page_groups.append(entry)
	for existing_key_value in _groups_by_key.keys():
		var existing_key := String(existing_key_value)
		if not active_keys.has(existing_key):
			var stale: Dictionary = _groups_by_key[existing_key]
			(stale.control as Control).visible = false
	refresh_toolbar(page, axis_picker, expand_button)


## 应用搜索/覆盖过滤和按组折叠可见性；同时更新空状态标签。
func apply_filter(page: String, needle: String, raw_search: String, overrides_only: bool,
		rows: Dictionary, expand_button: Button, empty_label: Label) -> void:
	var visible_count := 0
	var project_visible := 0
	if _active_page_groups.is_empty():
		for row_value in rows.values():
			var card: Dictionary = row_value
			if String(card.get("page", "")) != page:
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
			control.visible = matches and (not overrides_only or any_override)
			if control.visible:
				visible_count += 1
				project_visible += 1
	else:
		var default_card: Dictionary = rows.get("%s:__default__" % page, {})
		if not default_card.is_empty():
			(default_card.control as Control).visible = true
			visible_count += 1
		var force_expand := not needle.is_empty() or overrides_only
		for entry_value in _active_page_groups:
			var entry: Dictionary = entry_value
			var key := String(entry.key)
			var item_ids: PackedStringArray = entry.get("item_ids", PackedStringArray())
			var matched_in_group := 0
			var group_matches_name := not needle.is_empty() \
				and String(entry.get("label", "")).to_lower().contains(needle)
			for item_id in item_ids:
				var card: Dictionary = rows.get("%s:%s" % [page, String(item_id)], {})
				if card.is_empty():
					continue
				var control := card.control as Control
				var item_matches := needle.is_empty() or group_matches_name \
					or String(card.item_id).to_lower().contains(needle) \
					or String((card.name as Label).text).to_lower().contains(needle)
				var any_override := false
				for kind in (card.overridden as Dictionary).keys():
					any_override = any_override or bool(card.overridden[kind])
				var show_card := item_matches and (not overrides_only or any_override)
				control.visible = show_card
				if show_card:
					matched_in_group += 1
					project_visible += 1
			var root := entry.control as Control
			root.visible = matched_in_group > 0
			if root.visible:
				visible_count += 1
			_apply_group_expanded_ui(entry, force_expand or bool(_expanded_by_key.get(key, false)))
		if expand_button != null and expand_button.visible:
			expand_button.text = "全部折叠" if _any_group_expanded() else "全部展开"
	if empty_label == null:
		return
	if visible_count == 0 and needle.is_empty():
		empty_label.text = "当前科技未解锁任何项目"
		empty_label.visible = true
	elif project_visible == 0:
		empty_label.text = "没有匹配「%s」的项" % raw_search if not needle.is_empty() else "没有可显示的项"
		empty_label.visible = true
	else:
		empty_label.visible = false


func _ensure_group(key: String, page: String, group_id: String, label: String,
		kinds: Array, host_container: Container) -> Dictionary:
	if _groups_by_key.has(key):
		var existing: Dictionary = _groups_by_key[key]
		if existing.get("kinds", []) == kinds:
			if (existing.control as Control).get_parent() != host_container:
				_reparent_card(existing.control as Control, host_container)
			return existing
		var old_ctrl := existing.control as Control
		for child in (existing.members as HFlowContainer).get_children():
			_reparent_card(child as Control, host_container)
		old_ctrl.queue_free()
		_groups_by_key.erase(key)
	var root := TaxGroupScene.instantiate() as VBoxContainer
	root.name = "TaxGroup_%s_%s" % [page, group_id.replace(":", "_").replace("|", "_")]
	var header := root.get_node("Header") as PanelContainer
	var toggle := root.get_node("Header/Row/Toggle") as Button
	var chevron := root.get_node("Header/Row/Toggle/Content/Chevron") as IconBadge
	var group_icon := root.get_node("Header/Row/Toggle/Content/GroupIcon") as IconBadge
	var title := root.get_node("Header/Row/Toggle/Content/Title") as Label
	var meta := root.get_node("Header/Row/Toggle/Content/Meta") as Label
	var lane_host := root.get_node("Header/Row/Lanes") as Control
	var members_margin := root.get_node("MembersMargin") as MarginContainer
	var members := root.get_node("MembersMargin/Members") as HFlowContainer
	var page_def: Dictionary = _workspace.PAGE_DEFINITIONS.get(page, {})
	group_icon.set_semantic(StringName(page_def.get("icon", &"tax.section")),
		page_def.get("accent", UITokens.DOSSIER_INK))
	title.text = label
	toggle.toggled.connect(_on_group_toggled.bind(key))
	var spins := {}
	var modes := {}
	var resets := {}
	var pendings := {}
	for kind in kinds:
		var kind_row := TaxLaneScene.instantiate() as HBoxContainer
		kind_row.size_flags_horizontal = Control.SIZE_SHRINK_END
		lane_host.add_child(kind_row)
		var kind_label := kind_row.get_node("Kind") as Label
		kind_label.text = String(_workspace.KIND_LABELS.get(kind, kind))
		kind_label.visible = kinds.size() > 1 or page == "consumption"
		var mode_button := kind_row.get_node_or_null("Mode") as OptionButton
		if mode_button != null:
			mode_button.clear()
			mode_button.add_item("%", TAX_MODE_PERCENT_BP)
			mode_button.add_icon_item(MoneyDisplay.MENU_ICON, "定额", TAX_MODE_ABSOLUTE)
			mode_button.select(0)
			mode_button.item_selected.connect(_on_group_mode_selected.bind(key, kind))
			modes[kind] = mode_button
		var spin := kind_row.get_node("Spin") as SpinBox
		spin.size_flags_horizontal = Control.SIZE_SHRINK_END
		spin.custom_minimum_size = Vector2(92.0, 30.0)
		spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
		spin.get_line_edit().text_submitted.connect(
			_on_group_rate_confirmed.bind(key, kind))
		spin.get_line_edit().focus_exited.connect(
			_on_group_rate_focus_exited.bind(key, kind))
		spins[kind] = spin
		if TouchUI.is_touch():
			var field := TouchValueFieldScript.new()
			field.attach(spin, {
				"title": "%s（整组）" % label,
				"mode": func() -> int: return _group_mode(key, kind),
				"hint": func() -> String: return "将整组税率统一设为该值",
				"commit": func(text: String, mode: int) -> void:
					_on_group_rate_confirmed(text, key, kind, mode),
			})
		var reset := kind_row.get_node("Reset") as Button
		IconButton.apply(reset, &"action.reset", IconButton.SMALL, "重置整组为国家默认税率")
		reset.pressed.connect(_on_group_reset_pressed.bind(key, kind))
		resets[kind] = reset
		var pending_badge := kind_row.get_node("Pending") as IconBadge
		pending_badge.set_semantic(&"system.clock", UITokens.BRASS_HIGHLIGHT)
		pendings[kind] = pending_badge
	host_container.add_child(root)
	var entry := {
		"key": key, "page": page, "group_id": group_id, "label": label,
		"control": root, "header": header, "toggle": toggle, "chevron": chevron,
		"title": title, "meta": meta, "members_margin": members_margin, "members": members,
		"spins": spins, "modes": modes, "resets": resets, "pendings": pendings,
		"kinds": kinds, "item_ids": PackedStringArray(),
		"lane_states": {},
	}
	preload("res://scripts/ui/components/touch_tax_card_binder.gd").bind_group(self, key, entry)
	_groups_by_key[key] = entry
	_apply_group_expanded_ui(entry, bool(_expanded_by_key.get(key, false)))
	return entry


func _refresh_group_header(entry: Dictionary, page: String, rows: Dictionary) -> void:
	var item_ids: PackedStringArray = entry.item_ids
	var overridden_items := 0
	var any_mixed := false
	for item_id in item_ids:
		var card: Dictionary = rows.get("%s:%s" % [page, String(item_id)], {})
		if card.is_empty():
			continue
		for v in (card.overridden as Dictionary).values():
			if bool(v):
				overridden_items += 1
				break
	for kind in entry.kinds:
		var state := _summarize_kind(page, kind, item_ids, rows)
		(entry.lane_states as Dictionary)[kind] = state
		any_mixed = any_mixed or bool(state.mixed)
		var spin := (entry.spins as Dictionary)[kind] as SpinBox
		var mode_button := (entry.modes as Dictionary).get(kind) as OptionButton
		var reset := (entry.resets as Dictionary)[kind] as Button
		var pending_badge := (entry.pendings as Dictionary)[kind] as Control
		pending_badge.visible = bool(state.any_pending)
		reset.visible = bool(state.any_override)
		var line := spin.get_line_edit()
		var editing := line != null and (line.has_focus() or spin.has_focus())
		if editing:
			continue
		var display_mode := int(state.mode)
		if mode_button != null:
			var select_idx := mode_button.get_item_index(display_mode)
			if select_idx >= 0 and mode_button.selected != select_idx:
				mode_button.select(select_idx)
		if bool(state.mixed):
			_workspace._configure_spin_for_mode(spin, display_mode)
			spin.set_value_no_signal(0.0)
			if line != null:
				line.text = ""
				line.placeholder_text = "混合"
				line.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
			spin.tooltip_text = "组内税率不一致（%s），输入数值并确认即可一键统一整组" % String(state.range_text)
		else:
			if line != null:
				line.placeholder_text = ""
			_workspace._set_spin_basis_points(spin, int(state.rate), display_mode)
			if line != null:
				line.add_theme_color_override("font_color",
					UITokens.BRASS_HIGHLIGHT if bool(state.any_override) else UITokens.ARCHIVE_INK_MUTED)
	var meta_text := "%d 项" % item_ids.size()
	if overridden_items > 0:
		meta_text += " · 已覆盖 %d" % overridden_items
	if any_mixed:
		meta_text += " · 组内税率混合"
	(entry.meta as Label).text = meta_text
	var header := entry.header as PanelContainer
	header.theme_type_variation = &"PKPaperCard" if overridden_items > 0 else &"PKArchiveBand"
	(entry.title as Label).add_theme_color_override("font_color",
		UITokens.ARCHIVE_BRASS.lerp(UITokens.ARCHIVE_INK, 0.35) \
			if overridden_items > 0 else UITokens.DOSSIER_INK)


func _summarize_kind(page: String, kind: String, item_ids: PackedStringArray,
		rows: Dictionary) -> Dictionary:
	var first := true
	var common_rate := 0
	var common_mode := TAX_MODE_PERCENT_BP
	var mixed := false
	var any_override := false
	var any_pending := false
	var min_rate := 0
	var max_rate := 0
	var mode_mixed := false
	var count := 0
	for item_id in item_ids:
		var card: Dictionary = rows.get("%s:%s" % [page, String(item_id)], {})
		if card.is_empty() or not (card.kinds as Array).has(kind):
			continue
		count += 1
		var rate := int((card.rates as Dictionary).get(kind, 0))
		var mode := int((card.assessment_modes as Dictionary).get(kind, TAX_MODE_PERCENT_BP))
		var overridden := bool((card.overridden as Dictionary).get(kind, false))
		var pending: bool = _workspace._pending.has("%s:%s" % [kind, String(item_id)])
		any_override = any_override or overridden
		any_pending = any_pending or pending
		if first:
			first = false
			common_rate = rate
			common_mode = mode
			min_rate = rate
			max_rate = rate
		else:
			if mode != common_mode:
				mixed = true
				mode_mixed = true
			if rate != common_rate:
				mixed = true
			min_rate = mini(min_rate, rate)
			max_rate = maxi(max_rate, rate)
	var range_text := "多种口径" if mode_mixed else "%s ~ %s" % [
		TaxLaneEditor._format_value(min_rate, common_mode),
		TaxLaneEditor._format_value(max_rate, common_mode)]
	return {
		"count": count, "rate": common_rate, "mode": common_mode,
		"mixed": mixed, "any_override": any_override, "any_pending": any_pending,
		"range_text": range_text,
	}


func _on_group_toggled(expanded: bool, key: String) -> void:
	_expanded_by_key[key] = expanded
	var entry: Dictionary = _groups_by_key.get(key, {})
	if not entry.is_empty():
		_apply_group_expanded_ui(entry, expanded)
	if _workspace != null and _workspace.get("_expand_all_button") != null:
		var btn := _workspace.get("_expand_all_button") as Button
		if btn != null and btn.visible:
			btn.text = "全部折叠" if _any_group_expanded() else "全部展开"


func _apply_group_expanded_ui(entry: Dictionary, expanded: bool) -> void:
	var toggle := entry.toggle as Button
	if toggle != null:
		toggle.set_pressed_no_signal(expanded)
	var chevron := entry.chevron as IconBadge
	if chevron != null:
		chevron.set_semantic(&"action.chevron_down" if expanded else &"action.chevron_right",
			UITokens.ARCHIVE_INK_MUTED)
	var margin := entry.members_margin as Control
	if margin != null and margin.visible != expanded:
		margin.visible = expanded


func _on_axis_selected(index: int) -> void:
	if _syncing_axis or _workspace == null:
		return
	var picker := _workspace.get("_group_axis_picker") as OptionButton
	if picker == null or index < 0 or index >= picker.item_count:
		return
	var axis_id := String(picker.get_item_metadata(index))
	_axis_by_page[String(_workspace._page)] = axis_id
	_workspace._refresh_page()


func _on_toggle_expand_all() -> void:
	var target := not _any_group_expanded()
	for entry_value in _active_page_groups:
		var entry: Dictionary = entry_value
		_expanded_by_key[String(entry.key)] = target
		_apply_group_expanded_ui(entry, target)
	if _workspace != null and _workspace.get("_expand_all_button") != null:
		(_workspace.get("_expand_all_button") as Button).text = "全部折叠" if target else "全部展开"


func _any_group_expanded() -> bool:
	for entry_value in _active_page_groups:
		var entry: Dictionary = entry_value
		if bool(_expanded_by_key.get(String(entry.key), false)):
			return true
	return false


func _group_mode(key: String, kind: String) -> int:
	var entry: Dictionary = _groups_by_key.get(key, {})
	if entry.is_empty():
		return TAX_MODE_PERCENT_BP
	var btn := (entry.modes as Dictionary).get(kind) as OptionButton
	if btn != null and btn.selected >= 0:
		return int(btn.get_item_id(btn.selected))
	return TAX_MODE_PERCENT_BP


func _on_group_mode_selected(index: int, key: String, kind: String) -> void:
	var entry: Dictionary = _groups_by_key.get(key, {})
	if entry.is_empty():
		return
	var btn := (entry.modes as Dictionary).get(kind) as OptionButton
	var mode := int(btn.get_item_id(index)) if btn != null else TAX_MODE_PERCENT_BP
	var spin := (entry.spins as Dictionary)[kind] as SpinBox
	_workspace._configure_spin_for_mode(spin, mode)
	_workspace._set_spin_basis_points(spin, 0, mode)
	submit_group_rate(key, kind, 0, mode)


func _on_group_rate_confirmed(text: String, key: String, kind: String,
		mode_override: int = -1) -> void:
	var entry: Dictionary = _groups_by_key.get(key, {})
	if entry.is_empty():
		return
	var spin := (entry.spins as Dictionary)[kind] as SpinBox
	var mode := _group_mode(key, kind)
	if mode_override >= 0 and mode_override != mode:
		mode = mode_override
		var btn := (entry.modes as Dictionary).get(kind) as OptionButton
		if btn != null:
			var idx := btn.get_item_index(mode)
			if idx >= 0:
				btn.select(idx)
		_workspace._configure_spin_for_mode(spin, mode)
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return
	var state: Dictionary = (entry.lane_states as Dictionary).get(kind, {})
	var fallback := int(state.get("rate", 0))
	var parsed := TaxLaneEditor.parse_value_text(trimmed, fallback, mode) \
		if mode == TAX_MODE_ABSOLUTE else TaxLaneEditor.parse_rate_text(trimmed, fallback)
	_workspace._set_spin_basis_points(spin, parsed, mode)
	submit_group_rate(key, kind, parsed, mode)


func _on_group_rate_focus_exited(key: String, kind: String) -> void:
	var entry: Dictionary = _groups_by_key.get(key, {})
	if entry.is_empty():
		return
	var spin := (entry.spins as Dictionary)[kind] as SpinBox
	var text := spin.get_line_edit().text.strip_edges()
	if text.is_empty():
		# 混合态下未输入任何内容，直接保持混合态不提交。
		return
	var state: Dictionary = (entry.lane_states as Dictionary).get(kind, {})
	var mode := _group_mode(key, kind)
	var parsed := TaxLaneEditor.parse_value_text(text, int(state.get("rate", 0)), mode) \
		if mode == TAX_MODE_ABSOLUTE else TaxLaneEditor.parse_rate_text(text, int(state.get("rate", 0)))
	if not bool(state.get("mixed", false)) and parsed == int(state.get("rate", 0)) \
			and mode == int(state.get("mode", TAX_MODE_PERCENT_BP)):
		return
	submit_group_rate(key, kind, parsed, mode)


func _on_group_reset_pressed(key: String, kind: String) -> void:
	submit_group_clear(key, kind)


## 公开供测试与回调使用：把组内支持 `kind` 的全部项按 256 分块提交为同一税率与口径。
func submit_group_rate(key: String, kind: String, rate_bp: int,
		mode: int = TAX_MODE_PERCENT_BP) -> Dictionary:
	var entry: Dictionary = _groups_by_key.get(key, {})
	if entry.is_empty() or _workspace == null:
		return {"ok": false, "reason": "unknown_group"}
	var controller = _workspace._player_controller
	if controller == null or not controller.has_method("request_command"):
		_workspace._set_status("税收命令通道不可用，整组设值未提交。", true)
		return {"ok": false, "reason": "controller_unavailable"}
	var target_ids := _target_ids_for_kind(entry, kind)
	if target_ids.is_empty():
		return {"ok": false, "reason": "empty_group"}
	var chunks_total := 0
	var chunks_failed := 0
	var submitted := 0
	var first_reason := ""
	for chunk in _chunk_ids(target_ids):
		chunks_total += 1
		var result: Dictionary = controller.request_command(
			&"country.tax.set_override_group", {
				"kind": int(_workspace.TAX_KIND[kind]),
				"item_ids": chunk,
				"rate_basis_points": rate_bp,
				"tax_assessment_mode": mode,
			})
		if not bool(result.get("ok", false)):
			chunks_failed += 1
			if first_reason.is_empty():
				first_reason = String(result.get("reason", "被拒"))
			continue
		submitted += chunk.size()
		for item_id in chunk:
			_apply_optimistic_item(kind, String(item_id), rate_bp, mode, true)
	_workspace._refresh_page()
	var formatted := TaxLaneEditor._format_value(rate_bp, mode)
	if chunks_failed == 0:
		_workspace._set_status("「%s」整组已设为 %s · 共 %d 项（分 %d 批）" % [
			String(entry.label), formatted, submitted, chunks_total])
		return {"ok": true, "submitted": submitted, "chunks": chunks_total}
	_workspace._set_status("「%s」整组设值部分失败：%d/%d 批被拒（%s），已提交 %d 项。" % [
		String(entry.label), chunks_failed, chunks_total, first_reason, submitted], true)
	return {"ok": false, "submitted": submitted, "chunks": chunks_total,
		"failed_chunks": chunks_failed, "reason": first_reason}


func submit_group_clear(key: String, kind: String) -> Dictionary:
	var entry: Dictionary = _groups_by_key.get(key, {})
	if entry.is_empty() or _workspace == null:
		return {"ok": false, "reason": "unknown_group"}
	var controller = _workspace._player_controller
	if controller == null or not controller.has_method("request_command"):
		_workspace._set_status("税收命令通道不可用，整组重置未提交。", true)
		return {"ok": false, "reason": "controller_unavailable"}
	var target_ids := _target_ids_for_kind(entry, kind)
	if target_ids.is_empty():
		return {"ok": false, "reason": "empty_group"}
	var chunks_total := 0
	var chunks_failed := 0
	var submitted := 0
	var first_reason := ""
	var default_rate: int = _workspace._default_rate(kind)
	var default_mode: int = _workspace._default_mode(kind)
	for chunk in _chunk_ids(target_ids):
		chunks_total += 1
		var result: Dictionary = controller.request_command(
			&"country.tax.clear_override_group", {
				"kind": int(_workspace.TAX_KIND[kind]),
				"item_ids": chunk,
			})
		if not bool(result.get("ok", false)):
			chunks_failed += 1
			if first_reason.is_empty():
				first_reason = String(result.get("reason", "被拒"))
			continue
		submitted += chunk.size()
		for item_id in chunk:
			_apply_optimistic_item(kind, String(item_id), default_rate, default_mode, false)
	_workspace._refresh_page()
	if chunks_failed == 0:
		_workspace._set_status("「%s」整组已重置为国家默认 · 共 %d 项（分 %d 批）" % [
			String(entry.label), submitted, chunks_total])
		return {"ok": true, "submitted": submitted, "chunks": chunks_total}
	_workspace._set_status("「%s」整组重置部分失败：%d/%d 批被拒（%s），已提交 %d 项。" % [
		String(entry.label), chunks_failed, chunks_total, first_reason, submitted], true)
	return {"ok": false, "submitted": submitted, "chunks": chunks_total,
		"failed_chunks": chunks_failed, "reason": first_reason}


func _apply_optimistic_item(kind: String, item_id: String, rate_bp: int,
		mode: int, has_override: bool) -> void:
	_workspace._mark_pending(kind, item_id, rate_bp, "set" if has_override else "clear", mode)
	_workspace._submitted_tax["%s:%s" % [kind, item_id]] = {
		"rate": rate_bp, "mode": mode, "has_override": has_override}
	var card: Dictionary = _workspace._rows.get(
		"%s:%s" % [_workspace._kind_page(kind), item_id], {})
	if card.is_empty():
		return
	var spin := (card.spins as Dictionary)[kind] as SpinBox
	_workspace._set_spin_basis_points(spin, rate_bp, mode)
	spin.get_line_edit().add_theme_color_override("font_color",
		UITokens.BRASS_HIGHLIGHT if has_override else UITokens.ARCHIVE_INK_MUTED)
	(card.rates as Dictionary)[kind] = rate_bp
	(card.assessment_modes as Dictionary)[kind] = mode
	(card.overridden as Dictionary)[kind] = has_override
	((card.resets as Dictionary)[kind] as Button).visible = has_override
	_workspace._refresh_override_frame(card)


func _target_ids_for_kind(entry: Dictionary, kind: String) -> PackedStringArray:
	var page := String(entry.page)
	var out := PackedStringArray()
	for item_id in (entry.item_ids as PackedStringArray):
		var card: Dictionary = _workspace._rows.get("%s:%s" % [page, String(item_id)], {})
		if card.is_empty() or bool(card.get("is_default", false)):
			continue
		if (card.kinds as Array).has(kind):
			out.append(String(item_id))
	return out


func _group_kinds(page: String, item_ids: PackedStringArray, rows: Dictionary) -> Array:
	var out: Array = []
	for kind in _workspace._page_kinds(page):
		for item_id in item_ids:
			var card: Dictionary = rows.get("%s:%s" % [page, String(item_id)], {})
			if not card.is_empty() and (card.kinds as Array).has(kind):
				out.append(kind)
				break
	return out


func _wanted_item_ids(page: String, wanted: Dictionary) -> Array:
	var prefix := "%s:" % page
	var out: Array = []
	for key_value in wanted.keys():
		var key := String(key_value)
		if not key.begins_with(prefix):
			continue
		var item_id := key.substr(prefix.length())
		if item_id == "__default__":
			continue
		out.append(item_id)
	return out


func _building_columns() -> Dictionary:
	if _workspace == null:
		return {}
	var controller = _workspace._player_controller
	if controller == null or not controller.has_method("get_economy_facade"):
		return {}
	var economy = controller.get_economy_facade()
	if economy == null or not economy.has_method("construction_type_columns"):
		return {}
	return economy.construction_type_columns()


static func _reparent_card(control: Control, target_parent: Node) -> void:
	if control == null or target_parent == null or control.get_parent() == target_parent:
		return
	var current_parent := control.get_parent()
	if current_parent != null:
		current_parent.remove_child(control)
	target_parent.add_child(control)


static func _chunk_ids(ids: PackedStringArray) -> Array:
	var out: Array = []
	var index := 0
	while index < ids.size():
		var end := mini(index + TAX_GROUP_BATCH_LIMIT, ids.size())
		var chunk := PackedStringArray()
		for cursor in range(index, end):
			chunk.append(ids[cursor])
		out.append(chunk)
		index = end
	return out
