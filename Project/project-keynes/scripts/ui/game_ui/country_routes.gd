extends RefCounted

const SelectedCellRoutes = preload("res://scripts/ui/game_ui/selected_cell_routes.gd")

const ColonizationRoutes = preload("res://scripts/ui/game_ui/colonization_routes.gd")
const MilitaryPeaceRoutes = preload("res://scripts/ui/game_ui/military_peace_routes.gd")

# G5 collaborator. The host owns all mutable state; it is passed per call.

func _locate_cell_from_family_founding(host, cell_index: int) -> void:
	ColonizationRoutes._locate_cell_from_family_founding(host, cell_index)


func _on_founding_collapsed_changed(host, collapsed: bool) -> void:
	ColonizationRoutes._on_founding_collapsed_changed(host, collapsed)


func _cancel_colonization_targeting(host) -> void:
	ColonizationRoutes._cancel_colonization_targeting(host)


func _on_colonization_planning_context(host, context: Dictionary) -> void:
	ColonizationRoutes._on_colonization_planning_context(host, context)


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
	# 卷宗关掉这一刻才允许静置的叙事弹窗出现。
	host.notify_workspace_closed()



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

## 折叠卡的展开/收起：切换视图模型里的展开状态，再让窗口按它记着的
## 部门/搜索/排序/偏移重发同一页。展开只是多出几行，不触发任何模拟。
func _on_construction_fold_action_requested(host, action: Dictionary) -> void:
	if host._inspector_view_model == null or host._right_panel == null:
		return
	if not host._inspector_view_model.toggle_construction_fold(action):
		return
	host._last_construction_refresh_ms = Time.get_ticks_msec()
	host._right_panel.request_construction_refresh()


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
	ColonizationRoutes._open_colonization_target(host, target_cell, family_handle, source_cell)


func _open_dispatch_progress(host) -> void:
	ColonizationRoutes._open_dispatch_progress(host)


func _refresh_dispatch_status(host) -> void:
	ColonizationRoutes._refresh_dispatch_status(host)


func _on_colonization_requested(host, request: Dictionary) -> void:
	ColonizationRoutes._on_colonization_requested(host, request)


func _on_family_colonization_requested(host, family_handle: int,
		source_cell: int) -> void:
	ColonizationRoutes._on_family_colonization_requested(host, family_handle, source_cell)


func _suppress_ui_for_dispatch(host) -> void:
	ColonizationRoutes._suppress_ui_for_dispatch(host)


func _on_dispatch_closed(host) -> void:
	ColonizationRoutes._on_dispatch_closed(host)


# ── peace window (MilitaryPeaceWindow) ──────────────────────────────────

## Open the dedicated peace window for one war. The country shell is full-bleed,
## so it has to close first — the whole point of this window is the map behind it.

func open_military_peace(host, war_id: int) -> void:
	MilitaryPeaceRoutes.open_military_peace(host, war_id)



func close_military_peace(host) -> void:
	MilitaryPeaceRoutes.close_military_peace(host)



func is_peace_window_open(host) -> bool:
	return MilitaryPeaceRoutes.is_peace_window_open(host)


## Map click entry: true means the window consumed it (a cession toggle or a
## "you cannot cede this" note), false only when no window is open.

func handle_peace_map_cell(host, cell: int) -> bool:
	return MilitaryPeaceRoutes.handle_peace_map_cell(host, cell)
func _peace_focus_cell(host) -> int:
	return MilitaryPeaceRoutes._peace_focus_cell(host)



func _on_peace_window_closed(host) -> void:
	MilitaryPeaceRoutes._on_peace_window_closed(host)



func _on_peace_submit_requested(host, payload: Dictionary) -> void:
	MilitaryPeaceRoutes._on_peace_submit_requested(host, payload)



func _on_peace_locate_requested(host, cell: int) -> void:
	MilitaryPeaceRoutes._on_peace_locate_requested(host, cell)



func _refresh_peace_window(host) -> void:
	MilitaryPeaceRoutes._refresh_peace_window(host)



func _on_colonization_start_requested(host, args: Dictionary) -> void:
	ColonizationRoutes._on_colonization_start_requested(host, args)


func _on_colonization_cancel_requested(host, expedition_handle: int) -> void:
	ColonizationRoutes._on_colonization_cancel_requested(host, expedition_handle)


func _on_expedition_selected(host, expedition_handle: int) -> void:
	ColonizationRoutes._on_expedition_selected(host, expedition_handle)


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
	if id in [&"era.advance.start", &"era.advance.pause", &"era.advance.resume"]:
		if host._era_panel != null:
			host._era_panel.show_command_result(result)
		return
	if String(id).begins_with("country.tax.cell."):
		if not bool(result.get("ok", false)) and host._right_panel != null:
			host._right_panel.show_tax_rejection(result)
		return
	if String(id).begins_with("military."):
		host._on_military_command_settled(id, result)
		return
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
	SelectedCellRoutes._invalidate_live_revision(host)


func _on_object_details_requested(host, request: Dictionary) -> void:
	SelectedCellRoutes._on_object_details_requested(host, request)


func _close_object_detail_dialog(host) -> void:
	SelectedCellRoutes._close_object_detail_dialog(host)


func _refresh_object_detail(host, force: bool = false) -> void:
	SelectedCellRoutes._refresh_object_detail(host, force)


func set_world_context(host, map: MapData,
		generator: MapGenerator,
		view_adapter: DCViewAdapter,
		world_clock: WorldClock,
		sea_level: float,
		hex_size: float) -> void:
	SelectedCellRoutes.set_world_context(host, map, generator, view_adapter, world_clock, sea_level, hex_size)


func _sync_military_map_toolbar(host) -> void:
	SelectedCellRoutes._sync_military_map_toolbar(host)


func _report_inspector_daily_timing(host, timing: Dictionary, started_usec: int) -> void:
	SelectedCellRoutes._report_inspector_daily_timing(host, timing, started_usec)


func refresh_selected_daily_lines(host, force: bool = false, day_idx: int = -1) -> Dictionary:
	return SelectedCellRoutes.refresh_selected_daily_lines(host, force, day_idx)


func refresh_selected_panel(host) -> void:
	SelectedCellRoutes.refresh_selected_panel(host)


func _revision_selection_context(host, revision: Dictionary) -> String:
	return SelectedCellRoutes._revision_selection_context(host, revision)


func open_military_dossier(host, kind: String, id: int, cell: int = -1) -> bool:
	return SelectedCellRoutes.open_military_dossier(host, kind, id, cell)


func close_military_dossier(host) -> void:
	SelectedCellRoutes.close_military_dossier(host)


func military_dossier_open(host) -> bool:
	return SelectedCellRoutes.military_dossier_open(host)


func _military_dossier_payload(host, kind: String, id: int, cell: int = -1) -> Dictionary:
	return SelectedCellRoutes._military_dossier_payload(host, kind, id, cell)


func _military_view_model(host) -> MilitaryViewModel:
	return SelectedCellRoutes._military_view_model(host)


func _refresh_military_dossier(host, force: bool = false) -> void:
	SelectedCellRoutes._refresh_military_dossier(host, force)


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
	SelectedCellRoutes.apply_country_commit(host, report)


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




## 行军预览失败等原因的玩家侧回显。PlayerController 只持有 manager 引用，
## 不知道右栏是否正在显示军务档案，所以这里做一次存在性转发。
