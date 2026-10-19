extends SceneTree

## 悬停卡截图 QA：真实 player_game.tscn，验证放置/翻转/与面板互斥，并输出 png。
## 用渲染模式跑：godot --path . --script tests/cell_hover_card_screenshot_qa.gd

const OUTPUT := "res://tmp/cell_hover_qa"
const SIZES := [Vector2i(1366, 768), Vector2i(1920, 1080)]
const WORLD_READY_TIMEOUT_MSEC := 180000

var _failures := PackedStringArray()
var _card: CellHoverCard


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	root.size = SIZES[1]
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	root.add_child(game)
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	var deadline := Time.get_ticks_msec() + WORLD_READY_TIMEOUT_MSEC
	while runtime.get("_current_map") == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if runtime.get("_current_map") == null:
		push_error("[cell-hover-qa] world never became ready")
		quit(1)
		return
	var ui := game.get_node("UI") as GameUIManager
	var clock := game.get_node("WorldClock") as WorldClock
	# _current_map 早于 _on_world_ready 里的 set_world_context 落地，
	# 必须再等悬停卡真正拿到依赖，否则读到的是未配置状态。
	var card: CellHoverCard = null
	while Time.get_ticks_msec() < deadline:
		card = ui.get("_cell_hover_card") as CellHoverCard
		if card != null and card.get("_map") != null \
				and card.get("_view_model") != null and card.get("_camera") != null:
			break
		await process_frame
	clock.pause(true)
	if card == null:
		push_error("[cell-hover-qa] GameUIManager did not create the hover card")
		quit(1)
		return
	if card.get("_map") == null or card.get("_view_model") == null \
			or card.get("_camera") == null:
		push_error("[cell-hover-qa] hover card was never configured (map/vm/camera)")
		quit(1)
		return
	_card = card
	_expect(card.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"hover card stays click-through")
	_expect(not card.visible, "hover card starts hidden")

	var map: MapData = runtime.get("_current_map")
	var home := map.cell_at(int(runtime.call("_resolve_player_start_cell")))
	if home == null:
		push_error("[cell-hover-qa] no player start cell")
		quit(1)
		return
	# 建图完成后紧接一段异步启动流程（自动选中起始格 → 打开档案面板），
	# 悬停卡的放置检查必须在它收敛之后再做，否则关掉的面板会被重新打开。
	var settle_deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < settle_deadline and ui.get("_selected_cell") == null:
		await process_frame
	await create_timer(0.2).timeout
	ui.hide_cell_panel()
	await create_timer(0.35).timeout
	var right_panel := ui.get("_right_panel") as Control
	_expect(right_panel != null and not right_panel.visible,
		"inspector closed before hover placement checks")

	for viewport in SIZES:
		DisplayServer.window_set_size(viewport)
		root.size = viewport
		await create_timer(0.4).timeout
		ui.call("_layout_right_panel")
		await process_frame
		var safe := ui.map_safe_area()

		# 1) 常规位置：指针在左上，卡片右下展开。
		print("[cell-hover-qa] diag map=%s vm=%s camera=%s safe=%s" % [
			card.get("_map") != null, card.get("_view_model") != null,
			card.get("_camera") != null, safe])
		_expect(card.debug_show_cell(int(home.index), Vector2(420, 300)),
			"card shows at %s" % viewport)
		var rect := Rect2(card.position, card.size)
		print("[cell-hover-qa] pos=%s vp=%s win=%s root=%s hud=%s" % [
			card.position, card.get_viewport_rect().size,
			DisplayServer.window_get_size(), root.size,
			(card.get_parent() as Control).global_position])
		_expect(safe.encloses(rect), "card stays inside the map safe area: %s" % rect)
		await _capture("default_%dx%d" % [viewport.x, viewport.y])

		# 2) 右下角：x / y 同时翻转。
		var near_corner := Vector2(safe.end.x - 40.0, safe.end.y - 40.0)
		_expect(card.debug_show_cell(int(home.index), near_corner),
			"card shows near the bottom-right corner")
		var flipped := Rect2(card.position, card.size)
		_expect(flipped.end.x <= safe.end.x + 0.5 and flipped.end.y <= safe.end.y + 0.5,
			"flipped card stays inside the safe area: %s" % flipped)
		_expect(flipped.position.x < near_corner.x and flipped.position.y < near_corner.y,
			"flipped card sits left/above the pointer")
		await _capture("flip_%dx%d" % [viewport.x, viewport.y])

		# 3) 右侧档案面板打开 → 悬停卡必须让位。
		ui.show_cell_panel(home)
		await create_timer(0.3).timeout
		_expect(not card.visible, "card hides while the inspector is open")
		ui.hide_cell_panel()
		await create_timer(0.3).timeout

	await _test_live_hover(card, runtime)

	_push_error_summary()
	quit(0 if _failures.is_empty() else 1)


## 真实悬停链路：把指针移到某个可见格的屏幕位置，让 _input + _process 状态机自己出卡。
## debug_show_cell 只证明渲染，这一步才证明"鼠标停在格子上会弹卡"。
func _test_live_hover(card: CellHoverCard, runtime: WorldRuntimeHost) -> void:
	var camera := card.get("_camera") as MapCamera
	var map: MapData = runtime.get("_current_map")
	var hex_size := float(card.get("_hex_size"))
	var safe_call: Callable = card.get("_safe_area")
	var safe: Rect2 = safe_call.call()
	var pick := safe.grow(-40.0)
	var target := -1
	var screen := Vector2.ZERO
	for idx in mini(map.cell_count(), 6000):
		if not card.is_cell_available(idx):
			continue
		var cell := map.cell_at(idx)
		if cell == null:
			continue
		var pos := camera.safe_world_to_screen(
			HexUtils.cube_to_world(cell.q, cell.r, hex_size))
		if not pick.has_point(pos):
			continue
		target = idx
		screen = pos
		break
	if target < 0:
		print("[cell-hover-qa] SKIP live hover: no visible cell inside the safe area")
		return
	card.dismiss(true)
	root.warp_mouse(screen)
	await process_frame
	if root.get_mouse_position().distance_to(screen) > 4.0:
		print("[cell-hover-qa] SKIP live hover: window refuses pointer warp")
		return
	var motion := InputEventMouseMotion.new()
	motion.position = screen
	motion.global_position = screen
	motion.relative = Vector2(1.0, 0.0)
	motion.device = 0
	Input.parse_input_event(motion)
	await create_timer(0.45).timeout
	var blocked_call: Callable = card.get("_blocked")
	print("[cell-hover-qa] live diag zoom=%.3f panning=%s zooming=%s blocked=%s hovered=%s proc=%s ptr=%s" % [
		camera.zoom.x, camera.is_panning(), camera.is_zooming(), blocked_call.call(),
		root.gui_get_hovered_control(), card.is_processing(), root.get_mouse_position()])
	_expect(card.visible, "live hover shows the card")
	_expect(card.current_cell_index() == target,
		"live hover resolves the cell under the pointer (%d vs %d)"
			% [card.current_cell_index(), target])
	await _capture("live_1920x1080")


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var shot := root.get_texture().get_image()
	_expect(shot != null and shot.save_png("%s/%s.png" % [OUTPUT, label]) == OK,
		"cell hover capture %s" % label)
	if shot != null:
		_save_zoom(shot, label)
	print("[cell-hover-qa] %s" % label)


## 美术复核用的 2× 特写：卡片在 1920 截图上只有 400px 宽，看不清字号与字色。
func _save_zoom(shot: Image, label: String) -> void:
	if _card == null or not _card.visible:
		return
	# 截图是物理像素，Control 坐标是画布空间，中间隔着 content_scale。
	var scale := float(shot.get_width()) / maxf(_card.get_viewport_rect().size.x, 1.0)
	var rect := Rect2i(
		Vector2i((_card.position * scale).round()),
		Vector2i((_card.size * scale).round())).grow(6)
	rect = rect.intersection(Rect2i(Vector2i.ZERO, shot.get_size()))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var crop := shot.get_region(rect)
	crop.resize(crop.get_width() * 2, crop.get_height() * 2, Image.INTERPOLATE_LANCZOS)
	crop.save_png("%s/%s_zoom.png" % [OUTPUT, label])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _push_error_summary() -> void:
	for failure in _failures:
		push_error("[cell-hover-qa] FAIL: %s" % failure)
	print("[cell-hover-qa] %d failures" % _failures.size())
