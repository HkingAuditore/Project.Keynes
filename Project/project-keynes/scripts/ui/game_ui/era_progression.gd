extends RefCounted

# G5 collaborator. The host owns all mutable state; it is passed per call.

func show_era_reward_offer(host, offer: Dictionary) -> void:
	if host._era_reward_dialog != null:
		if host._era_panel != null and host._era_panel.visible:
			host._era_panel.close(true)
		if not host._era_reward_dialog.visible:
			host._era_reward_dialog.open_overview(host._build_era_overview())
		host._era_reward_dialog.present_offer(offer)
		if host._era_indicator != null:
			host._era_indicator.set_expanded(true)



func _build_era_overview(host) -> Dictionary:
	if host._player_controller == null:
		return {}
	if host._era_indicator_view_model == null:
		host._era_indicator_view_model = EraIndicatorViewModel.new()
	return host._era_indicator_view_model.build_overview(
		host._player_controller.get_country_facade(), host._player_controller.get_economy_facade(),
		int(host._player_controller.get_player_country_handle()), host._gdp_ledger)


## 纸徽点击：打开「国家概况 + 时代晋升」合并速览（一张纸笺、无页签、无滚动）。
## 待领时代奖励时，速览左栏出现「领取时代奖励」按钮；三张奖励纸片仍走 EraRewardDialog 原流程。
## 奖励弹窗已展开时，点击维持原有的开关语义。

func _on_era_indicator_pressed(host) -> void:
	if host.is_annual_report_open() or host.is_family_founding_modal_open() or host.is_era_ceremony_playing():
		return
	if host._era_reward_dialog != null and host._era_reward_dialog.visible:
		host._on_era_popup_dismissed()
		return
	host._ensure_era_panel()
	if host._era_panel == null:
		return
	if host._era_panel.is_open():
		host._close_era_panel()
		return
	host._era_panel.set_reward_available(String(host._era_offer.get("status", "NONE")) in ["OPEN", "ERROR"])
	host._era_panel.open(host._era_advancement_model(), host._build_era_overview())
	if host._era_indicator != null:
		host._era_indicator.set_expanded(host._era_panel.wants_expanded_badge())



func _close_era_panel(host) -> void:
	if host._era_panel != null:
		host._era_panel.close()
	if host._era_indicator != null and (host._era_reward_dialog == null or not host._era_reward_dialog.visible):
		host._era_indicator.set_expanded(false)



func is_era_panel_open(host) -> bool:
	return host._era_panel != null and host._era_panel.is_open()



func _on_era_panel_command(host, command: StringName) -> void:
	var result: Dictionary = {"ok": false, "code": "controller_unavailable",
		"message": "玩家会话尚未就绪"}
	if host._player_controller != null and host._player_controller.has_method("request_command"):
		result = host._player_controller.request_command(command, {})
	if host._era_panel != null:
		host._era_panel.show_command_result(result)
	host._apply_era_advancement(host._era_advancement_model(true))


## 快照只来自 PlayerController（§5）；控制器尚未提供时返回 ok=false，面板显示不可用。

func _era_advancement_model(host, fresh: bool = false) -> Dictionary:
	if (fresh or host._era_advancement_snapshot.is_empty()) and host._player_controller != null \
			and host._player_controller.has_method("get_era_advancement_snapshot"):
		var snapshot = host._player_controller.get_era_advancement_snapshot()
		if snapshot is Dictionary:
			host._era_advancement_snapshot = snapshot
	return host._era_advancement_snapshot



func _on_era_advancement_changed(host, snapshot: Dictionary) -> void:
	host._era_advancement_snapshot = snapshot
	host._apply_era_advancement(snapshot)



func _apply_era_advancement(host, snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return
	if host._era_indicator != null:
		host._era_indicator.set_advancement(String(snapshot.get("status", "")) \
			if bool(snapshot.get("ok", false)) else "", float(snapshot.get("progress", 0.0)))
	if host._era_panel != null and host._era_panel.visible:
		host._era_panel.set_snapshot(snapshot)



func _on_era_popup_dismissed(host) -> void:
	if host._era_reward_dialog.is_offer_open():
		host.era_reward_dismiss_requested.emit()
		# 已提交事务的控制器拒绝关闭，继续等待 ACK。
		if host._era_reward_dialog.is_offer_open():
			return
	host._era_reward_dialog.close_overview()
	if host._era_indicator != null:
		host._era_indicator.set_expanded(false)


# Availability never opens a modal; the native offer remains the sole authority.

func notify_era_reward_offer(host, offer: Dictionary) -> void:
	host._era_offer = offer
	if host._era_indicator != null:
		host._era_indicator.set_offer_available(String(offer.get("status", "NONE")) in ["OPEN", "ERROR"])
	if host._era_panel != null:
		host._era_panel.set_reward_available(String(offer.get("status", "NONE")) in ["OPEN", "ERROR"])
	host._queue_era_indicator_refresh()






func _refresh_era_indicator(host) -> void:
	if host._era_indicator == null or host._player_controller == null:
		return
	var facade = host._player_controller.get_country_facade()
	var handle = int(host._player_controller.get_player_country_handle())
	if facade == null or handle == 0:
		if host._top_bar != null:
			host._top_bar.set_country_status(0.0, false, 0, false)
		return
	host._refresh_player_country_status(facade, host._player_controller.get_economy_facade(), handle)
	if host._era_indicator_view_model == null:
		host._era_indicator_view_model = EraIndicatorViewModel.new()
	var model = host._era_indicator_view_model.build(facade.research_snapshot(handle))
	if not model.is_empty() and host._era_celebrated_index < 0:
		# 读档/新世界后的第一份模型只建立基线，任何时候都不重播旧的晋升。
		host._era_celebrated_index = int(model.era_index)
	host._era_indicator.set_model(model)
	if not model.is_empty() and host._era_transfer_name.is_empty() and host._top_bar != null \
			and not host._era_indicator.has_pending_era():
		host._top_bar.set_era_name(String(model.era_name))
	host._apply_era_advancement(host._era_advancement_model(true))
	if host._era_panel != null and host._era_panel.visible:
		host._era_panel.set_overview(host._build_era_overview())
	if host._era_reward_dialog != null and host._era_reward_dialog.visible:
		host._era_reward_dialog.refresh_overview(host._build_era_overview())



func _refresh_player_country_status(host, country_facade, economy_facade, handle: int) -> void:
	if host._top_bar == null:
		return
	var treasury: Dictionary = country_facade.treasury_snapshot(handle) \
		if country_facade != null and country_facade.has_method("treasury_snapshot") else {}
	var economy: Dictionary = economy_facade.country_economy_overview(handle, "summary") \
		if economy_facade != null and economy_facade.has_method("country_economy_overview") else {}
	var cash_valid = bool(treasury.get("ok", false)) and treasury.has("cash")
	var population_valid = bool(economy.get("ok", false)) and economy.has("population")
	host._top_bar.set_country_status(
		float(treasury.get("cash", 0)), cash_valid,
		int(economy.get("population", 0)), population_valid)
	host._refresh_status_card()


# ── 顶栏纸签悬浮卡：国库看近期日均收支，人口看阶层构成 ────────────────────
## hover 先延迟再查询：指针扫过顶栏时不会连发原生 professions 查询；
## 移开时同样延迟收卡，避免纸签之间来回移动导致卡片闪烁。
## 点击纸签直接进入对应章节，卡片立即收掉。




func _on_top_bar_status_pressed(host, kind: String) -> void:
	if host.TouchUI.is_touch() and host._status_card != null and host._top_bar != null:
		if not host._status_card.is_open() or host._status_card_kind != kind:
			var model = host._build_status_card_model(kind)
			if not model.is_empty():
				host._status_card_generation += 1
				host._status_card_kind = kind
				host._status_card_next_refresh_ms = Time.get_ticks_msec() + host.STATUS_CARD_REFRESH_MSEC
				host._status_card.show_card(model, host._top_bar.status_anchor(kind))
				return
	host._status_card_generation += 1
	host._status_card_kind = ""
	if host._status_card != null:
		host._status_card.hide_card(true)
	host.open_country_section("economy", "overview" if kind == "treasury" else "strata")


## 悬浮期间读数会随日结算变化：只在卡还开着时按节流重填，不重播入场。

func _refresh_status_card(host) -> void:
	if host._status_card == null or host._status_card_kind.is_empty() or not host._status_card.is_open():
		return
	var now = Time.get_ticks_msec()
	if now < host._status_card_next_refresh_ms:
		return
	host._status_card_next_refresh_ms = now + host.STATUS_CARD_REFRESH_MSEC
	host._status_card.refresh_card(host._build_status_card_model(host._status_card_kind))



func _build_status_card_model(host, kind: String) -> Dictionary:
	if host._player_controller == null:
		return {}
	var handle = int(host._player_controller.get_player_country_handle())
	if handle == 0:
		return {}
	var country_facade = host._player_controller.get_country_facade()
	var economy_facade = host._player_controller.get_economy_facade()
	if kind == "treasury":
		var treasury: Dictionary = country_facade.treasury_snapshot(handle) \
			if country_facade != null and country_facade.has_method("treasury_snapshot") else {}
		var fiscal: Dictionary = country_facade.fiscal_snapshot(handle) \
			if country_facade != null and country_facade.has_method("fiscal_snapshot") else {}
		var cash_valid = bool(treasury.get("ok", false)) and treasury.has("cash")
		var history = host._country_view_model.fiscal_history() if host._country_view_model != null else null
		return HudStatusViewModel.build_treasury(
			cash_valid, int(treasury.get("cash", 0)), fiscal, history)
	if economy_facade == null or not economy_facade.has_method("country_economy_overview"):
		return HudStatusViewModel.build_population({}, {})
	var professions: Dictionary = economy_facade.country_economy_overview(
		handle, "professions")
	var summary: Dictionary = economy_facade.country_economy_overview(handle, "summary")
	return HudStatusViewModel.build_population(professions, summary)


## 纸徽检测到会话内时代上升（已提交快照，读档首帧只建立基线不会走到这里）。
## 由大典接管：纸徽保留旧图标，大典的新徽记飞回后才换图、闪光并把光点送到日历。

func _on_era_indicator_advanced(host, model: Dictionary) -> void:
	var new_index = int(model.get("era_index", -1))
	if new_index > host._era_celebrated_index:
		var old_index = host._era_celebrated_index if host._era_celebrated_index >= 0 else new_index - 1
		host._start_era_ceremony(old_index, new_index, host._ceremony_buffs_from_snapshot(new_index))
		return
	# 大典已由 PlayerController.era_advanced 先行开播：等它落地再换图；已经落地则只补换图。
	if not host.is_era_ceremony_playing() and host._era_indicator != null:
		host._era_indicator.reveal_pending_era(false)


## PlayerController.era_advanced（玩家晋升服务观察到时代 ACK）：携带权威加成文案。

func _on_player_era_advanced(host, old_index: int, new_index: int, buffs: PackedStringArray) -> void:
	if new_index <= host._era_celebrated_index:
		if host.is_era_ceremony_playing() and host._era_ceremony_index == new_index and not buffs.is_empty():
			host._era_ceremony.set_buffs(buffs)
		return
	if host._era_celebrated_index < 0:
		# 尚未建立基线（会话刚绑定）：视为恢复，不演出。
		host._era_celebrated_index = new_index
		return
	host._start_era_ceremony(maxi(old_index, host._era_celebrated_index), new_index, buffs)



func _ceremony_buffs_from_snapshot(host, new_index: int) -> PackedStringArray:
	# 晋升前最后一份快照的 buffs_preview 正是这次获得的加成。
	var snapshot = host._era_advancement_snapshot
	if int(snapshot.get("next_era_index", -2)) == new_index:
		return PackedStringArray(snapshot.get("buffs_preview", PackedStringArray()))
	return PackedStringArray()



func is_era_ceremony_playing(host) -> bool:
	return host._era_ceremony != null and is_instance_valid(host._era_ceremony) and host._era_ceremony.is_playing()



func _on_era_ceremony_landed(host, new_index: int) -> void:
	if new_index != host._era_ceremony_index:
		return
	host._land_era_on_badge(host._era_ceremony_landed_name)


## 新徽记落到纸徽：换图 + 金环礼花，光点飞向日历换字，并补一条晋升纸贴。

func _land_era_on_badge(host, era_name: String) -> void:
	if host._era_indicator != null:
		# 纸徽未被大典接管（无 defer）时它已自行放过礼花，这里不再重放。
		host._era_indicator.reveal_pending_era(host._era_indicator.has_pending_era() \
			or host._era_indicator.defer_celebration)
	if not era_name.is_empty():
		host._era_transfer_name = era_name
	if host._era_flight != null and host._top_bar != null and host._era_indicator != null:
		host._era_flight.play(host._era_indicator.icon_origin(), host._top_bar.era_name_target())
	elif host._top_bar != null and not host._era_transfer_name.is_empty():
		host._on_era_flight_landed()
	if host._era_indicator_view_model == null:
		host._era_indicator_view_model = EraIndicatorViewModel.new()
	host._notify_era_promoted({"era_id": host._era_indicator_view_model.era_id_for(host._era_celebrated_index),
		"era_name": era_name})



func _on_era_ceremony_finished(host) -> void:
	# 兜底：跳过 / 中断 / landed 索引不匹配时，也要把纸徽对齐到当前时代。
	if host._era_indicator != null:
		host._era_indicator.reveal_pending_era(false)
	host._era_ceremony = null
	host._era_ceremony_index = -1
	host._restore_clock_after_ceremony()



func _abort_era_ceremony(host) -> void:
	if host._era_ceremony != null and is_instance_valid(host._era_ceremony):
		host._era_ceremony.abort()
	host._era_ceremony = null
	host._era_ceremony_index = -1
	# 世界已切换：不恢复旧世界的时钟状态。
	host._era_ceremony_resume_clock = false


## 大典期间暂停时钟（同时代奖励/家族创立的做法），只在由大典暂停时才恢复。

func _pause_clock_for_ceremony(host) -> void:
	if host._world_clock == null or host._era_ceremony_resume_clock:
		return
	if host._world_clock.paused:
		return
	host._era_ceremony_resume_clock = true
	host._world_clock.pause(true)
	if host._player_controller != null and host._player_controller.has_method("sync_ui"):
		host._player_controller.sync_ui()



func _restore_clock_after_ceremony(host) -> void:
	if not host._era_ceremony_resume_clock:
		return
	host._era_ceremony_resume_clock = false
	if host._world_clock == null or not host._world_clock.paused:
		return
	# 演出期间若有其他流程接管时钟（时代奖励选择、暂停菜单），交还给它们。
	if host._pause_menu != null and host._pause_menu.visible:
		return
	if host.is_era_reward_modal_open() or host.is_family_founding_modal_open() or host.is_annual_report_open():
		return
	if host._player_controller != null and host._player_controller.has_method("era_reward_locked") \
			and bool(host._player_controller.era_reward_locked()):
		return
	if host._player_controller != null and host._player_controller.has_method("ideology_draw_locked") \
			and bool(host._player_controller.ideology_draw_locked()):
		return
	host._world_clock.pause(false)
	if host._player_controller != null and host._player_controller.has_method("sync_ui"):
		host._player_controller.sync_ui()


## 时代晋升是必须被看见的一刻：徽记特效、顶栏日历换字和纸贴提醒三件事同时发生。
## 玩家通常正泡在科技面板里等里程碑完成，所以纸贴和徽记都走面板遮罩之上。

func _notify_era_promoted(host, model: Dictionary) -> void:
	var era_id = String(model.get("era_id", ""))
	if era_id.is_empty():
		return
	host._ensure_research_toast()
	if host._research_toast == null:
		return
	host._research_toast.show_era_promoted(era_id, String(model.get("era_name", "")),
		String(host._era_offer.get("status", "NONE")) in ["OPEN", "ERROR"])



func _on_era_flight_landed(host) -> void:
	if host._top_bar != null and not host._era_transfer_name.is_empty():
		host._top_bar.set_era_name(host._era_transfer_name, true)
	host._era_transfer_name = ""



func show_era_reward_error(host, message: String) -> void:
	if host._era_reward_dialog != null:
		host._era_reward_dialog.show_error(message)



func show_era_reward_pending(host) -> void:
	if host._era_reward_dialog != null:
		host._era_reward_dialog.show_pending()



func close_era_reward_offer(host) -> void:
	if host._era_reward_dialog != null:
		host._era_reward_dialog.close_offer()



func is_era_reward_modal_open(host) -> bool:
	return host._era_reward_dialog != null and host._era_reward_dialog.is_offer_open()



func show_family_founding_offer(host, offer: Dictionary) -> void:
	if host._country_panel != null and host._country_panel.is_panel_open():
		host.close_country_panel()
	if host._colonization_panel != null and host._colonization_panel.visible:
		host._colonization_panel.close_panel()
	if host._family_founding_dialog != null:
		host._layout_family_founding_dialog()
		host._family_founding_dialog.present_offer(offer)
		host._layout_family_founding_dialog()
		if host._player_controller != null:
			host._player_controller.ensure_selected_visible()



func show_family_founding_error(host, message: String) -> void:
	if host._family_founding_dialog != null and host._family_founding_dialog.is_offer_open():
		host._family_founding_dialog.show_error(message)



func close_family_founding_offer(host) -> void:
	if host._family_founding_dialog != null:
		host._family_founding_dialog.close_offer()



func is_family_founding_modal_open(host) -> bool:
	return host._family_founding_dialog != null and host._family_founding_dialog.is_offer_open()


