extends SceneTree

## AI 生成设置必须在「游戏设置」里可达，且不依赖任何事件入口。
## 只验证 UI 结构：不点「保存」，避免测试覆盖玩家本机的 user://ai_credentials.cfg。

const PauseMenuScene := preload("res://scenes/ui/pause_menu.tscn")

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var menu = PauseMenuScene.instantiate()
	root.add_child(menu)

	menu._show_settings()
	_expect("settings page exposes an AI generation entry",
		_find_button(menu, "AI 生成设置") != null)

	menu._show_ai_settings()
	var edits: Array = []
	_collect(menu, "LineEdit", edits)
	var toggles: Array = []
	_collect(menu, "CheckButton", toggles)
	_expect("AI page shows three text fields and three image fields", edits.size() == 6)
	_expect("AI page shows both enable toggles", toggles.size() == 2)
	_expect("AI page keeps a save action", _find_button(menu, "保存") != null)

	menu.free()
	print("pause menu ai settings: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _collect(node: Node, type_name: String, out: Array) -> void:
	if node.is_class(type_name):
		out.append(node)
	for child in node.get_children():
		_collect(child, type_name, out)


func _find_button(node: Node, text_value: String) -> Button:
	if node is Button:
		var button := node as Button
		if button.text == text_value:
			return button
		# pause_menu_button.tscn 把文案放在 Row/Label 子节点上。
		var label := button.get_node_or_null("Row/Label") as Label
		if label != null and label.text == text_value:
			return button
	for child in node.get_children():
		var found := _find_button(child, text_value)
		if found != null:
			return found
	return null


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("[FAIL] %s" % label)
