extends RefCounted

## Passive visual/vision adapter. Host owns state and signals.

func _bind_renderer_and_camera(host, safe_area: Rect2) -> void:
	if host._renderer == null or host._current_map == null or host._world_data == null:
		return
	# A headless session owns the same simulation authorities but has no valid
	# texture-array backend. Rebinding a restored world used to instantiate all
	# vegetation layers against DummyTexture, emit hundreds of null-image
	# failures and eventually crash before the first post-restore economy day.
	# Keep country/research event ingress alive without constructing visual state.
	if DisplayServer.get_name() == "headless":
		host._fog_of_war_enabled = _resolve_fog_of_war_enabled(host, )
		host._player_country_slot = _resolve_player_country_slot(host, )
		host._player_country_handle = _resolve_player_country_handle(host, )
		_connect_country_committed(host, )
		# Keep monotonic exploration and discovery ingress identical to a visual
		# session. Only texture/LUT/border publication is omitted.
		host._loading_visual_step("_refresh_vision()")
		_refresh_vision(host, )
		return
	host._renderer.hex_size = host.hex_size
	var ext = host._generator.get_data_core_world_ext() if host._generator != null and host._generator.has_method("get_data_core_world_ext") else null
	if ext != null and host._renderer.has_method("set_world_ext"):
		host._renderer.set_world_ext(ext)
	host._loading_visual_step("_renderer.set_map(_current_map, _world_data)")
	# 植被层构建（set_map_cooperative → _rebuild_cooperative）在这里面跑 14+ 层，
	# 逐层回调转成本次加载的进度（stage="visual"）。只在加载边界连接/断开，
	# 运行期重建不会误发进度。
	var layer_progress = Callable(host, "_on_renderer_loading_layer_progress")
	if not host._renderer.loading_layer_progress.is_connected(layer_progress):
		host._renderer.loading_layer_progress.connect(layer_progress)
	await host._renderer.set_map_cooperative(host._current_map, host._world_data)
	if not host._session_preparation_active():
		return
	if host._renderer.loading_layer_progress.is_connected(layer_progress):
		host._renderer.loading_layer_progress.disconnect(layer_progress)
	if host._map_overlay_layer != null:
		host._map_overlay_layer.set_bounds(host._renderer.get_world_bounds())
		host._map_overlay_layer.set_horizontal_wrap(host.map_wrap_period_x())
		host._map_overlay_layer.configure_visual_tiles(host._world_data.visual_tiles)
		host._map_overlay_layer.configure_cell_lut(
			host._world_data.enum_atlas_tex,
			host._world_data.lut_dims
		)
	if host._renderer.has_method("set_map_baker") and host._generator != null and "_baker" in host._generator:
		host._loading_visual_step("_renderer.set_map_baker(_generator._baker)")
		host._renderer.set_map_baker(host._generator._baker)
	host._loading_visual_step("_bind_country_visuals()")
	await host._session_frames.next_frame()
	if not host._session_preparation_active():
		return
	WebTelemetry.emit("bind_step", {"s": "pre_bind_country"})
	_bind_country_visuals(host, )
	WebTelemetry.emit("bind_step", {"s": "post_bind_country"})
	# ---- Military layers
	# Created after the world/renderer bind, configured by PlayerGame on
	# world_ready (map/camera/clock are all valid there).
	if host.military_map_layers == null and not OS.has_feature("mobile") and DisplayServer.get_name() != "headless":
		var military_script = load("res://scripts/rendering/military_map_layers.gd") as Script
		if military_script != null:
			host.military_map_layers = Node2D.new()
			host.military_map_layers.name = "MilitaryMapLayers"
			host.military_map_layers.set_script(military_script)
			host.add_child(host.military_map_layers)
	# ---- Military layers
	if host._world_clock != null:
		WebTelemetry.emit("bind_step", {"s": "set_season_phase"})
		host._renderer.set_season_phase(host._world_clock.season_phase())
		WebTelemetry.emit("bind_step", {"s": "set_climate_anomaly"})
		host._renderer.set_climate_anomaly(host._world_clock.climate_anomaly)
		WebTelemetry.emit("bind_step", {"s": "on_visual_day_phase_changed"})
		host.on_visual_day_phase_changed(host._world_clock.visual_day_phase)
		var cp = host._generator._c() if host._generator != null and host._generator.has_method("_c") else null
		if cp != null and cp.daily_climate_interpolation:
			# Web：这是「进世界前的气候 prewarm」，浏览器里实测 60s+
			# （async climate round 收不了尾，只能等超时）。它只影响第一帧的气候场，
			# 进世界后的第一个 daily tick 会算出同样的东西 —— 所以 web 跳过，
			# 别把 60 秒塞进加载条。
			if OS.has_feature("web"):
				print("[loading] web build: skip initial refresh_climate_loading (60s+ in browser; first daily tick recomputes it)")
			else:
				host._loading_visual_step("_generator.refresh_climate_daily(_current_map, _world_clock.season_phase())")
				await host._generator.refresh_climate_loading(host._current_map, host._world_clock.season_phase())
	WebTelemetry.emit("bind_step", {"s": "before_camera_frame"})
	await host._session_frames.next_frame()
	if not host._session_preparation_active():
		return
	WebTelemetry.emit("bind_step", {"s": "camera_bounds"})
	if host._camera != null:
		host._camera.set_world_bounds(host._renderer.get_world_bounds())
		WebTelemetry.emit("bind_step", {"s": "after_world_bounds"})
		if host._camera.has_method("set_horizontal_wrap"):
			host._camera.set_horizontal_wrap(host.map_wrap_period_x(), true)
		WebTelemetry.emit("bind_step", {"s": "after_wrap"})
		host._camera.fit_to_viewport(1.0, safe_area, true)
		WebTelemetry.emit("bind_step", {"s": "after_fit"})
		host._renderer.set_camera_zoom(host._camera.zoom.x)
		WebTelemetry.emit("bind_step", {"s": "after_zoom"})
	# Web：定居点标签层是逐 cell 建 Label，实测加载期要 45s 量级（wasm 下 GDScript
	# 每 cell 开销被放大 10~50 倍）。它纯属观感层，改成进世界后再补。
	if OS.has_feature("web"):
		WebTelemetry.emit("bind_step", {"s": "settlement_labels_deferred"})
		_defer_settlement_labels_after_ready(host, )
	else:
		_bind_settlement_labels(host, )


## Web 专用：把定居点标签层推到进世界之后（逐 cell 建 Label 在 wasm 上 45s 量级）。

func _defer_settlement_labels_after_ready(host) -> void:
	if host._exiting_tree or not host.is_inside_tree():
		return
	if host.PK_WEB_SKIP_DEFERRED_VISUAL_LAYERS:
		return
	var session = host._runtime_session
	var token: int = session.generation
	var timer = host.get_tree().create_timer(4.0, true, false, true)
	await timer.timeout
	if host._exiting_tree or not host.is_inside_tree() or not session.is_current(token):
		return
	var started = Time.get_ticks_msec()
	_bind_settlement_labels(host, )
	var elapsed = Time.get_ticks_msec() - started
	print("[settlement-labels] web deferred bind %dms" % elapsed)
	WebTelemetry.emit("bind_step", {"s": "deferred_settlement_labels_done", "dur": elapsed})

func _bind_settlement_labels(host) -> void:
	host._bind_presentation_resources()
	host._presentation._bind_settlement_labels()


# ─── 国界线与视野迷雾 ─────────────────────────────────────────────────
# 两者共用同一个触发源：领土是国界的定义，也是视野的源头。
# country_committed 仅在真实领土 diff > 0 时挂起刷新；刷新本身走
# `_service_country_visual_refresh_budgeted`，不阻塞 ACTIVE day_changed。

## 世界就绪后一次性绑定。此刻 country bootstrap 已完成，country_slot_arr 已由
## NativeCountryRuntime 发布到 MapData，可以直接首解算。

func _bind_country_visuals(host) -> void:
	host._fog_of_war_enabled = _resolve_fog_of_war_enabled(host, )
	host._player_country_slot = _resolve_player_country_slot(host, )
	host._player_country_handle = _resolve_player_country_handle(host, )
	if host._renderer != null and host._renderer.has_method("set_fog_of_war_enabled"):
		host._renderer.set_fog_of_war_enabled(host._fog_of_war_enabled, host.fog_early_out_enabled)
	_connect_country_committed(host, )
	var report = refresh_country_visuals(host, "world_ready")
	var vision: Dictionary = report.get("vision", {})
	var border: Dictionary = report.get("border", {})
	print("[vision] fog=%s player_slot=%d early_out=%s visible=%d explored=%d/%d solve_ms=%.3f border_edges=%d" % [
		"ON" if host._fog_of_war_enabled else "OFF", host._player_country_slot,
		"ON" if host.fog_early_out_enabled else "OFF",
		int(vision.get("visible", 0)), int(vision.get("explored", 0)),
		int(vision.get("cells", 0)), float(vision.get("elapsed_ms", 0.0)),
		int(border.get("edges", 0))])


func _connect_country_committed(host) -> void:
	var facade = host._generator.get_country_facade() if host._generator != null \
		and host._generator.has_method("get_country_facade") else null
	if facade == null or not facade.has_signal("country_committed"):
		return
	var callback = Callable(host, "_on_country_committed")
	if not facade.country_committed.is_connected(callback):
		facade.country_committed.connect(callback)
	if facade.has_signal("research_signal_discovered"):
		var signal_callback = Callable(host, "_on_research_signal_discovered")
		if not facade.research_signal_discovered.is_connected(signal_callback):
			facade.research_signal_discovered.connect(signal_callback)


func _on_country_committed(host, report: Dictionary) -> void:
	if host._player_country_slot < 0:
		host._player_country_slot = _resolve_player_country_slot(host, )
	if int(report.get("changed_cells", 0)) > 0:
		# CLAIM may be published by the worker before the deferred visual refresh
		# pulse. Push the immutable territory snapshot immediately so MapData,
		# market-cell ownership and the border layer cannot observe the old owner.
		_sync_country_territory_to_map(host, )
		host._country_visual_refresh_pending = true
		host._country_visual_refresh_reason = "country_territory_committed"
		return
	var capability_now = _has_remote_observation_capability(host, )
	if capability_now != host._remote_observation_capability:
		host._remote_observation_capability = capability_now
		var vision = _refresh_vision(host, )
		_republish_cell_luts(host, host._vision_dirty_indices)

func _on_research_signal_discovered(host, event: Dictionary) -> void:
	if host._generator == null or not host._generator.has_method("get_gameplay_event_bus"):
		return
	var bus = host._generator.get_gameplay_event_bus()
	if bus == null:
		return
	bus.publish_event(GameplayEventBus.EVENT_RESEARCH_SIGNAL_DISCOVERED,
		int(event.get("cell", -1)), host._world_clock.day_index() if host._world_clock != null else 0,
		0, GameplayEventBus.SOURCE_GDSCRIPT, 0, GameplayEventBus.PAYLOAD_RESEARCH_SIGNAL_V1,
		int(event.get("signal", -1)), int(event.get("source_kind", 0)), 0,
		int(event.get("evidence_delta", 1)),
		int(event.get("country_handle", 0)), 1)


## 重算视野 → 把知识度推进 enum_lut.a → 重建国界 mesh。
## 返回诊断信息（GM 面板 / 测试用）。
## Web 长帧定位：refresh_country_visuals 的分段耗时。

func _cv_phase(host, name: String, started_usec: int) -> void:
	if not WebTelemetry.enabled():
		return
	var ms = host._sched_elapsed_ms(started_usec)
	if ms < 20.0:
		return
	WebTelemetry.emit("cv_phase", {"p": name, "dur": int(ms)})

func refresh_country_visuals(host, reason: String) -> Dictionary:
	var out = {"reason": reason, "vision": {}, "border": {}, "lut": {}}
	if host._current_map == null or host._world_data == null:
		return out
	# Native CLAIM 先写 NativeCountryRuntime，再经 DataCore CoW 镜像到 MapData。
	# 若 country_committed 抢在 flush 之前触发，视野会用旧 country_slot_arr 解算，
	# 国界/Inspector 随后看到新领土，邻格就只剩迷雾柔边「看起来亮了」。
	var _cv_t = Time.get_ticks_usec()
	out["territory_sync"] = _sync_country_territory_to_map(host, )
	_cv_phase(host, "territory_sync", _cv_t)
	if host._player_country_slot < 0:
		host._player_country_slot = _resolve_player_country_slot(host, )
	var previous_visible = host._current_map.visible_arr.duplicate()
	# 首解前 enum_lut.a 按全知 255 编码，而 fog_dirty_indices 是对内存里全 0 的
	# fog_k_arr 求差，只覆盖首都周边；首次发布必须全量重编码，否则其余格子保持全知。
	var first_fog_publish = not host._current_map.fog_solved
	var _cv_t2 = Time.get_ticks_usec()
	out["vision"] = _refresh_vision(host, )
	_cv_phase(host, "vision", _cv_t2)
	if not out["vision"].has("newly_visible_cells"):
		var changed = PackedInt32Array()
		var newly_visible = PackedInt32Array()
		var newly_hidden = PackedInt32Array()
		for cell in host._current_map.cell_count():
			var before: int = previous_visible[cell] \
				if cell < previous_visible.size() else 0
			var after: int = host._current_map.visible_arr[cell] \
				if cell < host._current_map.visible_arr.size() else 0
			if before == after:
				continue
			changed.append(cell)
			if after != 0:
				newly_visible.append(cell)
			else:
				newly_hidden.append(cell)
		out["vision"]["visibility_changed_cells"] = changed
		out["vision"]["newly_visible_cells"] = newly_visible
		out["vision"]["newly_hidden_cells"] = newly_hidden
		out["vision"]["vision_revision"] = host._current_map.vision_revision
	var _cv_t3 = Time.get_ticks_usec()
	out["lut"] = _republish_cell_luts(host, host._vision_dirty_indices, first_fog_publish)
	_cv_phase(host, "lut", _cv_t3)
	_refresh_resource_visual_context(host, )
	var _cv_t4 = Time.get_ticks_usec()
	out["building_intel"] = _refresh_building_visual_intel(host, out["vision"])
	_cv_phase(host, "building_intel", _cv_t4)
	var _cv_t5 = Time.get_ticks_usec()
	out["border"] = _refresh_country_borders(host, )
	_cv_phase(host, "borders", _cv_t5)
	if host._settlement_label_layer != null:
		host._settlement_label_layer.set_fog_enabled(host._fog_of_war_enabled)
		host._settlement_label_layer.mark_visibility_dirty()
	return out


func _refresh_resource_visual_context(host) -> void:
	if host._renderer == null or not host._renderer.has_method("set_resource_visual_context"):
		return
	host._renderer.set_resource_visual_context(host._fog_of_war_enabled, host._last_seed)


func _refresh_building_visual_intel(host, vision_report: Dictionary) -> Dictionary:
	host._bind_presentation_resources()
	return host._presentation._refresh_building_visual_intel(vision_report)


func player_country_slot(host) -> int:
	return host._player_country_slot


## PKFG is restored before the PlayerGame world_ready callback. Rebind the
## player identity only after all providers (including player_session) have
## restored, then solve and publish fog exactly once from the restored explored
## array and PKCN territory.
##
## Two invariants are enforced here, both learned from a real same-build load
## failure ("读档后无法绑定玩家国家，视野不可解算"), where the save itself and the
## PKCN country plane were perfectly valid:
##   * The regenerated world must be the world the save was taken on. The load
##     path re-runs the new-game start solver, so `gameplay_start_report().cell`
##     is only a fallback; the restored `player_context.start_cell` is the
##     authority. If the two disagree the loaded terrain/resources are not the
##     ones the PKCN territory was recorded against, and binding the player to
##     the re-selected cell of a different world is what made the gate fire.
##     Fail with the explicit `start_cell_drift` code instead.
##   * The MapData country mirror can be stale: PKCN's own publish flush is
##     silent (`write_i32_range` no-ops on a size mismatch while still reporting
##     `published_to_slot=true`). Sync once before reading the mirror so a
##     recoverable desync is not escalated into a load failure.

func finalize_save_restore_visuals(host) -> Dictionary:
	host._fog_of_war_enabled = _resolve_fog_of_war_enabled(host, )
	var territory_sync: Dictionary = _sync_country_territory_to_map(host, )
	host._player_country_slot = _resolve_player_country_slot(host, )
	host._player_country_handle = _resolve_player_country_handle(host, )
	if host._renderer != null and host._renderer.has_method("set_fog_of_war_enabled"):
		host._renderer.set_fog_of_war_enabled(
			host._fog_of_war_enabled, host.fog_early_out_enabled)
	var drift = _player_start_cell_drift(host, )
	if not drift.is_empty():
		push_warning("[save/restore] %s" % String(drift.get("detail", "")))
		return {"reason": "save_restore_finalized", "border": {}, "lut": {},
			"vision": {"ok": false, "code": "start_cell_drift",
				"reason": String(drift.get("message", "读档重建出的世界与存档世界不一致。")),
				"detail": String(drift.get("detail", ""))}}
	# 迷雾开着却绑不到玩家国家，说明 PKCN 领土或 player_context 没恢复成功。
	# 这种状态解算出来的视野是全黑的，继续跑还会被下一次自动存档写死，
	# 所以直接让读档失败，而不是交出一张「全部未探索」的地图。
	if host._fog_of_war_enabled and host._player_country_slot < 0:
		var start_cell = _resolve_player_start_cell(host, )
		var mirror_slot = -2
		if host._current_map != null and start_cell >= 0 \
				and start_cell < host._current_map.country_slot_arr.size():
			mirror_slot = int(host._current_map.country_slot_arr[start_cell])
		var native_summary = "{}"
		if host._generator != null and start_cell >= 0 \
				and host._generator.has_method("get_country_facade") \
				and host._generator.get_country_facade() != null:
			native_summary = JSON.stringify(
				host._generator.get_country_facade().cell_summary(start_cell))
		var unbound_detail = "start_cell=%d mirror_slot=%d saved_start_cell=%d territory_sync=%s native=%s" % [
			start_cell, mirror_slot, _saved_player_start_cell(host, ),
			JSON.stringify(territory_sync), native_summary]
		push_warning("[save/restore] player country unbound %s" % unbound_detail)
		return {"reason": "save_restore_finalized", "border": {}, "lut": {},
			"vision": {"ok": false, "reason": "读档后无法绑定玩家国家，视野不可解算。",
				"detail": unbound_detail}}
	return refresh_country_visuals(host, "save_restore_finalized")


## 存档里的玩家起始格。读档期间 `_pending_load_bundle.sections.player_context`
## 是解码后的权威来源（成功返回后才清空），`GameFlow.session()` 作为兜底。

func _saved_player_start_cell(host) -> int:
	var sections = host._pending_load_bundle.get("sections", {})
	if sections is Dictionary:
		var pending_context = (sections as Dictionary).get("player_context", {})
		if pending_context is Dictionary:
			var pending_cell = int((pending_context as Dictionary).get("start_cell", -1))
			if pending_cell >= 0:
				return pending_cell
	# 测试/无头工具里 host 可能还没入树，此时没有 GameFlow 可查。
	if not host.is_inside_tree():
		return -1
	var flow = host._game_flow_service()
	if flow != null and flow.has_method("session"):
		var session: Dictionary = flow.session()
		return int(session.get("start_cell", -1))
	return -1


## 读档时由「重建世界 + 新开局选点」重新算出的起始格（只是派生值，不是权威）。

func _report_player_start_cell(host) -> int:
	if host._generator == null or not host._generator.has_method("gameplay_start_report"):
		return -1
	var report: Dictionary = host._generator.gameplay_start_report()
	if not bool(report.get("ok", false)):
		return -1
	return int(report.get("cell", -1))


## 读档重建出来的世界是否就是存档所在的世界。
## 起始格是地图地形/资源/气候的派生结果，所以「重算起始格 ≠ 存档起始格」就是
## 「重建世界 ≠ 存档世界」的直接证据；继续读下去只会得到领土/地形互相矛盾的
## 世界，下一次自动存档还会把它写死。返回 {} 表示一致或无法判定。

func _player_start_cell_drift(host) -> Dictionary:
	if host._pending_load_bundle.is_empty():
		return {}
	var saved_cell = _saved_player_start_cell(host, )
	var computed_cell = _report_player_start_cell(host, )
	if saved_cell < 0 or computed_cell < 0 or saved_cell == computed_cell:
		return {}
	var config_seed = -1
	var base = host._new_game_config.get("base", {})
	if base is Dictionary:
		config_seed = int((base as Dictionary).get("initial_seed", -1))
	return {
		"message": "读档重建出的世界与存档世界不一致，无法恢复。",
		"detail": "saved_start_cell=%d computed_start_cell=%d map=%dx%d generated_seed=%d config_seed=%d" % [
			saved_cell, computed_cell,
			host._current_map.width if host._current_map != null else -1,
			host._current_map.height if host._current_map != null else -1,
			host._last_seed, config_seed],
	}


func is_fog_of_war_enabled(host) -> bool:
	return host._fog_of_war_enabled


## GM 与场景配置共用这一入口；开启请求仍受正式对局上下文门控。

func set_fog_of_war_enabled(host, enabled: bool) -> void:
	host.fog_of_war_enabled = enabled
	var previous_fog_enabled = host._fog_of_war_enabled
	host._fog_of_war_enabled = _resolve_fog_of_war_enabled(host, )
	if previous_fog_enabled != host._fog_of_war_enabled:
		host._building_visual_force_full_refresh = true
	if host._renderer != null and host._renderer.has_method("set_fog_of_war_enabled"):
		host._renderer.set_fog_of_war_enabled(host._fog_of_war_enabled, host.fog_early_out_enabled)
	if host._current_map != null and host._world_data != null:
		refresh_country_visuals(host, "gm_fog_toggle")


## 迷雾只在正式对局里生效。调试 / 沙盒路径（没有 gameplay start context，
## country.default 铺满全部陆地）保持全图可见，否则整张地图会被云盖死。

func _resolve_fog_of_war_enabled(host) -> bool:
	# ?fog=off（web_autotest 写入 Engine meta）只用于诊断/截图：关掉全部战争迷雾，
	# 让画面直接呈现"最高可用画质"。正常入口读不到这个 meta。
	if bool(Engine.get_meta("pk_fog_off", false)):
		return false
	# [fog-off-qa 2026-11-03] 真机反馈"去掉战争迷雾就闪烁"，需要能在安卓上复现
	# 关雾后的画面做 A/B（安卓读不到 web 的 Engine meta）。仅 QA 用，正常包无该文件。
	if OS.get_environment("PK_FOG_OFF") == "1":
		return false
	var fog_cfg = ConfigFile.new()
	if fog_cfg.load("user://pk_debug.cfg") == OK \
			and bool(fog_cfg.get_value("render", "fog_off", false)):
		return false
	if not host.fog_of_war_enabled:
		return false
	return _resolve_player_start_cell(host, ) >= 0


func _resolve_player_country_slot(host) -> int:
	if host._current_map == null:
		return -1
	var start_cell = _resolve_player_start_cell(host, )
	if start_cell < 0 or start_cell >= host._current_map.country_slot_arr.size():
		return -1
	return int(host._current_map.country_slot_arr[start_cell])


func _resolve_player_country_handle(host) -> int:
	if host._generator == null or not host._generator.has_method("get_country_facade"):
		return 0
	var start_cell = _resolve_player_start_cell(host, )
	var facade = host._generator.get_country_facade()
	if facade == null or start_cell < 0:
		return 0
	return int(facade.cell_summary(start_cell).get("country_handle", 0))


## 读档期优先用存档里的 `player_context.start_cell`：读档会用存档 config 重新
## 生成世界并重跑新开局选点，`gameplay_start_report().cell` 只是「重建世界上的
## 选点结果」——一旦世界与存档不一致，它指向另一张图的格（通常无主），视野门禁
## 就会误判成「无法绑定玩家国家」。读档成功（pending bundle 清空）后才回落到它。

func _resolve_player_start_cell(host) -> int:
	if not host._pending_load_bundle.is_empty():
		var saved_cell = _saved_player_start_cell(host, )
		if saved_cell >= 0:
			return saved_cell
	var report_cell = _report_player_start_cell(host, )
	if report_cell >= 0:
		return report_cell
	var flow = host._game_flow_service()
	if flow != null and flow.has_method("session"):
		var session: Dictionary = flow.session()
		return int(session.get("start_cell", -1))
	return -1


## 把 native 领土权威刷进 MapData.country_slot_arr，供视野/国界同一瞬间消费。

func _sync_country_territory_to_map(host) -> Dictionary:
	var ext = host._generator.get_data_core_world_ext() if host._generator != null \
		and host._generator.has_method("get_data_core_world_ext") else null
	if ext == null or not ext.has_method("sync_country_territory_to_map"):
		return {"ok": false, "reason": "sync_country_territory_unavailable"}
	return ext.sync_country_territory_to_map()


func _refresh_vision(host) -> Dictionary:
	var ext = host._generator.get_data_core_world_ext() if host._generator != null \
		and host._generator.has_method("get_data_core_world_ext") else null
	if ext == null or not ext.has_method("run_vision_research_pass") \
			or not _ensure_native_vision_configured(host, ext):
		var fallback = VisionSolver.solve(host._current_map, host._world_data, host._player_country_slot)
		host._physical_visible_arr = host._current_map.visible_arr.duplicate()
		host._vision_dirty_indices.resize(host._current_map.cell_count())
		for cell in host._current_map.cell_count():
			host._vision_dirty_indices[cell] = cell
		return fallback
	var facade = host._generator.get_country_facade() if host._generator.has_method("get_country_facade") else null
	host._remote_observation_capability = _has_remote_observation_capability(host, )
	var result: Dictionary = ext.run_vision_research_pass({
		"player_slot": host._player_country_slot,
		"remote_observation": host._remote_observation_capability,
		"country_slots": host._current_map.country_slot_arr,
		"visible": host._physical_visible_arr,
		"explored": host._current_map.explored_arr,
		"fog_k": host._current_map.fog_k_arr,
		"bio_occupancy_bits": host._current_map.bio_occupancy_bits_arr,
	})
	if not bool(result.get("ok", false)):
		return VisionSolver.solve(host._current_map, host._world_data, host._player_country_slot)
	host._physical_visible_arr = result.get("physical_visible", PackedByteArray())
	host._current_map.explored_arr = result.get("explored_arr", PackedByteArray())
	host._current_map.fog_k_arr = result.get("fog_k_arr", PackedByteArray())
	host._current_map.visible_arr = host._physical_visible_arr.duplicate()
	host._vision_dirty_indices = result.get("fog_dirty_indices", PackedInt32Array())
	if not host._fog_of_war_enabled:
		# 渲染直通不写回物理视野，也不把历史探索伪造成研究资格。
		host._vision_dirty_indices.resize(host._current_map.cell_count())
		for cell in host._current_map.cell_count():
			host._current_map.visible_arr[cell] = 1
			host._current_map.fog_k_arr[cell] = 255
			host._vision_dirty_indices[cell] = cell
	host._current_map.fog_solved = true
	host._current_map.vision_revision += 1
	_submit_native_observations(host, facade, result)
	return result


func _ensure_native_vision_configured(host, ext: Object) -> bool:
	var n = host._current_map.cell_count()
	var map_id = host._current_map.get_instance_id()
	if host._native_vision_configured_n == n and host._native_vision_configured_map_id == map_id:
		return true
	if host._world_data.cell_view_height.size() != n or host._world_data.cell_view_block.size() != n:
		var baked = VisionSolver.bake_static_fields(host._current_map, host._world_data)
		if not bool(baked.get("ok", false)):
			return false
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var configured: Dictionary = ext.configure_vision_research({
		"cell_count": n,
		"neighbor_indices": host._current_map.neighbor_indices_packed(),
		"view_height": host._world_data.cell_view_height,
		"view_block": host._world_data.cell_view_block,
		"signal_offsets": host._current_map.cell_research_signal_offsets,
		"signal_ids": host._current_map.cell_research_signal_ids,
		"bio_bits": catalog.get("research_bio_occupancy_bits", PackedInt32Array()),
		"bio_signals": catalog.get("research_bio_signal_ids", PackedInt32Array()),
	})
	if bool(configured.get("ok", false)):
		host._native_vision_configured_n = n
		host._native_vision_configured_map_id = map_id
		host._physical_visible_arr = PackedByteArray()
	return bool(configured.get("ok", false))


func _has_remote_observation_capability(host) -> bool:
	if host._player_country_handle == 0:
		host._player_country_handle = _resolve_player_country_handle(host, )
	var facade = host._generator.get_country_facade() if host._generator != null \
		and host._generator.has_method("get_country_facade") else null
	if facade == null or host._player_country_handle == 0:
		return false
	if host._magnetic_navigation_dense_id == -2:
		var ids: PackedStringArray = facade.native_catalog().get(
			"technology_ids", PackedStringArray())
		host._magnetic_navigation_dense_id = ids.find("tech.magnetic_navigation")
	return host._magnetic_navigation_dense_id >= 0 and facade.has_completed_technology(
		host._player_country_handle, host._magnetic_navigation_dense_id)


func _submit_native_observations(host, facade, result: Dictionary) -> void:
	if facade == null or host._player_country_handle == 0:
		return
	var cells: PackedInt32Array = result.get("observation_cells", PackedInt32Array())
	var signals: PackedInt32Array = result.get("observation_signals", PackedInt32Array())
	if cells.size() != signals.size() or cells.is_empty():
		return
	var day = host._world_clock.day_index() + 1 if host._world_clock != null else 1
	facade.submit_observation_batch(host._player_country_handle, cells, signals, day)

func _submit_discovered_map_signals(host, previous: PackedByteArray) -> void:
	if host._current_map == null or previous.size() != host._current_map.explored_arr.size() \
			or host._generator == null or not host._generator.has_method("get_country_facade"):
		return
	var facade = host._generator.get_country_facade()
	var handle = _resolve_player_country_handle(host, )
	if facade == null or handle == 0:
		return
	var commands: Array[Dictionary] = []
	var effective_day = host._world_clock.day_index() + 1 if host._world_clock != null else 1
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var offsets = host._current_map.cell_research_signal_offsets
	var ids = host._current_map.cell_research_signal_ids
	var values = host._current_map.cell_research_signal_values
	var csr_ok = offsets.size() == host._current_map.cell_count() + 1 and ids.size() == values.size()
	for cell in host._current_map.cell_count():
		if previous[cell] != 0 or host._current_map.explored_arr[cell] == 0:
			continue
		var seq = 0
		if csr_ok:
			var begin = int(offsets[cell])
			var end = int(offsets[cell + 1])
			for edge in range(begin, end):
				commands.append({
					"opcode": CountryFacade.Opcode.DISCOVER_COUNTRY_SIGNAL,
					"target_handle": handle,
					"signal": int(ids[edge]),
					"cell": cell,
					"value": 1,
					"effective_day": effective_day,
					"sequence": cell * 64 + seq,
				})
				seq += 1
		if cell < host._current_map.bio_occupancy_bits_arr.size():
			var occ_signals = ResearchSignalCatalog.occupancy_signal_indices(
				catalog, int(host._current_map.bio_occupancy_bits_arr[cell]))
			for signal_index in occ_signals:
				commands.append({
					"opcode": CountryFacade.Opcode.DISCOVER_COUNTRY_SIGNAL,
					"target_handle": handle,
					"signal": int(signal_index),
					"cell": cell,
					"value": 1,
					"effective_day": effective_day,
					"sequence": cell * 64 + seq,
				})
				seq += 1
	if not commands.is_empty():
		facade.submit(commands)


## 迷雾值住在 enum_lut 的 A 通道，所以视野一变就必须重烘一次 LUT。
## 不能等 DynamicVisualAtlasUploadSystem 的日刷——它在 dirty_count==0 时会
## early-return，视野变化不体现在 climate/weather dirty mask 上。

func _republish_cell_luts(host, dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = false) -> Dictionary:
	if host._generator == null or not ("_baker" in host._generator):
		return {"ok": false, "reason": "no_baker"}
	var baker = host._generator._baker
	if baker == null or not baker.has_method("refresh_cell_luts_daily"):
		return {"ok": false, "reason": "baker_missing_refresh"}
	return baker.refresh_cell_luts_daily(
		host._current_map, host._world_data, dirty_indices, force_full_encode)


func _refresh_country_borders(host) -> Dictionary:
	if host._renderer == null or not host._renderer.has_method("country_border_layer"):
		return {"ok": false, "reason": "no_renderer"}
	var layer = host._renderer.country_border_layer()
	if layer == null:
		return {"ok": false, "reason": "no_border_layer"}
	layer.set_hex_size(host.hex_size)
	layer.set_horizontal_wrap(host.map_wrap_period_x())
	layer.set_player_slot(host._player_country_slot)
	var stats: Dictionary = layer.rebuild(host._current_map)
	stats["ok"] = true
	return stats


func _rebuild_view_adapter(host) -> void:
	if host._current_map == null:
		host._view_adapter = null
		return
	var cp = host._generator._c() if host._generator != null and host._generator.has_method("_c") else null
	if cp != null and DCFeatureFlags.is_on(&"use_world_view_adapter", cp):
		var dc_world = host._generator.get_data_core_world() if host._generator != null and host._generator.has_method("get_data_core_world") else null
		if dc_world != null and dc_world.has_method("is_bound") and dc_world.is_bound():
			host._view_adapter = DCViewAdapter.World.new(dc_world, host._current_map)
			return
	host._view_adapter = DCViewAdapter.Cell.new(host._current_map.iter_cells())

