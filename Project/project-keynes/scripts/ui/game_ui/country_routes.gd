extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _locate_cell_from_family_founding(host, cell_index: int) -> void:
	if host._country_panel != null and host._country_panel.is_panel_open():
		host.close_country_panel()
	if host._player_controller != null and host._player_controller.has_method(
			"focus_family_founding_cell"):
		host._player_controller.focus_family_founding_cell(cell_index)
	elif host._player_controller != null and host._map != null and cell_index >= 0:
		var cell: HexCell = host._map.cell_at(cell_index)
		if cell != null:
			host._player_controller.select_cell(cell)
	host._layout_family_founding_dialog()


func _on_founding_collapsed_changed(host, collapsed: bool) -> void:
	host._layout_country_action_bar()
	if not collapsed and host._player_controller != null:
		host._player_controller.ensure_selected_visible()


func _cancel_colonization_targeting(host) -> void:
	host._colonization_targeting.clear()
	if host._colonization_panel == null:
		return
	if host._colonization_panel.is_source_picking():
		host._colonization_panel.cancel_source_selection()
	else:
		host._colonization_panel.cancel_target_selection()


func _on_colonization_planning_context(host, context: Dictionary) -> void:
	if host._colonization_route == null:
		return
	if context.is_empty():
		host._colonization_route.clear_planning_context()
		return
	var sources: PackedInt32Array = context.get("sources", PackedInt32Array())
	host._colonization_route.set_planning_context(sources,
		int(context.get("selected_source", -1)),
		int(context.get("target_cell", -1)))


func _ensure_research_toast(host) -> void:
	if host._research_toast != null:
		return
	var hud := host.get_node_or_null("UIRoot/HUDLayer") as Control
	if hud == null:
		return
	host._research_toast = host.ResearchToastScene.instantiate() as ResearchToast
	host._research_toast.name = "ResearchToast"
	host._research_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(host._research_toast)
	host._layout_research_toast()

func open_country_section(host, section_id: String, economy_chapter: String = "") -> void:
	if section_id == "ideology":
		section_id = "politics"
	if host._player_controller != null:
		host._player_controller.cancel_military_arm_order()
	if section_id == "annual":
		host.close_country_panel()
		host.annual_history_requested.emit()
		return
	# 卷宗一打开就收起时代纸笺：纸笺在面板层之上，留着会浮在压暗的国家卷宗上。
	if host._era_panel != null and host._era_panel.is_open():
		host._close_era_panel()
	if host._country_panel == null or host._country_view_model == null:
		return
	# 打开国家面板时纸签悬浮卡必须退场：它盖在面板边缘，也没必要再读旧值。
	host._status_card_generation += 1
	host._status_card_kind = ""
	if host._status_card != null:
		host._status_card.hide_card(true)
	# Opening a section is an explicit player action and should never inherit a
	# throttle window left by a previously visible section.
	host._country_refresh_queued = false
	host._country_next_refresh_ms = 0
	host._country_refresh_timer_active = false
	host._hide_inspector_for_country()
	host._country_action_bar.set_active(section_id)
	if section_id == "economy" and not economy_chapter.is_empty() \
			and host._country_panel.has_method("focus_economy_chapter"):
		host._country_panel.focus_economy_chapter(economy_chapter)
	host._country_open_generation += 1
	var generation = host._country_open_generation
	if not host._country_ui_event_refresh_enabled:
		var started_usec = Time.get_ticks_usec()
		host._country_panel.show_section(section_id, host._country_view_model.build_legacy(section_id))
		host._record_country_ui_perf("legacy_full_build", false,
			(Time.get_ticks_usec() - started_usec) / 1000.0,
			host._country_section_mask(section_id))
		host._country_dirty_domains &= ~host._country_section_mask(section_id)
		return
	var cached = host._country_view_model.cached_section(section_id)
	if not cached.is_empty():
		host._country_panel.show_section(section_id, cached)
		host._record_country_ui_perf("panel_open_cache", true, 0.0,
			host._country_section_mask(section_id))
		host._country_dirty_domains &= ~host._country_section_mask(section_id)
		return
	host._country_panel.show_section(section_id, {
		"available": false,
		"country_name": "国家事务",
		"reason": "正在载入已提交数据",
	})
	host.call_deferred("_load_country_section_deferred", section_id, generation)



func _load_country_section_deferred(host, section_id: String, generation: int) -> void:
	if generation != host._country_open_generation or host._country_panel == null \
			or not host._country_panel.is_panel_open() \
			or host._country_panel.current_section() != section_id:
		return
	var started_usec = Time.get_ticks_usec()
	host._country_panel.refresh_summary(host._country_view_model.build(section_id))
	host._record_country_ui_perf("panel_open", false,
		(Time.get_ticks_usec() - started_usec) / 1000.0,
		host._country_section_mask(section_id))
	host._country_dirty_domains &= ~host._country_section_mask(section_id)
	var open_mask = host._country_section_mask(section_id)
	var open_interval = host.COUNTRY_UI_TECH_REFRESH_INTERVAL_MSEC \
		if open_mask == host.COUNTRY_DIRTY_TECHNOLOGY \
		else host.COUNTRY_UI_REFRESH_INTERVAL_MSEC
	host._country_next_refresh_ms = Time.get_ticks_msec() + open_interval



func _locate_cell_from_country_panel(host, cell_index: int) -> void:
	host.close_country_panel()
	if host._player_controller == null or host._map == null:
		return
	var cell = host._map.cell_at(cell_index)
	if cell != null:
		host._player_controller.select_cell(cell)


## "A card acts here." Same shape as the single-cell locate above — close the
## panel first, because it is full-bleed and would cover the very hexes we are
## about to paint — but the map side receives a set instead of a selection.

func _on_target_cells_from_country_panel(host, cells: PackedInt32Array) -> void:
	if host._player_controller == null:
		return
	# Dock the shell beside the map instead of closing it. Closing was the old
	# behaviour and it threw away the card the player was reading at the exact
	# moment they asked "where does this act?" — the highlight outlived the
	# panel, but so did the question of which card had painted it.
	if host._country_panel != null and host._country_panel.is_panel_open():
		host._country_panel.set_docked(true)
	host._player_controller.highlight_cells(cells)


## 物资详情逐单商路翻页：只更新请求 offset，再走既有对象详情 payload 通道重建。
## ViewModel 按 committed generation 缓存，翻页也是一次有界页查询。

func _on_trade_orders_page_requested(host, offset: int) -> void:
	if host._object_detail_context.is_empty() \
			or String(host._object_detail_context.get("kind", "")) != "good":
		return
	var request: Dictionary = host._object_detail_context.get("request", {})
	request["orders_offset"] = maxi(0, offset)
	host._object_detail_context["request"] = request
	host._refresh_object_detail(true)


## 点击逐单行的可见对端：关闭当前详情并选中该地块（与 country panel 定位语义一致）。

func _on_trade_order_locate_requested(host, cell_index: int) -> void:
	if host._player_controller == null or host._map == null:
		return
	var cell = host._map.cell_at(cell_index)
	if cell == null:
		return
	host._close_object_detail_dialog()
	host._player_controller.select_cell(cell)



func close_country_panel(host) -> void:
	host._country_open_generation += 1
	host._country_refresh_queued = false
	host._country_refresh_timer_active = false
	host._country_next_refresh_ms = 0
	if host._country_panel != null and host._country_panel.is_panel_open():
		# Undock before closing: the next open is a full-bleed screen again, and
		# a dock left set would silently shrink it with no way to tell why.
		host._country_panel.set_docked(false)
		host._country_panel.close_panel()
	# A closed panel never needs a fresh Native query. Drop only dynamic section
	# models so the next open starts from a committed shell and loads details
	# through the deferred section path; the static catalog remains session-cached.
	if host._country_view_model != null:
		host._country_view_model.invalidate_cache()
	if host._country_action_bar != null:
		host._country_action_bar.set_active("")



func _hide_inspector_for_country(host) -> void:
	if host._right_panel == null or not host._right_panel.visible:
		return
	host._inspector_suppressed_for_country = true
	host._right_panel.visible = false



func _restore_inspector_after_country(host) -> void:
	if not host._inspector_suppressed_for_country:
		return
	host._inspector_suppressed_for_country = false
	if host._selected_cell == null or host._right_panel == null:
		return
	host._right_panel.visible = true
	host._right_panel.modulate.a = 1.0



func refresh_country_summary(host) -> Dictionary:
	var timing = {"ran": false, "elapsed_ms": 0.0}
	if host._country_panel == null or not host._country_panel.is_panel_open() \
			or host._country_view_model == null:
		return timing
	var started_usec = Time.get_ticks_usec()
	var model = host._country_view_model.build(host._country_panel.current_section()) \
		if host._country_ui_event_refresh_enabled else host._country_view_model.build_legacy(
			host._country_panel.current_section())
	host._country_panel.refresh_summary(model)
	timing["ran"] = true
	timing["elapsed_ms"] = (Time.get_ticks_usec() - started_usec) / 1000.0
	host._record_country_ui_perf(
		host._country_refresh_reason if not host._country_refresh_reason.is_empty() else "explicit",
		false, float(timing["elapsed_ms"]),
		host._country_section_mask(host._country_panel.current_section()))
	return timing



func _record_country_ui_perf(host, reason: String, cache_hit: bool,
		snapshot_ms: float, dirty_domains: int) -> void:
	host._country_ui_perf_pending = {
		"country_ui_refresh_reason": reason,
		"country_ui_snapshot_ms": maxf(0.0, snapshot_ms),
		"country_ui_cache_hit": cache_hit,
		"country_ui_dirty_domains": dirty_domains,
		"country_ui_event_refresh_enabled": host._country_ui_event_refresh_enabled,
	}



func consume_country_ui_perf_summary(host) -> Dictionary:
	var out = host._country_ui_perf_pending.duplicate(false)
	host._country_ui_perf_pending.clear()
	return out



func _on_inspector_tab_data_requested(host, tab_id: String) -> void:
	if host._selected_cell == null or host._inspector_view_model == null or host._right_panel == null:
		return
	host._invalidate_live_revision()
	host._pending_object_request.clear()
	var category = host._inspector_view_model.build_tab_category(host._selected_cell, tab_id)
	host._right_panel.set_tab_category(tab_id, category)
	host._pending_inspector_tab = tab_id if bool(category.get("data_pending", false)) else ""
	if not host._pending_inspector_tab.is_empty():
		host._schedule_inspector_retry()



func _cancel_inspector_retry(host) -> void:
	host._inspector_retry_generation += 1
	host._inspector_retry_queued = false
	host._pending_inspector_tab = ""
	host._pending_object_request.clear()



func _retry_inspector_reads(host, generation: int) -> void:
	if generation != host._inspector_retry_generation:
		return
	host._inspector_retry_queued = false
	if host._selected_cell == null or host._right_panel == null or not host._right_panel.visible:
		host._cancel_inspector_retry()
		return
	if not host._pending_inspector_tab.is_empty():
		var tab_id = host._pending_inspector_tab
		if tab_id == host._right_panel.current_tab():
			var category = host._inspector_view_model.build_tab_category(host._selected_cell, tab_id)
			host._right_panel.apply_live_patch({"tab_id": tab_id, "category": category})
			if not bool(category.get("data_pending", false)):
				host._pending_inspector_tab = ""
		else:
			host._pending_inspector_tab = ""
	if not host._pending_object_request.is_empty():
		host._on_object_details_requested(host._pending_object_request)
	if not host._pending_inspector_tab.is_empty() or not host._pending_object_request.is_empty():
		host._schedule_inspector_retry()


## 营造窗口的一次目录页请求：部门 + 搜索词 + 排序档 + 偏移由窗口自己记，这里只
## 负责让 view model 组一整页模型（整部门报价后排序、再切一页）并推回窗口。

func _on_construction_page_requested(host, sector: String, search: String,
		sort_id: String, offset: int) -> void:
	if host._selected_cell == null or host._inspector_view_model == null or host._right_panel == null:
		return
	host._last_construction_refresh_ms = Time.get_ticks_msec()
	host._right_panel.set_construction_model(
		host._inspector_view_model.build_construction_model(
			int(host._selected_cell.index), sector, search, sort_id, offset))


## 次日结算会改变国库、市场与仓库；只在窗口打开时按墙钟节流重发同一页。

func _refresh_building_workspace(host, force: bool = false) -> void:
	if host._right_panel == null or not host._right_panel.building_workspace_open():
		return
	if not force and Time.get_ticks_msec() - host._last_construction_refresh_ms \
			< host.BUILDING_WORKSPACE_REFRESH_MSEC:
		return
	host._right_panel.request_construction_refresh()



func _on_construction_requested(host, request: Dictionary) -> void:
	if host._selected_cell == null or host._player_controller == null or host._right_panel == null:
		push_warning("[construction] click dropped: selected_cell=%s controller=%s right_panel=%s" % [
			str(host._selected_cell != null), str(host._player_controller != null),
			str(host._right_panel != null)])
		return
	# 军事部门的条目带 `military_index`：它是军事目录里的 dense 序，必须走
	# `state.build`（原生 MCMD_STATE_BUILD）。送进经济侧的 construction.build
	# 会因为经济目录里没有这座建筑而被拒。
	if request.has("military_index"):
		host._on_military_state_building_requested({
			"cell": int(host._selected_cell.index),
			"op": String(request.get("op", "state.build")),
			"building": int(request.get("military_index", -1)),
		})
		return
	var result: Dictionary = host._player_controller.request_command(
		&"construction.build", {"cell_idx": int(host._selected_cell.index),
			"building_id": StringName(request.get("building_id", &"")),
			"ownership_policy": &"treasury_sponsored_private"})
	print("[construction] click cell=%d id=%s -> ok=%s code=%s message=%s" % [
		int(host._selected_cell.index), String(request.get("building_id", &"")),
		str(result.get("ok", false)), str(result.get("code", "")),
		String(result.get("message", result.get("reason", "")))])
	host._right_panel.set_construction_feedback(
		String(result.get("message", result.get("reason", "修建命令未能提交。"))),
		bool(result.get("ok", false)))



func _open_colonization_target(host, target_cell: int, family_handle: int = 0,
		source_cell: int = -1) -> void:
	if host._colonization_panel == null:
		return
	host._close_object_detail_dialog()
	host._suppress_ui_for_dispatch()
	host._colonization_panel.open_target(target_cell, family_handle, source_cell)
	if host._player_controller != null and host._player_controller.has_method("ensure_selected_visible"):
		host._player_controller.ensure_selected_visible()



func _open_dispatch_progress(host) -> void:
	if host._colonization_panel == null:
		return
	host._close_object_detail_dialog()
	host._suppress_ui_for_dispatch()
	host._colonization_panel.open_expeditions()



func _refresh_dispatch_status(host) -> void:
	if host._top_bar == null:
		return
	if host._player_controller == null:
		host._top_bar.set_dispatch_status(0, 0, 0)
		return
	var counts = [0, 0, 0]
	var offset = 0
	while true:
		var page: Dictionary = host._player_controller.get_family_expeditions(offset, 128)
		if not bool(page.get("ok", false)):
			return
		var states: PackedInt32Array = page.get("states", PackedInt32Array())
		for state in states:
			if state == 4:
				counts[0] += 1
			elif state == 3:
				counts[2] += 1
			else:
				counts[1] += 1
		if not bool(page.get("has_more", false)) or states.is_empty():
			break
		offset += states.size()
	host._top_bar.set_dispatch_status(counts[0], counts[1], counts[2])



func _on_colonization_requested(host, request: Dictionary) -> void:
	host._open_colonization_target(int(request.get("target_cell", -1)))



func _on_family_colonization_requested(host, family_handle: int,
		source_cell: int) -> void:
	if host._colonization_panel == null:
		return
	host._close_object_detail_dialog()
	host._suppress_ui_for_dispatch()
	host._colonization_panel.open_source(source_cell, family_handle)
	if host._player_controller != null and host._player_controller.has_method("ensure_selected_visible"):
		host._player_controller.ensure_selected_visible()



func _suppress_ui_for_dispatch(host) -> void:
	if host._dispatch_ui_suppressed:
		return
	host._dispatch_ui_suppressed = true
	host._dispatch_previous_inspector_visible = host._right_panel != null and host._right_panel.visible
	host._dispatch_previous_toolbar_visible = host._map_overlay_toolbar != null and host._map_overlay_toolbar.visible
	if host._right_panel != null:
		host._right_panel.hide()
	if host._map_overlay_toolbar != null:
		host._map_overlay_toolbar.hide()



func _on_dispatch_closed(host) -> void:
	host._colonization_targeting.clear()
	if not host._dispatch_ui_suppressed:
		return
	host._dispatch_ui_suppressed = false
	if host._right_panel != null:
		host._right_panel.visible = host._dispatch_previous_inspector_visible
	if host._map_overlay_toolbar != null:
		host._map_overlay_toolbar.visible = host._dispatch_previous_toolbar_visible
	if host._dispatch_previous_inspector_visible and host._player_controller != null \
			and host._player_controller.has_method("selected_cell"):
		var cell = host._player_controller.selected_cell()
		if cell != null:
			host.show_cell_panel(cell)


# ── peace window (MilitaryPeaceWindow) ──────────────────────────────────

## Open the dedicated peace window for one war. The country shell is full-bleed,
## so it has to close first — the whole point of this window is the map behind it.

func open_military_peace(host, war_id: int) -> void:
	if host._peace_window == null or host._country_view_model == null:
		return
	if int(war_id) <= 0:
		return
	if host._country_panel != null and host._country_panel.is_panel_open():
		host.close_country_panel()
	if host._colonization_panel != null and host._colonization_panel.visible:
		host._colonization_panel.close_panel()
	host._colonization_targeting.clear()
	host._suppress_ui_for_dispatch()
	# The window is the only consumer here, so one fresh military model is enough.
	host._country_view_model.invalidate_cache(host.COUNTRY_DIRTY_MILITARY)
	host._peace_window.set_player_controller(host._player_controller)
	host._peace_window.open(int(war_id), host._country_view_model.build("military"))
	var focus_cell = host._peace_focus_cell()
	if focus_cell >= 0 and host._player_controller != null \
			and host._player_controller.has_method("focus_map_cell"):
		host._player_controller.call("focus_map_cell", focus_cell)



func close_military_peace(host) -> void:
	if host._peace_window != null:
		host._peace_window.close_panel()



func is_peace_window_open(host) -> bool:
	return host._peace_window != null and bool(host._peace_window.is_open())


## Map click entry: true means the window consumed it (a cession toggle or a
## "you cannot cede this" note), false only when no window is open.

func handle_peace_map_cell(host, cell: int) -> bool:
	if not host.is_peace_window_open():
		return false
	return bool(host._peace_window.handle_map_cell(int(cell)))



func _peace_focus_cell(host) -> int:
	if host._peace_window == null:
		return -1
	var candidates: PackedInt32Array = host._peace_window.candidate_cells()
	return int(candidates[0]) if not candidates.is_empty() else -1



func _on_peace_window_closed(host) -> void:
	# No clear_selection_requested() here: the window never moved the selection
	# (it eats map clicks), so closing it must hand the inspector back exactly as
	# the player left it.
	host._on_dispatch_closed()



func _on_peace_submit_requested(host, payload: Dictionary) -> void:
	if host._player_controller == null or host._peace_window == null:
		return
	var result: Dictionary = host._player_controller.request_command(
		host.PlayerControllerScript.COMMAND_MILITARY_PEACE_PROPOSE, {
			"war_id": int(payload.get("war_id", 0)),
			"terms": payload.get("terms", []),
		})
	host._peace_window.set_command_result(result)



func _on_peace_locate_requested(host, cell: int) -> void:
	if host._player_controller != null and host._player_controller.has_method("focus_map_cell"):
		host._player_controller.call("focus_map_cell", int(cell))



func _refresh_peace_window(host) -> void:
	if not host.is_peace_window_open() or host._country_view_model == null or host._peace_window == null:
		return
	host._country_view_model.invalidate_cache(host.COUNTRY_DIRTY_MILITARY)
	host._peace_window.refresh_model(host._country_view_model.build("military"))



func _on_colonization_start_requested(host, args: Dictionary) -> void:
	if host._player_controller == null or host._colonization_panel == null:
		return
	var result: Dictionary = host._player_controller.request_command(
		&"family.colonization.start", args)
	host._colonization_panel.set_command_result(result)
	host._refresh_dispatch_status()
	if bool(result.get("ok", false)) and result.has("expedition_handle"):
		host._on_expedition_selected(int(result.expedition_handle))



func _on_colonization_cancel_requested(host, expedition_handle: int) -> void:
	if host._player_controller == null or host._colonization_panel == null:
		return
	var result: Dictionary = host._player_controller.request_command(
		&"family.colonization.cancel", {"expedition_handle": expedition_handle})
	host._colonization_panel.set_command_result(result)
	host._refresh_dispatch_status()
	if bool(result.get("ok", false)):
		host._on_expedition_selected(expedition_handle)



func _on_expedition_selected(host, expedition_handle: int) -> void:
	if host._player_controller == null or host._colonization_route == null:
		return
	var snapshot: Dictionary = host._player_controller.get_family_expedition_snapshot(
		expedition_handle)
	if bool(snapshot.get("ok", false)):
		host._colonization_route.show_expedition(snapshot)



func _play_progression_cue(host, cue: StringName) -> void:
	var audio = host.get_node_or_null("/root/GameAudio")
	if audio != null:
		audio.play_event_cue(cue)



func _on_player_command_completed_audio(host, id: StringName, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		return
	# 入队与抽牌先反馈已接受的操作，装备/晋升则等待权威结算成功。
	var cues = {&"research.enqueue": &"tech_start", &"research.remove": &"tech_cancel",
		&"ideology.offer": &"ideology_draw", &"ideology.reroll": &"ideology_reroll",
		&"ideology.choose": &"ideology_choose"}
	if cues.has(id):
		host._play_progression_cue(cues[id])



func _on_player_command_settled(host, id: StringName, result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		var cues = {&"ideology.equip": &"ideology_use",
			&"ideology.unequip": &"ideology_unequip", &"ideology.promote": &"ideology_promote"}
		if cues.has(id):
			host._play_progression_cue(cues[id])
	if id == &"family.colonization.start" or \
			id == &"family.colonization.cancel":
		if host._colonization_panel != null:
			if not result.has("message"):
				result["message"] = "开拓队状态已更新。"
			host._colonization_panel.set_command_result(result)
			host._colonization_panel.refresh_expeditions_if_visible()
		host._refresh_dispatch_status()
		if host._selected_cell != null and String(result.get("code", "")) == "CLAIMED":
			host.refresh_selected_panel()
		host._mark_country_panel_dirty(host.COUNTRY_DIRTY_ECONOMY, "colonization_settled")
		return
	if id != &"construction.build" or host._selected_cell == null or \
			int(result.get("cell_idx", -1)) != int(host._selected_cell.index):
		return
	host.refresh_selected_panel()
	if host._right_panel != null:
		host._right_panel.set_construction_feedback(
			String(result.get("message", "修建命令已结算。")),
			bool(result.get("ok", false)))
	# 结算花掉了国库物资/现金，窗口里的报价与按钮态必须立刻跟着变。
	host._refresh_building_workspace(true)
	host._mark_country_panel_dirty(host.COUNTRY_DIRTY_ECONOMY, "construction_settled")



func _invalidate_live_revision(host) -> void:
	host._live_revision_cell = -1
	host._live_revision_tab = ""
	host._live_common_hash = 0
	host._live_category_generation = -1
	host._live_tax_policy_version = -1
	host._live_category_hash = 0
	host._live_revision_valid = false



func _on_object_details_requested(host, request: Dictionary) -> void:
	if host._selected_cell == null or host._inspector_view_model == null \
			or host._right_panel == null:
		return
	var is_family = String(request.get("kind", "")) == "family"
	var payload = host._inspector_view_model.build_family_detail(host._selected_cell, request) \
		if is_family else host._inspector_view_model.build_object_detail(host._selected_cell, request)
	if bool(payload.get("data_pending", false)):
		host._pending_object_request = request.duplicate(true)
		host._schedule_inspector_retry()
		return
	host._pending_object_request = {}
	if payload.is_empty():
		return
	host._object_detail_context = {
		"cell_idx": int(host._selected_cell.index),
		"kind": "family" if is_family else String(payload.get("kind", "")),
		"item_id": String(payload.get("item_id", "")),
	}
	host._object_detail_context["request"] = request.duplicate(true)
	if is_family:
		host._right_panel.show_family_workspace(payload)
	else:
		host._right_panel.show_object_detail(payload)
	host.call_deferred("_layout_right_panel")



func _close_object_detail_dialog(host) -> void:
	host._pending_object_request.clear()
	host._object_detail_context = {}
	if host._right_panel != null:
		host._right_panel.close_detail(false)
		host.call_deferred("_layout_right_panel")



func _refresh_object_detail(host, force: bool = false) -> void:
	if host._object_detail_context.is_empty() or host._selected_cell == null \
			or host._inspector_view_model == null or host._right_panel == null \
			or not host._right_panel.detail_open():
		return
	var now_ms = Time.get_ticks_msec()
	if not force and now_ms - host._last_object_detail_ms < 200:
		return
	if int(host._object_detail_context.get("cell_idx", -1)) != int(host._selected_cell.index):
		host._close_object_detail_dialog()
		return
	var request: Dictionary = host._object_detail_context.get("request", {})
	var is_family = String(host._object_detail_context.get("kind", "")) == "family"
	var payload = host._inspector_view_model.build_family_detail(host._selected_cell, request) \
		if is_family else host._inspector_view_model.build_object_detail(host._selected_cell, request)
	host._last_object_detail_ms = now_ms
	if bool(payload.get("data_pending", false)):
		return
	if payload.is_empty():
		host._close_object_detail_dialog()
		return
	if is_family:
		host._right_panel.refresh_family_workspace(payload)
	else:
		host._right_panel.refresh_object_detail(payload)


## ── 军务档案（右栏部队 / 战线页）──────────────────────────────────────────
## 拾取在地图层、格式在 MilitaryViewModel；这里只负责开合、定位、动作转发与
## 每日合并刷新。它和对象详情共用 DetailShell，所以面板变宽/目录列都由既有的
## _layout_right_panel() 与 InspectorPanel._sync_split_layout() 决定。



func set_world_context(host, map: MapData,
		generator: MapGenerator,
		view_adapter: DCViewAdapter,
		world_clock: WorldClock,
		sea_level: float,
		hex_size: float) -> void:
	if host._inspector_view_model == null:
		host._inspector_view_model = CellInspectorViewModel.new()
	host._cancel_inspector_retry()
	host._map = map
	host._world_clock = world_clock
	host._gdp_ledger.configure(generator, world_clock, map)
	if host._colonization_route != null:
		var wrap_period := float(host._diagnostics_source.map_wrap_period_x()) \
			if host._diagnostics_source != null and host._diagnostics_source.has_method(
				"map_wrap_period_x") else 0.0
		host._colonization_route.set_context(map, world_clock, hex_size, wrap_period)
	host._inspector_view_model.set_context(map, generator, view_adapter, world_clock, sea_level, hex_size)
	host._inspector_view_model.set_gdp_ledger(host._gdp_ledger)
	host._hover_hex_size = hex_size
	if host._cell_hover_view_model == null:
		host._cell_hover_view_model = CellHoverViewModel.new()
	host._cell_hover_view_model.set_context(map, generator, host._inspector_view_model, world_clock)
	if host._cell_hover_card != null:
		host._cell_hover_card.reset_for_world()
		host._configure_cell_hover_card()
	host._object_detail_context.clear()
	host._selection_context = ""
	host._invalidate_live_revision()
	if host._country_view_model == null:
		host._country_view_model = CountryViewModel.new()
	# 地图必须一起交出去：军事/外交视图模型要读领土镜像、邻接与视野，而 MapGenerator
	# 没有公开的 map getter（它的 `current_map()` 只在截图 fixture 里存在）。
	host._country_view_model.set_context(generator, map)
	host._country_view_model.set_gdp_ledger(host._gdp_ledger)
	host._bind_country_runtime_events(generator)
	if host._era_reward_dialog != null:
		host._era_reward_dialog.close_offer()
		host._era_reward_dialog.close_overview(true)
	if host._era_indicator != null:
		host._era_indicator.reset_for_world()
		# refresh_country_binding 已同步新世界候选；重置动画后保留待领提示。
		host._era_indicator.set_offer_available(String(host._era_offer.get("status", "NONE")) in ["OPEN", "ERROR"])
	if host._era_flight != null:
		host._era_flight.cancel()
	host._era_transfer_name = ""
	# 新世界/读档：撤掉进行中的大典（不补发落地，不恢复旧世界的时钟），只建立显示基线。
	host._abort_era_ceremony()
	host._era_celebrated_index = -1
	host._era_advancement_snapshot = {}
	if host._era_panel != null:
		host._era_panel.close(true)
	host._refresh_era_indicator()
	host._refresh_player_discovery_context()
	if host._right_panel != null:
		host._right_panel.reset_for_world()
	if host._country_panel != null and host._country_panel.has_method("set_player_controller"):
		host._country_panel.set_player_controller(host._player_controller)
	if host._map_overlay_toolbar != null:
		host._map_overlay_toolbar.reset_for_world()
	if host._map_overlay_legend != null:
		host._map_overlay_legend.update_for_mode(OverlayMode.MODE.NONE)
	if host._right_panel != null:
		host._right_panel.close_detail(false)
	if host._colonization_panel != null:
		host._colonization_panel.close_panel()
	if host._gm_console != null:
		host._gm_console.refresh_gm_capabilities()
	if host._country_panel != null:
		host._country_panel.visible = false
	if host._country_action_bar != null:
		host._country_action_bar.set_active("")

func _sync_military_map_toolbar(host) -> void:
	if host._military_map_toolbar == null:
		return
	if host._diagnostics_source == null:
		host._military_map_toolbar.set_available(false)
		return
	var layers = host._diagnostics_source.get("military_map_layers")
	if layers == null or not layers.has_method("layer_visibility"):
		host._military_map_toolbar.set_available(false)
		return
	host._military_map_toolbar.set_available(true)
	var state: Dictionary = layers.layer_visibility()
	for key in state:
		host._military_map_toolbar.set_layer_visibility(StringName(key), bool(state[key]))

func _report_inspector_daily_timing(host, timing: Dictionary, started_usec: int) -> void:
	if not WebTelemetry.enabled():
		return
	var total := float(Time.get_ticks_usec() - started_usec) / 1000.0
	if total < 200.0:
		return
	WebTelemetry.emit("inspector_daily", {
		"dur": int(total),
		"ran": bool(timing.get("ran", false)),
		"tab": String(timing.get("tab", "")),
		"build_ms": int(float(timing.get("live_patch_build_ms", 0.0))),
		"apply_ms": int(float(timing.get("live_patch_apply_ms", 0.0))),
	})

func refresh_selected_daily_lines(host, force: bool = false, day_idx: int = -1) -> Dictionary:
	var _t_all := Time.get_ticks_usec()
	var timing: Dictionary = {
		"ran": false,
		"tab": "",
		"live_patch_build_ms": 0.0,
		"live_patch_apply_ms": 0.0,
	}
	host._refresh_dispatch_status()
	if host._colonization_panel != null and host._colonization_panel.visible:
		host._colonization_panel.refresh_visible()
	if host._selected_cell == null or host._inspector_view_model == null or host._right_panel == null:
		host._report_inspector_daily_timing(timing, _t_all)
		return timing
	# 视野状态变了意味着页签集合变了，打补丁改不动页签栏，必须整块重建。
	var fog := VisionSolver.fog_state(host._map, int(host._selected_cell.index))
	if fog != host._selected_fog_state:
		host._selected_fog_state = fog
		host._set_inspector_trace_cell(int(host._selected_cell.index) \
			if fog == VisionSolver.FOG_VISIBLE else -1)
		host.refresh_selected_panel()
		timing["ran"] = true
		host._report_inspector_daily_timing(timing, _t_all)
		return timing
	var tab_id = host._right_panel.current_tab()
	timing["tab"] = tab_id
	host._inspector_view_model.observe_temperature(host._selected_cell, day_idx)
	var now_ms := Time.get_ticks_msec()
	var population_list = tab_id == "population"
	# 市场/建筑/地理的完整 category 仍按墙钟合并。人口列表改走无需求预览的
	# list snapshot，每个模拟日都能改人数，不再被 750ms 拖住。
	if not force and not population_list \
			and now_ms - host._last_cached_panel_ms < host.INSPECTOR_FULL_PATCH_INTERVAL_MSEC:
		host._refresh_object_detail(false)
		if host._right_panel.detail_open():
			timing["ran"] = true
		host._report_inspector_daily_timing(timing, _t_all)
		return timing
	if not population_list:
		host._last_cached_panel_ms = now_ms
	var revision: Dictionary = host._inspector_view_model.live_patch_revision(
		host._selected_cell, tab_id)
	var next_selection_context = host._revision_selection_context(revision)
	if not host._selection_context.is_empty() and next_selection_context != host._selection_context:
		host._selection_context = next_selection_context
		host.refresh_selected_panel()
		timing["ran"] = true
		host._report_inspector_daily_timing(timing, _t_all)
		return timing
	host._selection_context = next_selection_context
	var build_started_usec := Time.get_ticks_usec()
	var patch = host._inspector_view_model.build_live_patch(
		host._selected_cell,
		tab_id,
		true,
		revision.get("population_summary", {}),
		not population_list
	)
	timing["live_patch_build_ms"] = (
		Time.get_ticks_usec() - build_started_usec) / 1000.0
	if population_list:
		var next_category_hash := 0
		if patch.has("category"):
			next_category_hash = hash(patch["category"])
		var same_target = host._live_revision_valid \
			and host._live_revision_cell == int(host._selected_cell.index) \
			and host._live_revision_tab == tab_id
		if same_target and next_category_hash == host._live_category_hash:
			patch.erase("category")
		else:
			host._live_category_hash = next_category_hash
		host._live_revision_cell = int(host._selected_cell.index)
		host._live_revision_tab = tab_id
		host._live_common_hash = int(revision.get("common_hash", 0))
		host._live_category_generation = int(revision.get("category_generation", -1))
		host._live_tax_policy_version = int(revision.get("tax_policy_version", -1))
		host._live_revision_valid = true
	var apply_started_usec := Time.get_ticks_usec()
	host._right_panel.apply_live_patch(patch)
	host._refresh_object_detail(force or not population_list)
	timing["live_patch_apply_ms"] = (
		Time.get_ticks_usec() - apply_started_usec) / 1000.0
	timing["ran"] = true
	host._report_inspector_daily_timing(timing, _t_all)
	return timing

func refresh_selected_panel(host) -> void:
	if host._selected_cell == null or host._inspector_view_model == null or host._right_panel == null:
		return
	host._invalidate_live_revision()
	host._right_panel.set_model_for_selection(host._inspector_view_model.build(host._selected_cell))
	host._selection_context = host._revision_selection_context(
		host._inspector_view_model.live_patch_revision(
			host._selected_cell, host._right_panel.current_tab()))
	host._refresh_object_detail(true)

func _revision_selection_context(host, revision: Dictionary) -> String:
	return "%s|%s" % [
		String(revision.get("selection_context", "")),
		String(revision.get("tabs_signature", "")),
	]

func open_military_dossier(host, kind: String, id: int, cell: int = -1) -> bool:
	if host._right_panel == null or host._player_controller == null or kind.is_empty() or id == 0:
		return false
	if kind == "army" and cell < 0 and host._player_controller.has_method("military_army_cell"):
		cell = int(host._player_controller.call("military_army_cell", id))
	var payload = host._military_dossier_payload(kind, id, cell)
	if payload.is_empty():
		return false
	# 重选同一支部队保留档案、滚动位置和选点草稿；关闭交给 × / Esc。
	if host._right_panel.military_dossier_open() \
			and host._right_panel.military_dossier_identity() == String(payload.get("identity", "")):
		if kind != "army":
			host.close_military_dossier()
		return true
	host._player_controller.cancel_military_arm_order()
	var was_visible = host._right_panel.visible
	UIAnimation.cancel(host._right_panel)
	host._military_dossier_context = {"kind": kind, "id": id, "cell": cell}
	host._last_military_dossier_ms = Time.get_ticks_msec()
	host._military_dossier_pending = false
	host._right_panel.set_directory_available(kind != "army" and host._selected_cell != null)
	# 只开军务档案、没有地块档案时，面板本身也要出现。
	if not host._right_panel.visible:
		host._right_panel.visible = true
	host._right_panel.show_military_dossier(payload)
	host._layout_right_panel()
	UIAnimation.refresh_rest_position(host._right_panel)
	if not was_visible:
		UIAnimation.fade_slide_in(host._right_panel, Vector2(24.0, 0.0), UITokens.ANIM_MED)
	host.update_military_arm_order(host._player_controller.military_arm_order())
	var focus := int(payload.get("focus_cell", -1))
	if focus >= 0 and host._player_controller.has_method("focus_cell"):
		host._player_controller.call("focus_cell", focus)
	return true

func close_military_dossier(host) -> void:
	var was_open = host._right_panel != null and host._right_panel.military_dossier_open()
	# 每次点格都会走到这里：什么都没开时直接返回，别为一次选格多付一次原生调用。
	if not was_open and host._military_dossier_context.is_empty():
		return
	if host._player_controller != null:
		host._player_controller.cancel_military_arm_order()
	host._military_dossier_context.clear()
	host._military_dossier_pending = false
	if host._right_panel != null:
		host._right_panel.set_directory_available(true)
		if was_open:
			host._right_panel.close_detail(false)
	if host._player_controller != null \
			and host._player_controller.has_method("clear_military_map_selection"):
		host._player_controller.call("clear_military_map_selection")
	# 没有地块档案可回落时，面板本身也该收起。
	if was_open and host._selected_cell == null:
		host.hide_cell_panel()

func military_dossier_open(host) -> bool:
	return host._right_panel != null and host._right_panel.military_dossier_open()

func _military_dossier_payload(host, kind: String, id: int, cell: int = -1) -> Dictionary:
	var vm = host._military_view_model()
	if vm == null:
		return {}
	if kind == "army":
		var same_cell: Array = []
		# 行军后同格名录跟随部队当前位置，不继续展示开页时的旧驻地。
		if host._player_controller.has_method("military_army_cell"):
			var current_cell := int(host._player_controller.call("military_army_cell", id))
			if current_cell >= 0:
				cell = current_cell
		if cell >= 0 and host._player_controller != null \
				and host._player_controller.has_method("military_armies_at_cell"):
			same_cell = host._player_controller.call("military_armies_at_cell", cell)
		return vm.army_dossier(id, same_cell)
	if kind == "front":
		if host._player_controller == null \
				or not host._player_controller.has_method("military_front_sector"):
			return {}
		var sector: Dictionary = host._player_controller.call("military_front_sector", id)
		if sector.is_empty():
			return {}
		return vm.front_dossier(sector)
	return {}


## 每次开页/刷新建一个 view model：configure 只拷字典，真正的查询在
## build_military_model（O(armies)，走 200ms 合并窗口）与 facade.army（单支部队）。

func _military_view_model(host) -> MilitaryViewModel:
	if host._country_view_model == null or host._player_controller == null:
		return null
	var handle := int(host._player_controller.get_player_country_handle())
	if handle == 0:
		return null
	var context: Dictionary = host._country_view_model.military_dossier_context(handle)
	context["current_day"] = int(host._world_clock.day_index()) if host._world_clock != null else -1
	context["player_controller"] = host._player_controller
	var vm = MilitaryViewModel.new()
	vm.configure(context)
	if not vm.available():
		return null
	return vm

func _refresh_military_dossier(host, force: bool = false) -> void:
	if host._military_dossier_context.is_empty() or host._right_panel == null \
			or not host._right_panel.military_dossier_open():
		return
	var now := Time.get_ticks_msec()
	if not force and now - host._last_military_dossier_ms < host.MILITARY_DOSSIER_REFRESH_INTERVAL_MSEC:
		host._military_dossier_pending = true
		host._arm_military_dossier_timer()
		return
	host._last_military_dossier_ms = now
	host._military_dossier_pending = false
	var payload = host._military_dossier_payload(
		String(host._military_dossier_context.get("kind", "")),
		int(host._military_dossier_context.get("id", 0)),
		int(host._military_dossier_context.get("cell", -1)))
	if payload.is_empty():
		host.close_military_dossier()
		return
	host._right_panel.refresh_military_dossier(payload)

func set_resource_discovery_context(host, technology_ids: PackedStringArray,
	enforce_discovery: bool = false) -> void:
	if host._map_overlay_toolbar != null:
		host._map_overlay_toolbar.set_resource_discovery_context(
			technology_ids, enforce_discovery)

func _refresh_player_discovery_context(host) -> void:
	if host._country_view_model == null:
		return
	var technology_ids: PackedStringArray = \
		host._country_view_model.player_completed_technology_ids()
	if technology_ids.is_empty():
		return
	if host._discovery_tech_ids_ready and technology_ids == host._last_discovery_tech_ids:
		return
	host._last_discovery_tech_ids = technology_ids.duplicate()
	host._discovery_tech_ids_ready = true
	host.set_resource_discovery_context(technology_ids, true)


func notify_committed_day(host) -> void:
	host._queue_era_indicator_refresh()
	# 年度产值账本必须在面板关闭时也继续累计，否则中途打开会缺少年初到此刻的流量。
	# sample() 自带 sample_day 去重与墙钟合流，重复调用无额外开销。
	var committed_day := int(host._world_clock.day_index()) if host._world_clock != null else -1
	host._gdp_ledger.sample(committed_day)
	# 国库收支序列与产值账本同一节拍：面板关闭时也要连续，否则中途打开只有一点。
	if host._country_view_model != null:
		host._country_view_model.sample_fiscal_history(committed_day)
	if host._country_panel != null and host._country_panel.is_panel_open() \
			and host._country_panel.current_section() == "economy":
		host._mark_country_panel_dirty(host.COUNTRY_DIRTY_ECONOMY, "economy_day")
	# Ideology points accrue daily and, under worker authority, arrive through
	# snapshot write-back without a command receipt. Invalidate the cached
	# section every day so reopening never shows a stale point scroll.
	elif host._country_panel != null and host._country_panel.is_panel_open() \
		and host._country_panel.current_section() == "politics":
		host._mark_country_panel_dirty(host.COUNTRY_DIRTY_POLITICS, "politics_day")
	# 军事快照每日变化（兵力、士气、补给天数、战争分），打开时同样每个已提交日
	# 推进一次；节流仍由 _flush_country_panel_refresh 的墙钟窗口负责。
	elif host._country_panel != null and host._country_panel.is_panel_open() \
			and host._country_panel.current_section() == "military":
		host._mark_country_panel_dirty(host.COUNTRY_DIRTY_MILITARY, "military_day")
	# 外交读的是战争与领地，两者每天都可能变；同样每个已提交日推进一次。
	elif host._country_panel != null and host._country_panel.is_panel_open() \
			and host._country_panel.current_section() == "diplomacy":
		host._mark_country_panel_dirty(host.COUNTRY_DIRTY_DIPLOMACY, "diplomacy_day")
	elif host._country_view_model != null:
		host._country_view_model.invalidate_cache(host.COUNTRY_DIRTY_POLITICS)
	# 军务档案也随已提交日推进；合并窗口由 _refresh_military_dossier 负责。
	host._refresh_military_dossier()
	# 营造窗口开着时，国库现金、市场库存与仓库每天都会变；节流由这里负责。
	host._refresh_building_workspace()
	# 议和窗口开着时，战争分/占领格/对方意愿每天都会变，跟着已提交日重建一次。
	host._refresh_peace_window()


func _country_section_mask(host, section_id: String) -> int:
	match section_id:
		"economy":
			return host.COUNTRY_DIRTY_ECONOMY
		"politics", "ideology":
			return host.COUNTRY_DIRTY_POLITICS
		"military":
			return host.COUNTRY_DIRTY_MILITARY
		"diplomacy":
			return host.COUNTRY_DIRTY_DIPLOMACY
		_:
			return host.COUNTRY_DIRTY_TECHNOLOGY


func _set_inspector_trace_cell(host, cell_idx: int) -> void:
	if host._inspector_view_model == null:
		return
	host._inspector_view_model.set_inspector_trace_cell(cell_idx)


func _poll_research_completion_toasts(host) -> Dictionary:
	var result := {"states_changed": false, "completed": false}
	if host._country_view_model == null:
		return result
	host._ensure_research_toast()
	if host._research_toast == null:
		return result
	var states: PackedInt32Array = host._country_view_model.player_research_states()
	if states.is_empty():
		return result
	if not host._research_toast_bootstrapped:
		host._last_research_toast_states = states.duplicate()
		host._research_toast_bootstrapped = true
		return result
	var previous = host._last_research_toast_states
	if previous == states:
		return result
	result["states_changed"] = true
	var definitions: Array = host.TechnologyCatalogScript.public_definitions()
	var limit := mini(states.size(), definitions.size())
	for index in range(limit):
		var next_state := int(states[index])
		var prev_state := int(previous[index]) if index < previous.size() else 0
		# State 4 = research complete, pending Effect activation ("明日生效").
		# State 5 = already owned. Toast on the pending edge so the copy matches.
		if prev_state >= 4 or next_state < 4:
			continue
		var definition: Dictionary = definitions[index]
		if bool(definition.get("is_application", false)) \
				or String(definition.get("id", "")).begins_with("app."):
			continue
		host._research_toast.show_research_completed(String(definition.get(
			"display_name", definition.get("id", ""))))
		result["completed"] = true
	host._last_research_toast_states = states.duplicate()
	if bool(result["completed"]):
		host._play_progression_cue(&"tech_research")
	return result


func _hover_blocked(host) -> bool:
	var situations = host.get_node_or_null("UIRoot/HUDLayer/CellSituationLayer")
	if situations != null and situations.is_icon_hovered():
		return true
	if host._map == null or host._inspector_view_model == null or host._player_camera == null:
		return true
	if host._loading_overlay != null and host._loading_overlay.visible:
		return true
	if host._right_panel != null and host._right_panel.visible:
		return true
	if host._country_panel != null and host._country_panel.is_panel_open():
		return true
	if host._pause_menu != null and host._pause_menu.visible:
		return true
	if host.is_era_reward_modal_open() or host.is_family_founding_modal_open() or host.is_narrative_event_modal_open():
		return true
	if host.is_era_panel_open() or host.is_era_ceremony_playing():
		return true
	if host._colonization_panel != null and host._colonization_panel.visible:
		return true
	if bool(host._colonization_targeting.get("active", false)):
		return true
	if host.is_peace_window_open():
		return true
	if host._gm_console != null and host._gm_console.is_panel_open():
		return true
	return false


func show_transient_message(host, text: String) -> void:
	if host._right_panel != null and host._right_panel.has_method("set_military_dossier_feedback"):
		host._right_panel.set_military_dossier_feedback(text, false)


## Inspector 军事页签的官营建筑入口：翻成正式命令交给 PlayerController。
## 请求里的 `building` 已经是军事目录里的 dense 建筑序（由视图模型按科技闸门解析），
## 所以这里原样透传，不再把角色名当建筑名送过去。


func apply_country_commit(host, report: Dictionary) -> void:
	host._queue_era_indicator_refresh()
	# 税务/国库 soft-commit 每天都会推 generation，但通常 0 格领土变更。
	# 以前这里无条件 COUNTRY_DIRTY_ALL + 全量科技定义重建，把 50x 主线程打到 ~90ms。
	var territory_changed := int(report.get("changed_cells", 0)) > 0
	var dirty_families := int(report.get("dirty_families", 0))
	var state_dirty = (dirty_families & host.NATIVE_DIRTY_COUNTRY_STATE) != 0 \
		or int(report.get("research_watermark", 0)) > 0 \
		or int(report.get("tax_watermark", 0)) > 0
	# 领土变更会改 fog_state，必须强制重建 Inspector；软提交走既有墙钟节流。
	host.refresh_selected_daily_lines(territory_changed)
	if territory_changed and host._selected_cell != null:
		host.refresh_selected_panel()
	var domains = 0
	if territory_changed or state_dirty \
			or (dirty_families & host.NATIVE_DIRTY_COUNTRY_TERRITORY) != 0:
		domains |= host.COUNTRY_DIRTY_ECONOMY
	if state_dirty:
		domains |= host.COUNTRY_DIRTY_POLITICS
	# 归属变了，「已发现国家」清单、接壤面数与占领格都会变；外交页必须同一瞬间重算，
	# 否则名录会停在上一张地图上。
	if territory_changed or (dirty_families & host.NATIVE_DIRTY_COUNTRY_TERRITORY) != 0:
		domains |= host.COUNTRY_DIRTY_DIPLOMACY
	# A worker country commit can advance the published country generation while
	# leaving the legacy dirty-family bits empty.  The technology archive reads
	# that committed research snapshot, so while it is open it must observe every
	# committed country boundary; otherwise the old cached model survives until a
	# technology click forces a direct live snapshot.  Closed or other sections
	# only invalidate the cached technology model (no build), so reopening never
	# presents a model from before the panel was closed.
	var research_committed = int(report.get("generation", report.get("country_generation", 0))) > 0 \
			or int(report.get("changed_countries", 0)) > 0 \
			or state_dirty
	if research_committed:
		domains |= host.COUNTRY_DIRTY_TECHNOLOGY
	var research_poll := {"states_changed": false, "completed": false}
	if research_committed:
		var now_ms := Time.get_ticks_msec()
		if now_ms >= host._next_research_toast_poll_ms:
			host._next_research_toast_poll_ms = now_ms + host.RESEARCH_TOAST_POLL_INTERVAL_MSEC
			research_poll = host._poll_research_completion_toasts()
	if bool(research_poll.get("states_changed", false)):
		domains |= host.COUNTRY_DIRTY_TECHNOLOGY
	elif state_dirty and host._country_panel != null and host._country_panel.is_panel_open() \
			and String(host._country_panel.current_section()) == "technology" \
			and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		# Progress-only refresh while the archive is open. Never rebuild during
		# an active click — 50x soft-commits were eating double-click enqueue.
		var progress_now_ms := Time.get_ticks_msec()
		if progress_now_ms >= host._next_tech_panel_progress_ms:
			host._next_tech_panel_progress_ms = progress_now_ms + \
				host.RESEARCH_PANEL_PROGRESS_INTERVAL_MSEC
			domains |= host.COUNTRY_DIRTY_TECHNOLOGY
	if (dirty_families & host.NATIVE_DIRTY_COUNTRY_VISUAL_ERA) != 0:
		domains |= host.COUNTRY_DIRTY_POLITICS
	if domains == 0:
		domains = host.COUNTRY_DIRTY_ECONOMY
	host._mark_country_panel_dirty(domains, "country_committed")
	if bool(research_poll.get("completed", false)):
		host._refresh_player_discovery_context()


## economy_chapter 非空时直接落到经济卷宗的指定章节（总览 / 阶层民生），
## 顶栏纸签点击走这条路；其它调用方保持原来的「记住上次章节」行为。


func apply_country_research_signal(host, _event: Dictionary) -> void:
	host._mark_country_panel_dirty(host.COUNTRY_DIRTY_TECHNOLOGY, "research_signal")


func apply_economy_event_batch(host, _meta: Dictionary) -> void:
	host._queue_era_indicator_refresh()
	if host._country_view_model != null:
		host._country_view_model.sample_economy_history()
	var domains = host.COUNTRY_DIRTY_ECONOMY
	# Treasury cash and development objectives on the research page are fed by
	# economy commits even on days when no country commit arrives.
	if host._country_panel != null and host._country_panel.is_panel_open() \
			and host._country_panel.current_section() == "technology":
		var now := Time.get_ticks_msec()
		if now >= host._next_tech_economy_refresh_ms:
			host._next_tech_economy_refresh_ms = now + host.TECH_ECONOMY_REFRESH_INTERVAL_MSEC
			domains |= host.COUNTRY_DIRTY_TECHNOLOGY
	host._mark_country_panel_dirty(domains, "economy_commit")


## 经济事件批次只在有事件的日子发布，开局常连续数日没有；经济卷宗打开时
## 每个已提交日都要推进一次，否则数据停在打开那天。刷新仍走墙钟节流。


func apply_ideology_settled(host, _result: Dictionary) -> void:
	host._mark_country_panel_dirty(host.COUNTRY_DIRTY_POLITICS, "ideology_commit")


## 军事命令的下一个游戏日才生效，所以只在日推进时刷新；这里额外在玩家刚下达
## 命令后请求一次，让「已排队」的反馈和面板数值同步。


func apply_military_command_settled(host, _id: StringName, _result: Dictionary) -> void:
	host._mark_country_panel_dirty(host.COUNTRY_DIRTY_MILITARY, "military_commit")
	# 宣战/议和在军事运行时里落地，外交页的战事与关系必须在同一天跟上。
	host._mark_country_panel_dirty(host.COUNTRY_DIRTY_DIPLOMACY, "military_commit")
	host._refresh_peace_window()


## 行军预览失败等原因的玩家侧回显。PlayerController 只持有 manager 引用，
## 不知道右栏是否正在显示军务档案，所以这里做一次存在性转发。
