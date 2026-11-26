extends RefCounted

const CardData = preload("res://scripts/ui/components/ideology_workspace_card_data.gd")

const Collection = preload("res://scripts/ui/components/ideology_workspace_collection.gd")

const ArchiveLayout = preload("res://scripts/ui/components/ideology_workspace_layout.gd")

const IdeologySupport = preload("res://scripts/ui/components/ideology_workspace_support.gd")

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _build_promotion_overlay(host) -> void:
	ArchiveLayout._build_promotion_overlay(host)


func _wire_promotion_focus(host) -> void:
	ArchiveLayout._wire_promotion_focus(host)


func _close_promotion_overlay(host) -> void:
	ArchiveLayout._close_promotion_overlay(host)


func _open_detail_modal(host, ideology_id: int, is_offer: bool = false) -> void:
	ArchiveLayout._open_detail_modal(host, ideology_id, is_offer)


func _open_resonance_detail(host, school_id: String) -> void:
	ArchiveLayout._open_resonance_detail(host, school_id)


func _present_detail_dictionary(host, data: Dictionary) -> void:
	ArchiveLayout._present_detail_dictionary(host, data)


func _close_detail_modal(host) -> void:
	ArchiveLayout._close_detail_modal(host)


func is_detail_modal_open(host) -> bool:
	return ArchiveLayout.is_detail_modal_open(host)


func _focus_initial_action(host) -> void:
	ArchiveLayout._focus_initial_action(host)


func _build_dynamic_parts(host) -> void:
	ArchiveLayout._build_dynamic_parts(host)


func _build_archive_chrome(host) -> void:
	ArchiveLayout._build_archive_chrome(host)


func _build_deck_heading(host) -> void:
	ArchiveLayout._build_deck_heading(host)


func _build_slot_sections(host, deck_column: VBoxContainer) -> void:
	ArchiveLayout._build_slot_sections(host, deck_column)


func _make_slot_section_header(host, kind: int) -> PanelContainer:
	return ArchiveLayout._make_slot_section_header(host, kind)


static func _spirit_alcove_rule_style(host) -> StyleBoxFlat:
	return ArchiveLayout._spirit_alcove_rule_style(host)


func _build_collection_heading(host) -> void:
	ArchiveLayout._build_collection_heading(host)


func _style_school_tabs(host) -> void:
	ArchiveLayout._style_school_tabs(host)


func _tab_style(host, state: String) -> StyleBox:
	return ArchiveLayout._tab_style(host, state)


func _apply_archive_metrics(host) -> void:
	ArchiveLayout._apply_archive_metrics(host)


func _play_workspace_intro(host) -> void:
	ArchiveLayout._play_workspace_intro(host)


func _build_stage_scenery(host) -> void:
	ArchiveLayout._build_stage_scenery(host)


func _build_stage_header(host) -> void:
	ArchiveLayout._build_stage_header(host)


func _build_stage_footer(host) -> void:
	ArchiveLayout._build_stage_footer(host)


func set_model(host, model: Dictionary) -> void:
	host._bind_nodes()
	host._apply_model(model)



func refresh_model(host, model: Dictionary) -> void:
	host._bind_nodes()
	host._apply_model(model)



func set_compact(host, compact: bool) -> void:
	host._bind_nodes()
	# 触摸档（手机横屏逻辑 1942×873）走紧凑版：让渡一列给卡面，页签才有 44dp 的位置。
	compact = compact or host.TouchUI.is_short_viewport()
	var changed = compact != host._compact
	host._compact = compact
	# Card glyph sizes are cheap to reapply, so they never wait for a signature
	# change; only the container rebuild below is gated.
	if not changed and not host._signature.is_empty():
		return
	host._apply_stage_metrics()
	host._empty.custom_minimum_size = Vector2(0, 150 if compact else 170)
	host._apply_archive_metrics()
	host._style_school_tabs()
	if host._compact and Time.get_ticks_msec() >= host._hint_hold_until:
		host._hint.visible = false
	for view in host._resonance_views.values():
		(view).set_compact(compact)
	host._signature = []
	if not host._snapshot.is_empty() and not host._presentation.is_empty():
		host._rebuild_board()
		host._signature = host._board_signature(
			host._snapshot.get("known_ids", PackedInt32Array()))



static func _safe_insets(host) -> Dictionary:
	var insets = {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var tree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return insets
	var settings = tree.root.get_node_or_null("/root/GameSettings")
	if settings != null and settings.has_method("ui_scaling"):
		var scaling = settings.call("ui_scaling")
		if scaling != null and scaling.has_method("safe_insets"):
			insets = scaling.call("safe_insets")
	return insets



func _apply_offer_layer_insets(host) -> void:
	var insets = host._safe_insets()
	var safe_left = float(insets.get("left", 0.0))
	var safe_top = float(insets.get("top", 0.0))
	var safe_right = float(insets.get("right", 0.0))
	var safe_bottom = float(insets.get("bottom", 0.0))
	var v_margin = 24.0 if host._compact else 48.0
	if host._offer_layer != null:
		host._offer_layer.offset_left = 24.0 + safe_left
		host._offer_layer.offset_top = v_margin + safe_top
		host._offer_layer.offset_right = -24.0 - safe_right
		host._offer_layer.offset_bottom = -v_margin - safe_bottom
	if host._detail_layer != null:
		host._detail_layer.offset_left = safe_left
		host._detail_layer.offset_top = safe_top
		host._detail_layer.offset_right = -safe_right
		host._detail_layer.offset_bottom = -safe_bottom



func _stage_card_size(host) -> Vector2:
	# The tray is modal over the workspace, not the whole game viewport. Measuring
	# the workspace height here was what pushed the action row below 720p.
	var view_height = host._offer_layer.size.y if host._offer_layer != null \
		and host._offer_layer.size.y > 0.0 else host.size.y if host.size.y > 0.0 else 576.0
	var view_width = host._offer_layer.size.x if host._offer_layer != null \
		and host._offer_layer.size.x > 0.0 else 1024.0
	var base_chrome = host.STAGE_CHROME_HEIGHT_COMPACT if host._compact else host.STAGE_CHROME_HEIGHT
	var action_min_y = maxf(32.0, host.TouchUI.min_units())
	if host._offer_actions != null:
		action_min_y = maxf(action_min_y, host._offer_actions.get_combined_minimum_size().y)
	var extra_actions_height = maxf(0.0, action_min_y - 32.0)
	var chrome_height = base_chrome + extra_actions_height
	host._stage_available_height = maxf(0.0,
		view_height - host.STAGE_OUTER_INSET * 2.0 - chrome_height)
	var height = clampf(host._stage_available_height, host.STAGE_CARD_MIN_HEIGHT,
		host.STAGE_CARD_MAX_HEIGHT)
	if view_width > 0.0:
		var gutter = 62.0 if host._compact else 136.0
		height = minf(height, ((view_width - gutter) / 3.0) / host.CardScript.CARD_ASPECT)
	height = maxf(height, 118.0)
	return Vector2(roundf(height * host.CardScript.CARD_ASPECT), roundf(height))



func _apply_stage_metrics(host) -> void:
	host._apply_offer_layer_insets()
	var cards: HBoxContainer = null
	if host._choice_0 != null:
		cards = host._choice_0.get_parent() as HBoxContainer
	var separation = 18 if host._compact else 28
	var card_size = host._stage_card_size()
	host._stage_card_applied = card_size
	if host._offer != null:
		var chrome_width = 54.0 if host._compact else 92.0
		var desired_width = card_size.x * 3.0 + separation * 2.0 + chrome_width
		host._offer.custom_minimum_size = Vector2(
			minf(host._offer_layer.size.x - host.STAGE_OUTER_INSET * 2.0, desired_width), 0)
	if cards != null:
		# 720p keeps the three offer cards and their actions inside one viewport.
		cards.add_theme_constant_override("separation", separation)
		var column = cards.get_parent() as VBoxContainer
		if column != null:
			column.add_theme_constant_override("separation", 4 if host._compact else 7)
		# Reserve the three-card row even while the deck shuffles, so the tray does
		# not jump in size when the offer lands.
		cards.custom_minimum_size.x = card_size.x * 3.0 + separation * 2.0
		cards.custom_minimum_size.y = card_size.y
	if host._offer_title != null:
		host._offer_title.add_theme_font_size_override("font_size", 22 if host._compact else 28)
		if host._compact:
			host._offer_title.theme_type_variation = host.COMPACT_TITLE_STYLE
			host._offer_title.custom_minimum_size = Vector2.ZERO
		else:
			host._offer_title.theme_type_variation = &"Label"
			host._offer_title.custom_minimum_size = Vector2(0, 34)
	if host._offer_header != null:
		host._offer_header.add_theme_constant_override("separation", 0)
	if host._offer_hint != null:
		host._offer_hint.add_theme_font_size_override("font_size", 14)
		host._offer_hint.visible = true
	var button_min_y = maxf(30.0 if host._compact else 32.0, host.TouchUI.min_units())
	if host._offer_actions != null:
		host._offer_actions.add_theme_constant_override("separation", 8 if host._compact else 12)
		for button in host._offer_actions.get_children():
			if button is Button:
				(button as Button).custom_minimum_size.y = maxf(
					(button as Button).custom_minimum_size.y, button_min_y)
		button_min_y = maxf(button_min_y, host._offer_actions.get_combined_minimum_size().y)
	if host._offer_footer != null:
		host._offer_footer.add_theme_constant_override("separation", 0 if host._compact else 2)
		host._offer_footer.custom_minimum_size.y = maxf(48.0 if host._compact else 52.0, button_min_y + 20.0)
	if host._offer_body != null:
		var inset = 10 if host._compact else 16
		host._offer_body.add_theme_constant_override("margin_left", inset)
		host._offer_body.add_theme_constant_override("margin_right", inset)
		host._offer_body.add_theme_constant_override("margin_top", 6 if host._compact else 10)
		host._offer_body.add_theme_constant_override("margin_bottom", 6 if host._compact else 10)
	for index in 3:
		var card = host._choice(index)
		if card == null:
			continue
		# Stage text follows the actual offer size, not the collection compact
		# style. Otherwise a 145px 720p card still uses 16px frame padding.
		card.call("set_compact", false)
		card.set("stage_rest_offset", Vector2.ZERO)
		card.set("stage_rest_rotation", 0.0)
		card.call("reset_motion")
		card.call("set_stage_size", card_size)
	if host._draw_stack != null:
		host._draw_stack.set_card_size(card_size)



func _on_workspace_resized(host) -> void:
	if host._choice_0 == null:
		return
	host._apply_offer_layer_insets()
	if host._compact:
		host._apply_archive_metrics()
	var target = host._stage_card_size()
	if absf(target.y - host._stage_card_applied.y) < 4.0 \
			and absf(target.x - host._stage_card_applied.x) < 4.0:
		return
	host._apply_stage_metrics()



func set_player_controller(host, controller) -> void:
	var bindings = {
		"command_settled": "_on_player_command_settled",
		"ideology_offer_ready": "_on_ideology_offer_ready",
		"command_completed": "_on_player_command_completed",
	}
	if host._player_controller != null:
		for signal_name in bindings:
			var old_callback = Callable(host, String(bindings[signal_name]))
			if host._player_controller.has_signal(signal_name) \
					and host._player_controller.is_connected(signal_name, old_callback):
				host._player_controller.disconnect(signal_name, old_callback)
	host._player_controller = controller
	if host._player_controller == null:
		return
	for signal_name in bindings:
		var callback = Callable(host, String(bindings[signal_name]))
		if host._player_controller.has_signal(signal_name) \
				and not host._player_controller.is_connected(signal_name, callback):
			host._player_controller.connect(signal_name, callback)


# --- model ----------------------------------------------------------------


func _apply_model(host, model: Dictionary) -> void:
	var ideology: Dictionary = model.get("ideology", {})
	host._facade = ideology.get("facade")
	host._country_handle = int(model.get("country_handle", 0))
	host._current_day = int(model.get("current_day", 0))
	if ideology.is_empty() or not bool(ideology.get("available", false)):
		var raw_reason = String(ideology.get("reason", model.get("reason", "")))
		var loading = ideology.is_empty() and not bool(model.get("available", false)) \
			and (raw_reason.is_empty() or raw_reason == "正在载入已提交数据")
		host._show_shell(CountryViewModel.ideology_player_reason(raw_reason), loading)
		return
	host._catalog = ideology.get("catalog", {})
	host._snapshot = ideology.get("snapshot", {})
	host._presentation = ideology.get("presentation", {})
	if host._presentation.is_empty():
		host._presentation = CountryViewModel.present_ideology(host._snapshot, host._catalog)
	host._index_catalog()
	var state_changes = host._index_states()
	host._render_top()
	var known: PackedInt32Array = host._snapshot.get("known_ids", PackedInt32Array())
	var explain_signature: Array = [
		host._country_handle, int(host._snapshot.get("support_revision", 0)), known,
		host._snapshot.get("levels", PackedInt32Array()),
		host._snapshot.get("locations", PackedInt32Array())]
	var support_changed = explain_signature != host._explain_signature
	if support_changed:
		host._explain_signature = explain_signature
		host._refresh_live_explain(known)
	var effect_changed_ids = PackedInt32Array()
	var effect_context: Array = [
		host._country_handle, known,
		host._snapshot.get("levels", PackedInt32Array()),
		host._snapshot.get("locations", PackedInt32Array()),
		host._snapshot.get("active_synergy_ids", PackedInt32Array())]
	if host._effect_report_context != effect_context:
		host._effect_report_context = effect_context
		host._effect_report_day = -1
	if host._effect_report_day != host._current_day or host._effect_summary.is_empty():
		host._effect_report_day = host._current_day
		effect_changed_ids = host._refresh_effect_report()
	var signature = host._board_signature(known)
	var active_synergy_ids: PackedInt32Array = host._snapshot.get(
		"active_synergy_ids", PackedInt32Array())
	if signature != host._signature:
		host._signature = signature
		host._rebuild_board()
		host._resonance_signature = active_synergy_ids
	else:
		if active_synergy_ids != host._resonance_signature:
			host._resonance_signature = active_synergy_ids
			host._update_resonance(null, -1)
		host._refresh_board_values(support_changed,
			state_changes.get("progress_ids", PackedInt32Array()),
			state_changes.get("pending_ids", PackedInt32Array()),
			state_changes.get("level_ids", PackedInt32Array()), effect_changed_ids)
	host._rebuild_offer()
	host._show_empty_state(bool(host._presentation.get("empty", known.is_empty())), host._presentation)



func _index_catalog(host) -> void:
	var rows: Array = host._catalog.get("ideologies", [])
	if rows.size() == host._metadata.size() and not host._metadata.is_empty():
		return
	host._metadata.clear()
	for row_value in rows:
		var row = row_value as Dictionary
		host._metadata[int(row.get("dense_id", -1))] = row



func _index_states(host) -> Dictionary:
	var ids: PackedInt32Array = host._snapshot.get("idea_ids", PackedInt32Array())
	var understanding: PackedInt64Array = host._snapshot.get("understanding_q16", PackedInt64Array())
	var levels: PackedInt32Array = host._snapshot.get("levels", PackedInt32Array())
	var locations: PackedInt32Array = host._snapshot.get("locations", PackedInt32Array())
	var pending: PackedByteArray = host._snapshot.get("transition_pending", PackedByteArray())
	var same_ids = host._indexed_snapshot_valid and ids == host._indexed_idea_ids
	var changed = not same_ids or understanding != host._indexed_understanding \
		or levels != host._indexed_levels or locations != host._indexed_locations \
		or pending != host._indexed_pending
	if not changed:
		return {"progress_ids": PackedInt32Array(),
			"pending_ids": PackedInt32Array(), "level_ids": PackedInt32Array()}
	if not same_ids:
		host._states.clear()
	var progress_ids = PackedInt32Array()
	var pending_ids = PackedInt32Array()
	var level_ids = PackedInt32Array()
	for index in ids.size():
		var idea_id = int(ids[index])
		var state: Dictionary = host._states.get(idea_id, {})
		var next_understanding = int(understanding[index]) if index < understanding.size() else 0
		var next_level = int(levels[index]) if index < levels.size() else 0
		var next_location = int(locations[index]) if index < locations.size() else 0
		var next_pending = index < pending.size() and pending[index] != 0
		if not same_ids or int(state.get("understanding", -1)) != next_understanding \
				or int(state.get("level", -1)) != next_level:
			progress_ids.append(idea_id)
		if not same_ids or int(state.get("level", -1)) != next_level:
			level_ids.append(idea_id)
		if not same_ids or bool(state.get("pending", false)) != next_pending:
			pending_ids.append(idea_id)
		state["understanding"] = next_understanding
		state["level"] = next_level
		state["location"] = next_location
		state["pending"] = next_pending
		host._states[idea_id] = state
	host._indexed_snapshot_valid = true
	host._indexed_idea_ids = ids
	host._indexed_understanding = understanding
	host._indexed_levels = levels
	host._indexed_locations = locations
	host._indexed_pending = pending
	return {"progress_ids": progress_ids, "pending_ids": pending_ids,
		"level_ids": level_ids}



func _render_top(host) -> void:
	var points = int(host._presentation.get("points", 0))
	var cost = int(host._presentation.get("offer_cost_q16", 65536))
	var gain = int(host._presentation.get("last_gain_q16", 0))
	var ready = bool(host._presentation.get("baseline_ready", false))
	var points_signature = "%d|%d|%d|%s" % [points, cost, gain, ready]
	if points_signature != host._points_signature:
		host._points_signature = points_signature
		host._point_scroll.call("set_points", points, cost, gain, ready, host.motion_reduced())
	host._point_scroll.tooltip_text = "理念点 %s / 抽取 %s\n累计 %s" % [
		host._q16(points), host._q16(cost), host._q16(int(host._presentation.get("lifetime_points_q16", 0)))]
	var offer_active = bool(host._presentation.get("offer_active", false))
	var waiting = host._draw_waiting()
	var generation = int(host._snapshot.get("offer_generation", 0))
	var collapsed = offer_active and generation == host._dismissed_generation
	host._offer_button.disabled = waiting or not (bool(host._presentation.get("can_open_offer", false))
		or collapsed)
	if waiting:
		host._offer_button.text = "抽取中…"
	elif collapsed:
		host._offer_button.text = "查看候选"
	elif offer_active:
		host._offer_button.text = "候选待选"
	else:
		host._offer_button.text = "抽取 · %s" % String(
			host._presentation.get("offer_cost_text", ""))
	host._offer_button.tooltip_text = "每次抽取消耗 %s 理念点，下次费用 +20%%" \
		% String(host._presentation.get("offer_cost_text", ""))
	if Time.get_ticks_msec() >= host._hint_hold_until:
		host._hint.text = "" if waiting \
			else String(host._presentation.get("offer_hint", ""))
		host._hint.visible = not host._compact and not host._hint.text.is_empty()
	# Capacity is carried by the slot rows themselves; do not repeat it as a
	# second counter above the board.
	host._slot_counts.text = ""
	host._slot_counts.visible = false



func _draw_waiting(host) -> bool:
	return host._pending_draw_sequence >= 0


func _blocking_confirmation_reason(host, allow_ideology: bool = false) -> String:
	if host._player_controller == null or not host._player_controller.has_method("player_confirmation_reason"):
		return ""
	var reason := String(host._player_controller.player_confirmation_reason())
	return "" if reason.is_empty() or (allow_ideology and reason == "ideology_choice_required") else reason


## Per-card effect-instance totals for the card face.
##
## Effect target rows can change when a committed day changes or an equipped
## card changes. The UI only queries this native report at those boundaries.

func _refresh_effect_report(host) -> PackedInt32Array:
	if host._facade == null or host._country_handle == 0:
		return host._replace_effect_summary({})
	var report: Dictionary = host._facade.effect_instances(host._country_handle)
	if not bool(report.get("ok", false)):
		return host._replace_effect_summary({})
	var summary: Dictionary = host.IdeologyEffectReportScript.summarize(report)
	if not bool(summary.get("ok", false)):
		return host._replace_effect_summary({})
	return host._replace_effect_summary(summary)



func _replace_effect_summary(host, summary: Dictionary) -> PackedInt32Array:
	var previous_rows: Dictionary = host._effect_summary.get("by_idea", {})
	var next_rows: Dictionary = summary.get("by_idea", {})
	var changed = PackedInt32Array()
	for raw_id in previous_rows:
		var idea_id = int(raw_id)
		if not next_rows.has(raw_id) or previous_rows[raw_id] != next_rows[raw_id]:
			changed.append(idea_id)
	for raw_id in next_rows:
		if not previous_rows.has(raw_id):
			changed.append(int(raw_id))
	host._effect_summary = summary
	return changed



func _refresh_live_explain(host, known: PackedInt32Array) -> void:
	IdeologySupport._refresh_live_explain(host, known)


# --- deck table and collection --------------------------------------------


func _rebuild_board(host) -> void:
	Collection._rebuild_board(host)


func _board_signature(host, known: PackedInt32Array) -> Array:
	return Collection._board_signature(host, known)


func _slot_row_data(host, ideology_id: int, kind: int) -> Dictionary:
	return Collection._slot_row_data(host, ideology_id, kind)


func _next_milestone(host, kind: int) -> String:
	return Collection._next_milestone(host, kind)


func _locked_captions(host, kind: int) -> PackedStringArray:
	return Collection._locked_captions(host, kind)


func _rebuild_collection(host, known: PackedInt32Array) -> void:
	Collection._rebuild_collection(host, known)


func _on_collection_resized(host) -> void:
	Collection._on_collection_resized(host)


func _apply_collection_columns(host) -> void:
	Collection._apply_collection_columns(host)


func _collection_max_card_width(host) -> float:
	return Collection._collection_max_card_width(host)


static func _update_collection_metrics(host, _visible_count: int) -> void:
	Collection._update_collection_metrics(host, _visible_count)


func _sort_less(host, a: int, b: int) -> bool:
	return Collection._sort_less(host, a, b)


func _make_collection_entry(host, ideology_id: int) -> Control:
	return Collection._make_collection_entry(host, ideology_id)


static func _action_button(host, text: String, disabled: bool, callback: Callable,
		tooltip: String, _compact_value := false) -> Button:
	return Collection._action_button(host, text, disabled, callback, tooltip, _compact_value)


static func _secondary_action_button(host, text: String, callback: Callable,
		tooltip: String, compact_value := false) -> Button:
	return Collection._secondary_action_button(host, text, callback, tooltip, compact_value)


func _on_card_locate_requested(host, ideology_id: int) -> void:
	if host._effect_summary.is_empty() and host._facade != null and host._country_handle > 0:
		host._refresh_effect_report()
	var row: Dictionary = host.IdeologyEffectReportScript.card_row(host._effect_summary, ideology_id)
	if row.is_empty():
		return
	var cells: PackedInt32Array = row.get("cells", PackedInt32Array())
	if cells.is_empty():
		return
	host.target_cells_requested.emit(cells)



func _card_data(host, ideology_id: int, in_collection: bool) -> Dictionary:
	return CardData._card_data(host, ideology_id, in_collection)


func _detail_data(host, ideology_id: int, offer := false) -> Dictionary:
	return CardData._detail_data(host, ideology_id, offer)


static func _id_set(host, ids: PackedInt32Array) -> Dictionary:
	return CardData._id_set(host, ids)


func _progress_data(host, ideology_id: int) -> Dictionary:
	return CardData._progress_data(host, ideology_id)


func _school_counts(host, extra_id: int) -> Dictionary:
	return CardData._school_counts(host, extra_id)


func _update_resonance(host, _niche: Control, preview_id: int) -> void:
	CardData._update_resonance(host, _niche, preview_id)


func _on_niche_drop(host, ideology_id: int, from_location: int, kind: int) -> void:
	host._hover_niche = null
	host._hover_id = -1
	host._update_resonance(null, -1)
	if kind == 1:
		if from_location == 0:
			host._command("equip", ideology_id)
		return
	if from_location != 1:
		host._flash_hint("需先推行")
		return
	host._request_promotion(ideology_id)



func _on_niche_hover(host, ideology_id: int, kind: int, entered: bool, niche: Control) -> void:
	var location = int((host._states.get(ideology_id, {}) as Dictionary).get("location", 0))
	if entered and kind == 1 and location == 0:
		host._hover_niche = niche
		host._hover_id = ideology_id
		host._update_resonance(niche, ideology_id)
	elif host._hover_niche == niche or not entered:
		host._hover_niche = null
		host._hover_id = -1
		host._update_resonance(null, -1)



static func _can_drop_collection(host, _at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and (data as Dictionary).has("ideology_card") \
		and int((data as Dictionary).get("location", 0)) == 1



func _drop_collection(host, _at_position: Vector2, data: Variant) -> void:
	host._command("unequip", int((data as Dictionary).get("ideology_card", -1)))


static func _fill_slots(workspace, host: VBoxContainer, kind: int, hosted: Array[int], capacity: int) -> void:
	if host == null:
		return
	if kind == 2:
		if workspace._spirit_alcove != null:
			workspace._spirit_alcove.visible = capacity > 0
		if workspace._spirit_section_header != null:
			workspace._spirit_section_header.visible = capacity > 0
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()
	for ideology_id in hosted:
		var row = workspace.NicheScript.new()
		row.configure(kind, false, workspace._compact)
		row.set_row(workspace._slot_row_data(ideology_id, kind))
		row.command_requested.connect(workspace._on_slot_command)
		row.promote_requested.connect(workspace._request_promotion)
		# Same handler as the card grid: "where does this act" does not depend on
		# whether the caller was a 196x260 card or a 60px row.
		row.locate_requested.connect(workspace._on_card_locate_requested)
		if row.has_signal("detail_requested"):
			row.detail_requested.connect(workspace._open_detail_modal.bind(false))
		host.add_child(row)
	var empty_count = maxi(0, capacity - hosted.size())
	if empty_count > 0:
		var empty_row = workspace.NicheScript.new()
		empty_row.configure(kind, true, workspace._compact)
		# The next technology milestone belongs on the empty slot itself: the
		# hint only exists while a slot is still missing, so it never costs
		# vertical space in a full board.
		empty_row.set_empty_count(empty_count, workspace._next_milestone(kind))
		empty_row.card_dropped.connect(workspace._on_niche_drop)
		empty_row.drag_hovered.connect(workspace._on_niche_hover.bind(empty_row))
		host.add_child(empty_row)


static func _refresh_board_values(workspace, support_changed: bool,
		progress_ids: PackedInt32Array, pending_ids: PackedInt32Array,
		level_ids: PackedInt32Array, effect_ids: PackedInt32Array) -> void:
	if not support_changed and progress_ids.is_empty() \
			and pending_ids.is_empty() and level_ids.is_empty() \
			and effect_ids.is_empty():
		return
	var progress_set = workspace._id_set(progress_ids)
	var pending_set = workspace._id_set(pending_ids)
	var level_set = workspace._id_set(level_ids)
	var effect_set = workspace._id_set(effect_ids)
	for host in [workspace._ideology_slots, workspace._spirit_slots]:
		for row in host.get_children():
			var id = int(row.get("occupied_id"))
			if id >= 0 and (support_changed or progress_set.has(id) \
					or pending_set.has(id) or level_set.has(id) \
					or effect_set.has(id)):
				row.set_row(workspace._slot_row_data(id, int(row.get("kind"))))
	if not support_changed and progress_ids.is_empty() \
			and pending_ids.is_empty() and level_ids.is_empty() \
			and effect_ids.is_empty():
		return
	for id in workspace._collection_entries:
		var idea_id = int(id)
		if not support_changed and not progress_set.has(idea_id) \
				and not pending_set.has(idea_id) and not level_set.has(idea_id) \
				and not effect_set.has(idea_id):
			continue
		var entry: Control = workspace._collection_entries[id]
		var live: Dictionary = workspace._live_by_id.get(idea_id, {})
		var state: Dictionary = workspace._states.get(idea_id, {})
		var location = int(state.get("location", 0))
		if pending_set.has(idea_id):
			entry.call("refresh_status", bool(state.get("pending", false)), location)
		if support_changed:
			entry.call("refresh_support_details", workspace._support_details(live, location))
		if support_changed or pending_set.has(idea_id) or level_set.has(idea_id) or effect_set.has(idea_id):
			var footer = entry.call("footer") as HBoxContainer
			var effect_row = workspace.IdeologyEffectReportScript.card_row(workspace._effect_summary, idea_id)
			var target_cells: PackedInt32Array = effect_row.get("cells", PackedInt32Array())
			var has_target_cells = not target_cells.is_empty()
			for button in footer.get_children():
				if not button is Button:
					continue
				var action = String(button.get_meta("ideology_action", ""))
				if action == "详情":
					continue
				if action == "定位":
					button.visible = has_target_cells
					button.tooltip_text = "在地图上定位 %d 处生效地块" % target_cells.size() \
						if has_target_cells else "在地图上定位生效地块"
					continue
				var direction = 0 if action == "推行" else 1 if action == "撤回" else 2
				var key: String = ["equip_allowed", "unequip_allowed", "promote_allowed"][direction]
				button.disabled = bool(state.get("pending", false)) \
					or not bool(live.get(key, false))
				if direction == 2:
					button.disabled = button.disabled or int(state.get("level", 0)) < int(
						(workspace._metadata.get(idea_id, {}) as Dictionary).get("min_spirit_level", 99))
				if support_changed:
					button.tooltip_text = workspace._support_tooltip(live, direction)
		if level_set.has(idea_id) or effect_set.has(idea_id):
			entry.call("refresh_card_data", workspace._card_data(idea_id, true))
		elif progress_set.has(idea_id):
			entry.call("refresh_progress", workspace._progress_data(idea_id))
	if workspace.is_detail_modal_open() and workspace._detail_ideology_id >= 0:
		workspace._present_detail_dictionary(workspace._detail_data(workspace._detail_ideology_id, workspace._detail_is_offer))
