extends SceneTree


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var failures := PackedStringArray()
	var top_bar := PlayerTopBar.new()
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

	for failure in failures:
		push_error("[player-top-bar-day-night] FAIL: %s" % failure)
	print("[player-top-bar-day-night] %s" % ("PASS" if failures.is_empty() else "FAIL"))
	top_bar.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, label: String, failures: PackedStringArray) -> void:
	if not condition:
		failures.append(label)
