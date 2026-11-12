extends SceneTree

const SCENE := preload("res://scenes/ui/military_map_toolbar.tscn")

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var toolbar := SCENE.instantiate() as Control
	root.add_child(toolbar)
	await process_frame
	var column := toolbar.get_node("Panel/Margin/Column") as VBoxContainer
	_expect(column != null, "military map toolbar keeps a fixed button column")
	_expect(column.get_child_count() == 7, "toolbar exposes seven military layer toggles")
	for child in column.get_children():
		var button := child as Button
		_expect(button != null and button.focus_mode == Control.FOCUS_NONE,
			"map layer toggles stay outside the keyboard focus chain")
		_expect(button != null and button.icon != null and not button.tooltip_text.is_empty(),
			"every map layer toggle has an icon and a readable tooltip")
	toolbar.set_available(true)
	_expect(toolbar.visible, "toolbar becomes visible when military layers are available")
	toolbar.set_layer_visibility(&"front", false)
	_expect(not toolbar.layer_visibility().get("front", true),
		"front visibility is stored as presentation state")
	toolbar.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	print("military map toolbar: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
