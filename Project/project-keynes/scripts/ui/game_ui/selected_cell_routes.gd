extends RefCounted

## Refreshes selected cell, object, and army detail from committed state.




static func _invalidate_live_revision(host) -> void:
	host._live_revision_cell = -1
	host._live_revision_tab = ""
	host._live_common_hash = 0
	host._live_category_generation = -1
	host._live_tax_policy_version = -1
	host._live_category_hash = 0
	host._live_revision_valid = false



static func _on_object_details_requested(host, request: Dictionary) -> void:
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



static func _close_object_detail_dialog(host) -> void:
	host._pending_object_request.clear()
	host._object_detail_context = {}
	if host._right_panel != null:
		host._right_panel.close_detail(false)
		host.call_deferred("_layout_right_panel")



static func _refresh_object_detail(host, force: bool = false) -> void:
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



static func set_world_context(host, map: MapData,
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

static func _sync_military_map_toolbar(host) -> void:
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

static func _report_inspector_daily_timing(host, timing: Dictionary, started_usec: int) -> void:
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

static func refresh_selected_daily_lines(host, force: bool = false, day_idx: int = -1) -> Dictionary:
	var _t_all := Time.get_ticks_usec()
	var timing: Dictionary = {
		"ran": false,
		"tab": "",
		"live_patch_build_ms": 0.0,
		"live_patch_apply_ms": 0.0,
	}
	if host._selected_cell == null or host._inspector_view_model == null or host._right_panel == null:
		host._report_inspector_daily_timing(timing, _t_all)
		return timing
	# 视野状态变了意味着页签集合变了，打补丁改不动页签栏，必须整块重建。
	var fog := VisionSolver.displayed_fog_state(host._map, int(host._selected_cell.index))
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

static func refresh_selected_panel(host) -> void:
	if host._selected_cell == null or host._inspector_view_model == null or host._right_panel == null:
		return
	host._invalidate_live_revision()
	host._right_panel.set_model_for_selection(host._inspector_view_model.build(host._selected_cell))
	host._selection_context = host._revision_selection_context(
		host._inspector_view_model.live_patch_revision(
			host._selected_cell, host._right_panel.current_tab()))
	host._refresh_object_detail(true)

static func _revision_selection_context(host, revision: Dictionary) -> String:
	return "%s|%s" % [
		String(revision.get("selection_context", "")),
		String(revision.get("tabs_signature", "")),
	]

static func open_military_dossier(host, kind: String, id: int, cell: int = -1) -> bool:
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

static func close_military_dossier(host) -> void:
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

static func military_dossier_open(host) -> bool:
	return host._right_panel != null and host._right_panel.military_dossier_open()

static func _military_dossier_payload(host, kind: String, id: int, cell: int = -1) -> Dictionary:
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

static func _military_view_model(host) -> MilitaryViewModel:
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

static func _refresh_military_dossier(host, force: bool = false) -> void:
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


static func apply_country_commit(host, report: Dictionary) -> void:
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
