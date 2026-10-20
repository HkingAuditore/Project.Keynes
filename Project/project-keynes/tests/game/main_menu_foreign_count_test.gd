extends SceneTree

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var error := change_scene_to_file("res://scenes/main_menu.tscn")
	_expect("main menu scene opens", error == OK)
	for _frame in range(3):
		await process_frame
	if current_scene == null:
		_finish()
		return
	current_scene.call("_show_new_game")
	for _frame in range(3):
		await process_frame
	var box = current_scene.get("_foreign_count_box")
	_expect("foreign count control exists", box is SpinBox)
	if box is SpinBox:
		_expect("foreign count minimum", int(box.min_value) == 0)
		_expect("foreign count maximum", int(box.max_value) == 12)
		_expect("foreign count default", int(box.value) == 5)
	var scrolls := current_scene.find_children("*", "ScrollContainer", true, false)
	_expect("new-game form remains scrollable", not scrolls.is_empty())
	_finish()


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _finish() -> void:
	print("main menu foreign count: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
