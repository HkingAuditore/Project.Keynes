extends SceneTree

class Host extends Node:
	var _hud_layout_component = preload("res://scripts/ui/game_hud_layout.gd").new()
	var _map_overlay_toolbar: MapOverlayToolbar
	var _cell_hover_card: CellHoverCard

var _failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _run() -> void:
	var settings := root.get_node("GameSettings")
	var original: bool = settings.values().get("reduce_motion", false)
	# Only change this process's setting; never persist test preferences.
	settings.get("_settings")["reduce_motion"] = false
	var host := Host.new()
	root.add_child(host)
	var ui_root := Control.new()
	ui_root.name = "UIRoot"
	host.add_child(ui_root)
	var layer := Control.new()
	layer.name = "PanelLayer"
	ui_root.add_child(layer)
	var toolbar := preload("res://scenes/ui/map_overlay_toolbar.tscn").instantiate() as MapOverlayToolbar
	ui_root.add_child(toolbar)
	host._map_overlay_toolbar = toolbar
	host._hud_layout_component._viewport = root
	host._hud_layout_component._map_overlay_toolbar = toolbar
	preload("res://scripts/ui/game_ui/overlays.gd").new()._ensure_cell_board(host)
	var board: CellBoard = host._hud_layout_component._cell_board
	var slide := board.get_node("Slide") as Control
	var primary := toolbar.get_node("PrimaryPanel") as Control
	var secondary := toolbar.get_node("SecondaryPanel") as Control
	var secondary_rest := secondary.position
	toolbar._set_category(MapOverlayToolbar.Category.GEOGRAPHY)
	_step_midway(secondary, UITokens.ANIM_FAST)
	var request := toolbar._active_request.duplicate(true)
	board.show_board(true)
	_expect(primary.mouse_behavior_recursive == Control.MOUSE_BEHAVIOR_DISABLED,
		"工具栏淡出起始即停止接收输入")
	await _wait_for_animation(primary)
	await _wait_for_animation(secondary)
	await _wait_for_animation(slide)
	_expect(not primary.visible and not secondary.visible, "展板可见时两级工具栏都隐藏")
	_expect(toolbar.visible, "不改派遣等工作区管理的根可见性")
	board.hide_board(false)
	_expect(not primary.visible, "展板退场期间工具栏不提前出现")
	_step_midway(slide, CellBoard.SLIDE_OUT_SEC)
	_expect(board.visible and not primary.visible, "退场中段保持工具栏隐藏")
	await _wait_for_animation(slide)
	await _wait_for_animation(primary)
	await _wait_for_animation(secondary)
	_expect(not board.visible and primary.visible and secondary.visible, "退场后恢复原分类工具栏")
	_expect(is_equal_approx(primary.modulate.a, 1.0), "恢复后透明度完整")
	_expect(secondary.position.is_equal_approx(secondary_rest), "打断次级栏入场后恢复原布局位置")
	_expect(toolbar._active_request == request, "显隐不修改地图图层请求")
	# Reopen in the very same frame that exit starts: the old exit must be cancelled.
	board.show_board(false)
	board.hide_board(false)
	var interrupted_exit := _animation(slide)
	board.show_board(true)
	_expect(interrupted_exit != null and not interrupted_exit.is_valid(), "快速重入取消旧退场动画")
	await _wait_for_animation(slide)
	await _wait_for_animation(primary)
	_expect(board.visible and not primary.visible, "快速重入不被旧退场回调隐藏")
	board.hide_board(true)
	_step_midway(primary, UITokens.ANIM_MED)
	var interrupted_restore := _animation(primary)
	board.show_board(true)
	_expect(interrupted_restore != null and not interrupted_restore.is_valid(), "再次入场取消工具栏恢复动画")
	await _wait_for_animation(primary)
	_expect(not primary.visible, "恢复淡入被再次入场打断后没有迟到回调")
	paused = true
	board.hide_board(false)
	await _wait_for_animation(slide)
	await _wait_for_animation(primary)
	_expect(not board.visible and primary.visible and is_equal_approx(primary.modulate.a, 1.0),
		"暂停期间退场与恢复动画仍能收尾")
	paused = false
	board.show_board(false)
	# Another workspace owns the root: board dismissal must never unhide it.
	toolbar.hide()
	board.hide_board(true)
	await _wait_for_animation(primary)
	_expect(not toolbar.visible, "派遣等界面隐藏工具栏后不能被展板恢复")
	toolbar.show()
	toolbar._set_category(MapOverlayToolbar.Category.NONE)
	await _wait_for_animation(secondary)
	settings.get("_settings")["reduce_motion"] = true
	board.show_board(true)
	_expect(not primary.visible and not secondary.visible, "减少动效时立即隐藏")
	board.hide_board(false)
	_expect(primary.visible and not secondary.visible, "减少动效时立即恢复且不打开已关闭的次级栏")
	settings.get("_settings")["reduce_motion"] = original
	host.free()
	for failure in _failures:
		printerr("[cell-board-toolbar] FAIL: ", failure)
	print("[cell-board-toolbar] ", "PASS" if _failures.is_empty() else "FAIL")
	quit(0 if _failures.is_empty() else 1)

func _animation(control: Control) -> Tween:
	return control.get_meta("_ui_active_tween") as Tween if control.has_meta("_ui_active_tween") else null

func _step_midway(control: Control, duration: float) -> void:
	var tween := _animation(control)
	# A wall-clock timer can resume after the animation in a single slow frame.
	var in_progress := tween != null and tween.is_valid() and tween.custom_step(duration * 0.5)
	_expect(in_progress, "%s 的动画走到一半时仍在进行" % control.name)

func _wait_for_animation(control: Control) -> void:
	var tween := _animation(control)
	if paused and tween != null and tween.is_running():
		var start := tween.get_total_elapsed_time()
		# These two signals bracket an idle frame even when the first precedes
		# the tween's first update. Fail promptly if the tween is paused too.
		await process_frame
		await process_frame
		var advanced := tween.get_total_elapsed_time() > start
		_expect(advanced, "暂停期间 %s 的动画仍在推进" % control.name)
		if not advanced:
			return
	if tween != null and tween.is_running():
		await tween.finished
