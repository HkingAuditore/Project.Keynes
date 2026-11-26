extends RefCounted

## Builds the active ideology board and browsable card collection.




static func _rebuild_board(host) -> void:
	var saved_scroll = host._scroll.scroll_vertical if host._scroll != null else 0
	var known: PackedInt32Array = host._snapshot.get("known_ids", PackedInt32Array())
	var equipped: Array[int] = []
	var spirits: Array[int] = []
	for value in known:
		var location = int((host._states.get(int(value), {}) as Dictionary).get("location", 0))
		if location == 1:
			equipped.append(int(value))
		elif location == 2:
			spirits.append(int(value))
	host._fill_slots(host._ideology_slots, 1, equipped, int(host._presentation.get("slots_capacity", 0)))
	host._fill_slots(host._spirit_slots, 2, spirits, int(host._presentation.get("spirits_capacity", 0)))
	host._update_resonance(null, -1)
	host._rebuild_collection(known)
	if host._scroll != null:
		host._scroll.set_deferred("scroll_vertical", saved_scroll)



static func _board_signature(host, known: PackedInt32Array) -> Array:
	var signature: Array = [known]
	if host._sort_mode == 3:
		signature.append(host._snapshot.get("levels", PackedInt32Array()))
	signature.append_array([host._snapshot.get("locations", PackedInt32Array()),
		int(host._presentation.get("slots_capacity", 0)),
		int(host._presentation.get("spirits_capacity", 0)), host._country_handle,
		host._metadata.size(), host._tab_school, host._sort_mode, host._compact])
	return signature


## One compact row per equipped idea, plus a single collapsed row for whatever
## empty slots remain. Future technology milestones are a caption, not alcoves.

static func _slot_row_data(host, ideology_id: int, kind: int) -> Dictionary:
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var state: Dictionary = host._states.get(ideology_id, {})
	var live: Dictionary = host._live_by_id.get(ideology_id, {})
	var level = maxi(0, int(state.get("level", 0)))
	var location = int(state.get("location", 0))
	var pending = bool(state.get("pending", false))
	var effect_row = host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id)
	var target_cells: PackedInt32Array = effect_row.get("cells", PackedInt32Array())
	var has_target_cells = not target_cells.is_empty()
	var locate_tooltip = "在地图上定位 %d 处生效地块" % target_cells.size() \
		if has_target_cells else "在地图上定位生效地块"
	var view = CountryViewModel.present_ideology_card(meta, level, effect_row)
	var level_progress: Dictionary = host.LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var tooltip = PackedStringArray([host._display_name(meta, ideology_id),
		String(view.get("tooltip", ""))])
	if bool(level_progress.get("maxed", false)):
		tooltip.append("已至最高境界")
	else:
		tooltip.append("理解度 %s / %s" % [
			host._q16(int(level_progress.get("understanding_q16", 0))),
			host._q16(int(level_progress.get("threshold_q16", 0)))])
	tooltip.append(host._support_tooltip(live, 1))
	if location == 1:
		tooltip.append(host._support_tooltip(live, 2))
	var min_spirit_level = int(meta.get("min_spirit_level", 99))
	var can_promote = location == 1 and level >= min_spirit_level \
		and bool(live.get("promote_allowed", true)) and not pending
	var promote_tooltip = "晋升为民族精神"
	if location == 1 and level < min_spirit_level:
		promote_tooltip = "需达到境界 %d 才能晋升" % (min_spirit_level + 1)
	return {
		"ideology_id": ideology_id,
		"display_name": host._display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"level": level,
		"level_count": int(view.get("level_count", 3)),
		"level_label": String(view.get("level_label", "")),
		"level_progress": level_progress,
		"effects": view.get("effect_lines", PackedStringArray()),
		"pending": pending,
		"has_target_cells": has_target_cells,
		"locate_tooltip": locate_tooltip,
		"can_unequip": bool(live.get("unequip_allowed", true)),
		"can_promote": can_promote,
		"unequip_tooltip": "%s\n%s" % ["撤回这条道路", host._support_summary(live, 1)],
		"promote_tooltip": "%s\n%s" % [promote_tooltip, host._support_summary(live, 2)],
		"tooltip": "\n".join(tooltip).strip_edges(),
		"detail_model": host._detail_data(ideology_id),
		"kind": kind,
	}


## The next technology milestone gating another slot of this kind, or "".

static func _next_milestone(host, kind: int) -> String:
	var capacity = int(host._presentation.get(
		"slots_capacity" if kind == 1 else "spirits_capacity", 0))
	var capacity_max = int(host._presentation.get(
		"slots_max" if kind == 1 else "spirits_max", capacity))
	if capacity >= capacity_max:
		return ""
	var captions = host._locked_captions(kind)
	if captions.is_empty():
		return ""
	return "下一格 %s" % String(captions[0])



static func _locked_captions(host, kind: int) -> PackedStringArray:
	var captions = PackedStringArray()
	for unlock_value in host._presentation.get("capacity_unlocks", []) as Array:
		var unlock = unlock_value as Dictionary
		if bool(unlock.get("owned", false)):
			continue
		var delta = int(unlock.get("ideology_delta" if kind == 1 else "spirit_delta", 0))
		for _i in delta:
			captions.append(String(unlock.get("technology_name", "")))
	return captions



static func _rebuild_collection(host, known: PackedInt32Array) -> void:
	for child in host._collection.get_children():
		host._collection.remove_child(child)
		child.queue_free()
	host._collection_entries.clear()
	var ids: Array[int] = []
	for value in known:
		var meta: Dictionary = host._metadata.get(int(value), {})
		if host._tab_school.is_empty() or String(meta.get("school_id", "")) == host._tab_school:
			ids.append(int(value))
	if host._sort_mode != 0:
		ids.sort_custom(host._sort_less)
	for ideology_id in ids:
		host._collection.add_child(host._make_collection_entry(ideology_id))
	host._apply_collection_columns()
	host._update_collection_metrics(ids.size())



static func _on_collection_resized(host) -> void:
	if host._collection == null or host._collection.get_child_count() == 0:
		return
	host._apply_collection_columns()


## Card width follows the viewport; text flow determines height at every size.

static func _apply_collection_columns(host) -> void:
	if host._collection == null or host._scroll == null:
		return
	var available = maxf(1.0, host._scroll.size.x - 16.0)
	var columns = maxi(1, int(floorf((available + 12.0) / 372.0)))
	var width = floorf((available - (columns - 1) * 12.0) / columns)
	for child in host._collection.get_children():
		var entry = child as Control
		entry.custom_minimum_size.x = width
		entry.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		entry.call_deferred("refresh_layout")



static func _collection_max_card_width(host) -> float:
	# At 1080p one card should not grow into a banner: the generated frame reads
	# as an object at roughly 420px, while larger copies make its line weight and
	# parchment grain look thin beside the cabinet.
	return 420.0 if host._compact else 460.0



static func _update_collection_metrics(host, _visible_count: int) -> void:
	# Value refresh and filter changes preserve stable opacity and hit targets.
	pass



static func _sort_less(host, a: int, b: int) -> bool:
	var meta_a: Dictionary = host._metadata.get(a, {})
	var meta_b: Dictionary = host._metadata.get(b, {})
	match host._sort_mode:
		1:
			if int(meta_a.get("rarity", 1)) != int(meta_b.get("rarity", 1)):
				return int(meta_a.get("rarity", 1)) > int(meta_b.get("rarity", 1))
		2:
			var school_a = host.ArtScript.SCHOOL_ORDER.find(String(meta_a.get("school_id", "")))
			var school_b = host.ArtScript.SCHOOL_ORDER.find(String(meta_b.get("school_id", "")))
			if school_a != school_b:
				return school_a < school_b
		3:
			var level_a = int((host._states.get(a, {}) as Dictionary).get("level", 0))
			var level_b = int((host._states.get(b, {}) as Dictionary).get("level", 0))
			if level_a != level_b:
				return level_a > level_b
	return a < b



static func _make_collection_entry(host, ideology_id: int) -> Control:
	var state: Dictionary = host._states.get(ideology_id, {})
	var live: Dictionary = host._live_by_id.get(ideology_id, {})
	var meta: Dictionary = host._metadata.get(ideology_id, {})
	var location = int(state.get("location", 0))
	var pending = bool(state.get("pending", false))
	var effect_row = host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id)
	var target_cells: PackedInt32Array = effect_row.get("cells", PackedInt32Array())
	var has_target_cells = not target_cells.is_empty()
	var view = CountryViewModel.present_ideology_card(meta,
		maxi(0, int(state.get("level", 0))),
		effect_row)
	var level_progress: Dictionary = host.LevelProgressScript.build(meta, state,
		String(view.get("level_label", "")))
	var entry = host.CollectionEntry.new()
	entry.name = "IdeologyCollectionCard"
	host._collection_entries[ideology_id] = entry
	entry.setup({
		"name": host._display_name(meta, ideology_id),
		"school_id": String(meta.get("school_id", "")),
		"rarity": int(meta.get("rarity", 1)),
		"level_label": String(view.get("level_label", "")),
		"level_progress": level_progress,
		"effects": view.get("effect_lines", PackedStringArray()),
		"next_effects": view.get("next_level_lines", PackedStringArray()),
		"detail": String(view.get("detail", "")),
		"tooltip": String(host._card_data(ideology_id, true).get("tooltip", "")),
		"detail_model": host._detail_data(ideology_id),
		"location": location,
		"pending": pending,
		"draggable": location != 2,
		"payload": {"ideology_card": ideology_id, "location": location},
		"activated": Callable(host, "_on_card_activated").bind(ideology_id),
		"detail_requested": Callable(host, "_open_detail_modal").bind(ideology_id, false),
		"locate_requested": Callable(host, "_on_card_locate_requested").bind(ideology_id),
		"compact": host._compact,
	})
	entry.custom_minimum_size = Vector2(0, 180.0 if host._compact else 220.0)
	entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var progress: Control = entry.call("level_meter")
	progress.set_meta("accent_source", int(meta.get("rarity", 1)))
	var actions: HBoxContainer = entry.call("footer")
	actions.alignment = BoxContainer.ALIGNMENT_END
	# The ink line and the action are separate targets: a card-wide row can be
	# dragged while the button remains a normal click target.
	entry.mouse_filter = Control.MOUSE_FILTER_PASS
	actions.mouse_filter = Control.MOUSE_FILTER_STOP
	actions.visible = true
	actions.add_child(host._secondary_action_button("详情",
		host._open_detail_modal.bind(ideology_id, false),
		"查看理念详情、下一境效果与阶层支持", host._compact))
	var locate_btn = host._secondary_action_button("定位",
		host._on_card_locate_requested.bind(ideology_id),
		"在地图上定位 %d 处生效地块" % target_cells.size() if has_target_cells else "在地图上定位生效地块",
		host._compact)
	locate_btn.visible = has_target_cells
	actions.add_child(locate_btn)
	match location:
		0:
			actions.add_child(host._action_button("推行", pending
				or not bool(live.get("equip_allowed", false)),
				host._command.bind("equip", ideology_id), host._support_summary(live, 0),
				host._compact))
		1:
			actions.add_child(host._action_button("撤回", pending
				or not bool(live.get("unequip_allowed", false)),
				host._command.bind("unequip", ideology_id), host._support_summary(live, 1),
				host._compact))
			actions.add_child(host._action_button("晋升", pending
				or int(state.get("level", 0)) < int(meta.get("min_spirit_level", 99))
				or not bool(live.get("promote_allowed", false)),
				host._request_promotion.bind(ideology_id), host._support_summary(live, 2),
				host._compact))
		_:
			actions.add_child(host.ArtScript.label("民族精神", 11, host.ArtScript.VERMILION))
	return entry



static func _action_button(host, text: String, disabled: bool, callback: Callable,
		tooltip: String, _compact_value := false) -> Button:
	var button = Button.new()
	button.text = text
	button.disabled = disabled
	button.custom_minimum_size = Vector2(72 if _compact_value else 80, 36)
	button.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	button.theme_type_variation = &"PKSealPrimaryButton"
	button.focus_mode = Control.FOCUS_ALL
	button.tooltip_text = tooltip
	button.set_meta("ideology_action", text)
	button.pressed.connect(callback)
	return button



static func _secondary_action_button(host, text: String, callback: Callable,
		tooltip: String, compact_value := false) -> Button:
	var button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(56 if compact_value else 66, 36)
	button.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	button.theme_type_variation = &"PKDossierRowButton"
	button.focus_mode = Control.FOCUS_ALL
	button.tooltip_text = tooltip
	button.set_meta("ideology_action", text)
	button.pressed.connect(callback)
	return button


## Right click on a card face: hand the receiver the cells this card resolved to.
##
## The list comes from the same report the badge is built from, so the number on
## the card and the hexes on the map can never disagree. A card with no cell
## targets emits nothing at all rather than an empty list — there is nothing to
## show, and silently clearing the previous card's highlight would look like a
## dropped click.
