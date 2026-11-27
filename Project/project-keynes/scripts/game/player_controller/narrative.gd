extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func narrative_service(host):
	return host._narrative_service



func narrative_flow(host):
	return host._narrative_flow


func narrative_ai_client(host):
	return host._narrative_ai_client



func narrative_event_locked(host) -> bool:
	return host._narrative_flow != null and host._narrative_flow.is_locked()


## 玩家关掉自己窗口后的重查入口：静置中的事件在这一刻才允许展示。
func recheck_narrative_popup(host) -> void:
	if host._narrative_flow != null:
		host._narrative_flow.try_present()


func open_narrative_chronicle(host, filter_cell: int = -1) -> void:
	if host._ui_manager == null or host._narrative_service == null:
		return
	if host._ui_manager.has_method("show_narrative_chronicle"):
		host._ui_manager.show_narrative_chronicle(
			host._narrative_service.chronicle_for_display(filter_cell)
		)



func _configure_narrative_runtime(host) -> void:
	if host._narrative_service == null or host._narrative_flow == null:
		return
	if host._narrative_ai_client == null:
		host._narrative_ai_client = host.NarrativeAiClientScript.new()
		host._narrative_ai_client.name = "NarrativeAiClient"
		host.add_child(host._narrative_ai_client)
	host._narrative_flow.configure(
		host, host._runtime_host, host._world_clock, host._ui_manager,
		host._narrative_service, host._narrative_ai_client
	)
	if not host._narrative_flow.offer_changed.is_connected(host._on_narrative_offer_changed):
		host._narrative_flow.offer_changed.connect(host._on_narrative_offer_changed)
	if not host._narrative_flow.event_resolved.is_connected(host._on_narrative_event_resolved):
		host._narrative_flow.event_resolved.connect(host._on_narrative_event_resolved)
	if not host._narrative_service.ai_generation_requested.is_connected(host._on_narrative_ai_generation_requested):
		host._narrative_service.ai_generation_requested.connect(host._on_narrative_ai_generation_requested)
	if host._ui_manager != null and host._ui_manager.has_signal("narrative_chronicle_requested"):
		var cb_chron = Callable(host, "open_narrative_chronicle")
		if not host._ui_manager.narrative_chronicle_requested.is_connected(cb_chron):
			host._ui_manager.narrative_chronicle_requested.connect(cb_chron)



func _on_narrative_offer_changed(host, offer: Dictionary) -> void:
	host.narrative_event_offer_changed.emit(offer)



func _on_narrative_event_resolved(host, record: Dictionary) -> void:
	host.narrative_event_resolved.emit(record)




func _configure_music_situation(host) -> void:
	if host._music_situation == null or host._runtime_host == null:
		return
	var generator = host._runtime_host.generator() if host._runtime_host.has_method("generator") else null
	host._music_situation.configure(host._runtime_host, generator, host)
	host._music_situation.refresh_global_from_commit()
	if host._camera != null and host._camera.has_method("current_world_view_rect"):
		host._music_situation.refresh_local_from_view(
			host._camera.current_world_view_rect(), host.music_camera_zoom_ratio())


func _sync_era_music(host, force_population_sync: bool = false) -> void:
	if host._player_country_handle == 0 or host._country_facade == null:
		return
	if not host._country_facade.has_method("current_era_index"):
		return
	var audio: Node = host.get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("set_era"):
		return
	var prev_era: int = int(audio.era_index()) if audio.has_method("era_index") else -1
	var era_index: int = host._country_facade.current_era_index(host._player_country_handle)
	if era_index >= 0:
		audio.set_era(era_index)
	var era_changed := era_index >= 0 and era_index != prev_era
	if (force_population_sync or era_changed) and host._camera != null:
		host.AudioPresentation._sync_camera_zoom_audio(host, force_population_sync and prev_era < 0)
	if host._economy_facade != null and host._economy_facade.has_method("country_economy_overview") \
			and audio.has_method("update_active_suite_population_count"):
		var now_ms := Time.get_ticks_msec()
		if force_population_sync or era_changed \
				or host._last_music_pop_sample_ms == 0 \
				or now_ms - host._last_music_pop_sample_ms >= host.MUSIC_POP_SAMPLE_INTERVAL_MS:
			var summary: Dictionary = host._economy_facade.country_economy_overview(
				host._player_country_handle, "summary")
			if bool(summary.get("ok", false)):
				host._last_music_pop_sample_ms = now_ms
				audio.update_active_suite_population_count(int(summary.get("population", 0)))


func _sync_camera_zoom_audio(host, reset_baseline: bool = false) -> void:
	if host._camera == null:
		return
	var zoom_val: float = float(host._camera.zoom.x) if "zoom" in host._camera else 1.0
	if reset_baseline:
		host._camera_zoom_baseline = zoom_val
		host._camera_zoom_user_engaged = false
		var audio: Node = host.get_node_or_null("/root/GameAudio")
		if audio != null and audio.has_method("set_active_suite_camera_zoom"):
			audio.set_active_suite_camera_zoom(0.5, true)
		return
	host._on_camera_zoom_changed(zoom_val)


func music_camera_zoom_ratio(host) -> float:
	if host._camera == null:
		return 0.5
	var min_z := 0.55
	var max_z := 3.6
	if host._camera.has_method("_minimum_zoom"):
		min_z = clampf(float(host._camera._minimum_zoom()), 0.25, 1.2)
	if "zoom_max" in host._camera:
		max_z = maxf(min_z + 0.6, minf(float(host._camera.zoom_max), 4.0))
	return host.camera_zoom_to_audio_ratio(float(host._camera.zoom.x), min_z, max_z)


## 将 Camera2D 的缩放倍率（越大越近、越小越远）映射为 FMOD CameraZoom 参数（0.0=拉近近景 .. 1.0=拉远苍穹）。


static func camera_zoom_to_audio_ratio(host, zoom_val: float,
		min_zoom: float = 0.55, max_zoom: float = 3.6) -> float:
	var lo := maxf(0.1, min_zoom)
	var hi := maxf(lo + 0.2, max_zoom)
	var clamped := clampf(zoom_val, lo, hi)
	var t := inverse_lerp(log(lo), log(hi), log(clamped))
	return clampf(1.0 - t, 0.0, 1.0)



## 理念音效：抽（offer/choose/reroll）与用（equip/unequip/promote）分开。
## 只在成功时发声，被拒绝的命令不响。
## 日常游戏事件音效：经济 trace 流自带消费游标，不遍历全图。
##   贸易 / 人口 → 经济 trace 流；建筑由可见地图活动层播放。
##   科技/理念 → GameUIManager 的完成通知与命令回执，避免日切重复播放。
##   开拓      → diff territory_cells.size()


func _sync_event_audio(host) -> void:
	if host._player_country_handle == 0:
		return
	var audio: Node = host.get_node_or_null("/root/GameAudio")
	if audio == null or not audio.has_method("play_event_cue"):
		return

	# 贸易：经济事件流 kind 13 = TRADE_ARRIVED。
	# 建筑不走这里 —— map_activity_layer 的 build 活动已经带屏幕过滤，
	# 两处都接会在同一栋建筑落成时响两声。
	if host._economy_facade != null and host._economy_facade.has_method("poll_events"):
		var trade: Dictionary = host._economy_facade.poll_events(&"pk_sfx_trade", 32, 13)
		if int(trade.get("count", 0)) > 0:
			audio.play_event_cue(&"trade")
		# 人口：原生市场级 births/deaths 事件（EVENT_POPULATION_CHANGED = 16）。
		# 逐格出生分摊在 market 结算内部，这里拿到市场级汇总，配 2.5s 冷却足够。
		var pop: Dictionary = host._economy_facade.poll_events(&"pk_sfx_pop", 32, 16)
		if int(pop.get("count", 0)) > 0:
			audio.play_event_cue(&"population_grow")
	# _player_controller_build_removed

	# 开拓：领土格数变多
	if host._country_facade != null and host._country_facade.has_method("snapshot"):
		var snapshot: Dictionary = host._country_facade.snapshot(host._player_country_handle)
		var cells: PackedInt32Array = snapshot.get("territory_cells", PackedInt32Array())
		if not cells.is_empty():
			if host._territory_snapshot >= 0 and cells.size() > host._territory_snapshot:
				audio.play_event_cue(&"territory_expand")
			host._territory_snapshot = cells.size()
