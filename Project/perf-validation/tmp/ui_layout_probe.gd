extends Node

# 临时排查脚本：复现"详情框滑入动画把面板缓存到错误 rest position"这个 bug，
# 并验证 GameUIManager._layout_right_panel() + UIAnimation.refresh_rest_position()
# 这套修复是否真的能让 fade_slide_in 收尾时停在正确坐标上。

const InspectorPanelScene := preload("res://scenes/ui/inspector_panel.tscn")

var _canvas_layer: CanvasLayer
var _ui_root: Control
var _panel_layer: Control


func _ready() -> void:
	_canvas_layer = CanvasLayer.new()
	add_child(_canvas_layer)
	_ui_root = Control.new()
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas_layer.add_child(_ui_root)
	_panel_layer = Control.new()
	_panel_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.add_child(_panel_layer)

	await get_tree().process_frame

	print("[probe] viewport visible_rect = ", get_viewport().get_visible_rect())

	await _run_case_without_fix()
	await _run_case_with_fix()

	print("[probe] done, quitting.")
	get_tree().quit(0)


func _run_case_without_fix() -> void:
	print("--- case A: 复现原始 bug（不调用 _layout_right_panel / refresh_rest_position）---")
	var panel := InspectorPanelScene.instantiate() as Control
	# 复刻 player_game.tscn 里 RightPanel 的初始状态：一路 visible=false 挂在树上，
	# 直到玩家第一次点地块才由 show_cell_panel() -> fade_slide_in 打开。
	panel.visible = false
	_panel_layer.add_child(panel)
	await get_tree().process_frame
	await get_tree().process_frame

	var expected: Rect2 = panel.get_rect()
	print("[case-A] hidden 状态下锚点算出的“应该在”的 rect = ", expected)

	# 模拟 show_cell_panel()：不做任何显式重新排布，直接调用原始 fade_slide_in。
	UIAnimation.fade_slide_in(panel, Vector2(24.0, 0.0), 0.05)
	await get_tree().create_timer(0.2).timeout

	print("[case-A] fade_slide_in 收尾后的实际 rect          = ", panel.get_rect())
	print("[case-A] 两者一致 = ", panel.get_rect().position.is_equal_approx(expected.position))

	panel.queue_free()
	await get_tree().process_frame


func _run_case_with_fix() -> void:
	print("--- case B: 应用修复（_layout_right_panel 等价逻辑 + refresh_rest_position）---")
	var panel := InspectorPanelScene.instantiate() as Control
	panel.visible = false
	_panel_layer.add_child(panel)
	await get_tree().process_frame
	await get_tree().process_frame

	# 等价于 GameUIManager._layout_right_panel()。
	panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -460.0
	panel.offset_top = 68.0
	panel.offset_right = 0.0
	panel.offset_bottom = -12.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_END
	UIAnimation.refresh_rest_position(panel)

	var expected: Rect2 = panel.get_rect()
	print("[case-B] 显式重新排布后的 rect                    = ", expected)

	UIAnimation.fade_slide_in(panel, Vector2(24.0, 0.0), 0.05)
	await get_tree().create_timer(0.2).timeout

	print("[case-B] fade_slide_in 收尾后的实际 rect          = ", panel.get_rect())
	print("[case-B] 两者一致 = ", panel.get_rect().position.is_equal_approx(expected.position))

	panel.queue_free()
	await get_tree().process_frame
