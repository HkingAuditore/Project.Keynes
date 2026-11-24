extends RefCounted


static func _update_target_readout(host) -> void:
	var budget_mode: bool = host._mode_budget.button_pressed
	var per := float(host._forces.get("per_soldier_cost", 0)) / MilitaryViewModel.MONEY_SCALE
	var value: float = host._target_slider.value
	host._target_value_icon.visible = budget_mode
	host._cost_icon.visible = not budget_mode and per > 0.0
	if budget_mode:
		host._target_value.text = "%s / 日" % UITokens.format_compact_number_cn(value, 1)
		host._cost_caption.text = "约可维持 %s 人" % (UITokens.format_compact_number_cn(
			value / per, 0) if per > 0.0 else "—")
		host._cost_value.text = ""
	else:
		host._target_value.text = "%s 人" % UITokens.format_compact_number_cn(value, 1)
		host._cost_caption.text = "预计日军费" if per > 0.0 else "人均军费待首次结算"
		host._cost_value.text = UITokens.format_compact_number_cn(value * per, 1) if per > 0.0 else ""
	MoneyDisplay.apply_icon(host._target_value_icon, 22)
	MoneyDisplay.apply_icon(host._cost_icon, 14)


static func _on_target_value_changed(host, _value: float) -> void:
	_update_target_readout(host)
	if host._slider_dragging:
		return
	if host._target_commit_timer != null:
		host._target_commit_timer.start()


static func _on_target_drag_ended(host, _changed_value: bool) -> void:
	host._slider_dragging = false
	_commit_target(host)


static func _commit_target(host) -> void:
	if host._target_commit_timer != null:
		host._target_commit_timer.stop()
	_submit_target(host, 1 if host._mode_budget.button_pressed else 0)


static func _on_target_mode(host, mode: int) -> void:
	host._mode_headcount.set_pressed_no_signal(mode == 0)
	host._mode_budget.set_pressed_no_signal(mode == 1)
	var current_mode: int = host._target_pending_mode if host._target_pending_mode >= 0 \
		else int(host._forces.get("target_mode", 0))
	if mode == current_mode:
		# 重复点当前模式：只同步按钮状态，不发命令。以前这里会照发一条
		# 「value = 滑条当前值」的命令，滑条停在 0 时等于把招募目标清零。
		return
	var per := float(host._forces.get("per_soldier_cost", 0)) / MilitaryViewModel.MONEY_SCALE
	if per > 0.0:
		# Keep the same force size when switching units of the slider.
		var converted: float = host._target_slider.value * per if mode == 1 else host._target_slider.value / per
		host._target_slider.max_value = host.BUDGET_MAX if mode == 1 else host.HEADCOUNT_MAX
		host._target_slider.step = 50.0 if mode == 1 else 100.0
		host._target_slider.set_value_no_signal(converted)
	_update_target_readout(host)
	_submit_target(host, mode)


static func _submit_target(host, mode: int) -> void:
	var value: float = host._target_slider.value
	if mode == host._target_pending_mode and is_equal_approx(value, host._target_pending_value):
		return
	var raw := int(round(value * MilitaryViewModel.MONEY_SCALE)) if mode == 1 else int(round(value))
	host._target_pending_mode = mode
	host._target_pending_value = value
	var result: Dictionary = host._request(
		host.PlayerControllerScript.COMMAND_MILITARY_FORCE_TARGET, {"mode": mode, "value": raw})
	if bool(result.get("ok", false)):
		return
	# 没被受理（会话未就绪 / 参数被拒）：立刻放弃覆盖，下一次刷新把把手退回原生
	# 真值。顶部那句拒绝理由由 `host._request` 留下，不在这里用本地值假装已生效。
	host._target_pending_mode = -1
	host._target_pending_value = -1.0


static func _on_roster_step(host, unit_id: String, delta_bp: int) -> void:
	var current := 0
	for unit in host._forces.get("units", []):
		if String(unit.id) == unit_id:
			current = int(unit.bp)
			break
	# 份额合计上限 10000，未分配的部分保持民兵。
	var ceiling := maxi(current, 10000 - (int(host._forces.get("share_total", 0)) - current))
	var target := clampi(current + delta_bp, 0, ceiling)
	if target == current:
		return
	host._request(host.PlayerControllerScript.COMMAND_MILITARY_CONFIG_SHARES,
		{"unit": unit_id, "bp": target})


static func _on_share_bar_clicked(host, unit_id: String, ratio: float) -> void:
	if unit_id.is_empty():
		return
	var current := 0
	var others := 0
	for unit in host._forces.get("units", []):
		if bool(unit.get("is_militia_row", false)):
			continue
		var bp := int(unit.bp)
		if String(unit.id) == unit_id:
			current = bp
		else:
			others += bp
	if current <= 0:
		return
	var target := clampi(int(round(float(current) * clampf(ratio, 0.0, 1.0))),
		0, maxi(0, 10000 - others))
	if target == current:
		return
	host._request(host.PlayerControllerScript.COMMAND_MILITARY_CONFIG_SHARES,
		{"unit": unit_id, "bp": target})
