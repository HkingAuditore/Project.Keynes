extends RefCounted

static func _on_military_state_building_requested(host, request: Dictionary) -> void:
	if host._player_controller == null:
		return
	var op := String(request.get("op", "state.build"))
	var command_id: StringName = host.PlayerControllerScript.COMMAND_MILITARY_STATE_BUILD \
		if op == "state.build" else host.PlayerControllerScript.COMMAND_MILITARY_STATE_DEMOLISH
	var result: Dictionary = host._player_controller.request_command(command_id, {
		"cell": int(request.get("cell", -1)),
		"building": int(request.get("building", -1)),
	})
	var ok := bool(result.get("ok", false))
	var message := String(result.get("message", ""))
	# 被拒时立刻解锁动作键，不然要等到下一次日推进才恢复——玩家会以为按钮坏了。
	if not ok and host._right_panel != null \
			and host._right_panel.has_method("release_military_ledger_busy"):
		host._right_panel.release_military_ledger_busy()
	# 回执先写在地块档案那一行上（成功=已排队，失败=被拒的理由）；营造反馈条
	# 只在营造窗口打开时可见，不能当作这一页的回音。
	if host._right_panel != null and host._right_panel.has_method("set_military_ledger_feedback"):
		host._right_panel.set_military_ledger_feedback(message, ok)
	if host._right_panel != null and host._right_panel.has_method("set_construction_feedback"):
		host._right_panel.set_construction_feedback(message, ok)


## 地块军事台账把该格本国驻军整编为一支部队；兵种模板直接取自驻军 lots。
static func _on_military_army_create_requested(host, request: Dictionary) -> void:
	if host._player_controller == null:
		if host._right_panel != null:
			host._right_panel.set_military_army_feedback("玩家控制器尚未就绪。", false)
			host._right_panel.release_military_ledger_busy()
		return
	var result: Dictionary = host._player_controller.request_command(
		host.PlayerControllerScript.COMMAND_MILITARY_ARMY_CREATE, {
			"cell": int(request.get("cell", -1)),
			"units": request.get("units", {}),
		})
	var ok := bool(result.get("ok", false))
	var message := String(result.get("message", ""))
	if message.is_empty():
		message = "编成命令已排队，将在下一游戏日生效。" if ok else "部队编成未能排队。"
	if not ok and host._right_panel != null \
			and host._right_panel.has_method("release_military_ledger_busy"):
		host._right_panel.release_military_ledger_busy()
	if host._right_panel != null and host._right_panel.has_method("set_military_army_feedback"):
		host._right_panel.set_military_army_feedback(message, ok)
	if ok:
		host._mark_country_panel_dirty(host.COUNTRY_DIRTY_MILITARY, "army_create")


static func _on_military_dossier_action_requested(host, action: StringName, payload: Dictionary) -> void:
	if host._player_controller == null:
		return
	if action == &"locate" or action == &"locate_cell":
		var cell := int(payload.get("cell", -1))
		if cell < 0:
			cell = int(payload.get("focus_cell", -1))
		if cell >= 0 and host._player_controller.has_method("focus_cell"):
			host._player_controller.call("focus_cell", cell)
		return
	var handle := int(payload.get("handle", 0))
	if handle <= 0:
		return
	var result: Dictionary = {}
	match action:
		&"move", &"area", &"explore":
			var default_radius := int(payload.get("radius", 2 if action == &"explore" else 1))
			result = host._player_controller.begin_military_arm_order(handle, String(action), default_radius)
		&"cancel_order":
			host._player_controller.cancel_military_arm_order()
			return
		&"confirm_order":
			result = host._player_controller.confirm_military_arm_order()
		&"radius":
			host._player_controller.set_military_arm_order_radius(int(payload.get("radius", 1)))
			return
		&"stop", &"stance":
			host._player_controller.cancel_military_arm_order()
			var command := &"military.army.stop" if action == &"stop" else &"military.army.stance"
			result = host._player_controller.request_command(command,
				{"army": handle, "stance": int(payload.get("stance", 0))})
		_:
			return
	# 行军 / 区域控制成功也要给回执：否则确认键按下后档案毫无变化，玩家以为按钮坏了。
	var accepted := bool(result.get("ok", false))
	var fallback := "命令已下达。" if accepted else "命令未生效，请重试。"
	host._right_panel.set_military_dossier_feedback(
		String(result.get("message", fallback)), accepted)


static func apply_military_command_settled(host, id: StringName, result: Dictionary) -> void:
	var panel = host._right_panel
	if panel != null:
		var ok := bool(result.get("ok", false))
		var message := String(result.get("message", ""))
		if id in [&"military.state.build", &"military.state.demolish"]:
			panel.release_military_ledger_busy()
			panel.set_military_ledger_feedback(message, ok)
			panel.set_construction_feedback(message, ok)
		elif not ok and id in [&"military.army.create", &"military.train"]:
			panel.set_military_army_feedback(message, false)
			panel.set_military_ledger_feedback(message, false)
		elif not ok and id in [&"military.army.move", &"military.army.area_control",
				&"military.army.explore"]:
			panel.set_military_dossier_feedback(message, false)
	host._mark_country_panel_dirty(host.COUNTRY_DIRTY_MILITARY, "military_commit")
	# 宣战/议和在军事运行时里落地，外交页的战事与关系必须在同一天跟上。
	host._mark_country_panel_dirty(host.COUNTRY_DIRTY_DIPLOMACY, "military_commit")
	host._refresh_peace_window()
