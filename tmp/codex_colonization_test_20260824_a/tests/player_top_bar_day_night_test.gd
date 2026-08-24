extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	var top_bar := (load("res://scenes/ui/player_top_bar.tscn") as PackedScene).instantiate() as PlayerTopBar
	root.add_child(top_bar)
	await process_frame

	var button: Button = top_bar.get("_day_night_button")
	_expect(button != null, "昼夜按钮已创建", failures)
	if button != null:
		top_bar.set_day_night_enabled(true)
		_expect(button.toggle_mode, "开启状态同步后仍保留 toggle_mode", failures)
		_expect(button.button_pressed, "开启状态正确回显", failures)

		var emitted_states: Array[bool] = []
		top_bar.day_night_toggled.connect(func(enabled: bool) -> void:
			emitted_states.append(enabled)
			top_bar.set_day_night_enabled(enabled)
		)
		button.button_pressed = false
		_expect(emitted_states == [false], "第一次点击可关闭昼夜循环", failures)
		_expect(button.toggle_mode, "关闭状态回读后仍保留 toggle_mode", failures)
		button.button_pressed = true
		_expect(emitted_states == [false, true], "第二次点击可重新开启昼夜循环", failures)
		_expect(button.toggle_mode and button.button_pressed,
			"重新开启后的按钮状态稳定", failures)

	var pause_button: Button = top_bar.get("_pause_button")
	_expect(pause_button != null, "暂停按钮已创建", failures)
	if pause_button != null:
		# GM 对 simulation.paused 的状态回读最终会走同一个顶栏刷新入口。
		top_bar.update_time_state(0, 7, 1, true, 1.0)
		_expect(pause_button.toggle_mode, "GM 暂停状态同步后仍保留 toggle_mode", failures)
		_expect(pause_button.button_pressed, "GM 暂停状态正确回显", failures)

		var emitted_pause_states: Array[bool] = []
		top_bar.pause_toggled.connect(func(paused: bool) -> void:
			emitted_pause_states.append(paused)
			top_bar.update_time_state(0, 7, 1, paused, 1.0)
		)
		pause_button.button_pressed = false
		_expect(emitted_pause_states == [false], "GM 状态同步后可点击继续", failures)
		_expect(pause_button.toggle_mode, "继续状态回读后仍保留 toggle_mode", failures)
		pause_button.button_pressed = true
		_expect(emitted_pause_states == [false, true], "继续后可再次点击暂停", failures)
		_expect(pause_button.toggle_mode and pause_button.button_pressed,
			"再次暂停后的按钮状态稳定", failures)

	for failure in failures:
		push_error("[player-top-bar-day-night] FAIL: %s" % failure)
	print("[player-top-bar-day-night] %s" % ("PASS" if failures.is_empty() else "FAIL"))
	top_bar.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, label: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(label)
