extends SceneTree

## 议和窗口的视觉验收（需要渲染，不要加 --headless）。
##
##   godot --path Project/project-keynes -s res://tests/qa/military_peace_window_screenshot_qa.gd
##
## 把生产用的 military_peace_window.tscn 放在真实视口里截图，覆盖：
##   · 1280×720 / 1920×1080 两种窗口尺寸（左停靠，地图仍是主画面）
##   · 空白草案（白和平）与「已点选两格割地」两个状态
## 并断言：面板不出视口、纸张边框不裁内容、清单与页脚按钮可见、地图至少留 45% 宽。
## 数据是固定 fixture——窗口只读视图模型，fixture 足以验证版面与材质。

const SCENE := "res://scenes/ui/military_peace_window.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"
const OUTPUT := "res://tmp/military_peace_qa"
const PARCHMENT := Color("e4d9bf")
const SETTLE_SECONDS := 0.55
const DAY := 404
const WAR_ID := 7
const Q16 := 65536
const PLAYER_SLOT := 0
const ENEMY_SLOT := 3
const CANDIDATES := [3, 4, 5]
const ENEMY_OWNED := [3, 4, 5, 9, 10, 11, 15, 16, 17, 21, 22, 23]
const SIZES := [Vector2i(1600, 900), Vector2i(2400, 1350)]

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for size in SIZES:
		await _run_size(size)
	for failure in _failures:
		print("  [FAIL] %s" % failure)
	print("military peace window qa: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _run_size(size: Vector2i) -> void:
	DisplayServer.window_set_size(size)
	root.size = size
	await _settle_viewport()
	# The project runs a 1.25× desktop scale, so a 1600 px window is a 1280 px UI.
	# Every geometry assertion below is in that logical space.
	var logical := root.get_visible_rect().size
	print("  [info] window %s -> UI %s" % [size, logical])
	var backdrop := ColorRect.new()
	backdrop.color = PARCHMENT
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.theme = load(THEME) as Theme
	root.add_child(backdrop)
	await process_frame
	var window := (load(SCENE) as PackedScene).instantiate() as Control
	backdrop.add_child(window)
	await process_frame
	window.set_player_controller(Node.new())
	window.open(WAR_ID, _fixture_model())
	await _settle()
	await _capture("peace_%d" % int(logical.x))
	_check_layout(window, logical)
	# 第二张：点选两格割地后的草案（清单勾选 + 条款总价 + 页脚读数）。
	window.call("handle_map_cell", CANDIDATES[0])
	window.call("handle_map_cell", CANDIDATES[2])
	await _settle()
	await _capture("peace_%d_picked" % int(logical.x))
	_check_draft(window)
	window.close_panel()
	backdrop.queue_free()
	await process_frame


func _check_layout(window: Control, viewport_size: Vector2) -> void:
	var tag := "%d" % int(viewport_size.x)
	if not window.visible:
		_failures.append("%s: window did not open" % tag)
		return
	var rect := window.get_global_rect()
	var viewport := Rect2(Vector2.ZERO, viewport_size)
	if not viewport.grow(1.0).encloses(rect):
		_failures.append("%s: window %s escapes the viewport %s" % [tag, rect, viewport])
	var share := 1.0 - (rect.position.x + rect.size.x) / viewport_size.x
	if share < 0.45:
		_failures.append("%s: window covers too much map (map share %.2f)" % [tag, share])
	if window.get_combined_minimum_size().x > rect.size.x + 1.0:
		_failures.append("%s: content minimum %s exceeds the panel" % [tag,
			window.get_combined_minimum_size()])
	var submit := window.get_node("%Submit") as Button
	if submit == null or not submit.is_visible_in_tree():
		_failures.append("%s: submit button is not visible" % tag)
	elif not rect.grow(-8.0).encloses(submit.get_global_rect()):
		_failures.append("%s: submit %s sits outside %s" % [tag,
			submit.get_global_rect(), rect.grow(-8.0)])
	var list := window.get_node("%CedingList") as Control
	if list == null or not list.is_visible_in_tree():
		_failures.append("%s: cession list is not visible" % tag)
	else:
		# Three candidates: the last row must not land on the clip line.
		var scroll := window.get_node("%CedeScroll") as ScrollContainer
		var needed := list.get_combined_minimum_size().y
		if scroll != null and needed > scroll.size.y + 0.5:
			_failures.append("%s: cession list %.1f px taller than its %.1f px viewport"
				% [tag, needed, scroll.size.y])
	# Narrow docks keep two KPIs on one line and fold the other two numbers into
	# the 战况 header; wide docks show all four in a row.
	var expected_kpis := 2 if window.size.x < 640.0 else 4
	for index in range(4):
		# NodePath first: "%Kpi0" inside a format string is a GDScript format bug.
		var kpi := window.get_node_or_null(NodePath("%Kpi" + str(index))) as Control
		if kpi == null:
			_failures.append("%s: KPI%d node is missing" % [tag, index])
		elif kpi.is_visible_in_tree() != (index < expected_kpis):
			_failures.append("%s: KPI%d visible=%s (expected %s)" % [tag, index,
				kpi.is_visible_in_tree(), index < expected_kpis])
	_check_frames(window, tag)
	_check_text(window, tag)


func _check_draft(window: Control) -> void:
	var snapshot: Dictionary = window.call("debug_snapshot")
	var selected: PackedInt32Array = snapshot.get("selected", PackedInt32Array())
	if selected.size() != 2:
		_failures.append("picked draft holds %d cells (expected 2)" % selected.size())
	var terms: Array = snapshot.get("terms", [])
	if terms.size() != 2 or String((terms[0] as Dictionary).get("kind", "")) != "cede":
		_failures.append("picked draft is not encoded as two cede terms: %s" % [terms])
	var white := window.get_node("%PeaceWhite") as CheckBox
	if white != null and white.button_pressed:
		_failures.append("white peace stayed ticked next to ceded land")


func _check_text(window: Control, tag: String) -> void:
	var title := window.get_node("%PeaceTitle") as Label
	if title == null or title.text.find("议和") < 0:
		_failures.append("%s: title does not read 议和 (%s)" % [tag,
			title.text if title != null else "missing"])
	var price := window.get_node("%TermsPrice") as Label
	if price == null or price.text.find("条款总价") < 0:
		_failures.append("%s: terms price line is missing (%s)" % [tag,
			price.text if price != null else "missing"])
	var band := window.get_node("%FooterBand") as Label
	if band == null or band.text.is_empty():
		_failures.append("%s: acceptance band is empty" % tag)


## 九宫纸边按 48 * frame_scale 像素画出来，画在边下面的内容等于没画。
## 与军事工作台的截图 harness 同一条规则：每个纸框的内容都必须让开这条边。
func _check_frames(window: Control, tag: String) -> void:
	var frames: Array = []
	_collect_frames(window, frames)
	for node in frames:
		var panel := node as Control
		if not panel.is_visible_in_tree() or panel.size.x < 8.0 or panel.size.y < 8.0:
			continue
		var border := float(panel.get("frame_scale")) * 48.0
		var inner := panel.get_global_rect().grow(-border + 1.0)
		for child in panel.find_children("*", "Control", true, false):
			var control := child as Control
			if control == null or not control.is_visible_in_tree():
				continue
			# Scrolled content legitimately extends past its viewport; the
			# ScrollContainer's own rect is what has to stay inside the frame.
			if _clipped_by_scroll(control, panel):
				continue
			var child_rect := control.get_global_rect()
			if child_rect.size.x < 2.0 or child_rect.size.y < 2.0:
				continue
			if child_rect.end.y > inner.end.y + 1.0 or child_rect.end.x > inner.end.x + 1.0:
				_failures.append("%s: '%s' is drawn under the paper frame of '%s'"
					% [tag, control.name, panel.name])


func _clipped_by_scroll(node: Control, stop: Control) -> bool:
	var cursor := node.get_parent()
	while cursor != null and cursor != stop:
		if cursor is ScrollContainer:
			return true
		cursor = cursor.get_parent()
	return false


func _collect_frames(node: Node, out: Array) -> void:
	if node is PanelContainer and node.get_script() != null \
			and String(node.get_script().resource_path).ends_with("military_frame_panel.gd"):
		out.append(node)
	for child in node.get_children():
		_collect_frames(child, out)


func _settle_viewport() -> void:
	var last := Vector2.ZERO
	for _i in range(40):
		await process_frame
		var now := root.get_visible_rect().size
		if now == last and now.x > 1.0:
			return
		last = now


func _settle() -> void:
	for _i in range(4):
		await process_frame
	await create_timer(SETTLE_SECONDS).timeout


func _capture(label: String) -> void:
	for _i in range(2):
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUTPUT, label]
	if image == null or image.is_empty() or image.save_png(path) != OK:
		_failures.append("failed to capture %s" % path)


func _fixture_model() -> Dictionary:
	var owners := PackedInt32Array()
	for index in range(24):
		owners.append(ENEMY_SLOT if index in ENEMY_OWNED else PLAYER_SLOT)
	return {
		"country_handle": 0x100000000,
		"country_slot": PLAYER_SLOT,
		"current_day": DAY,
		"population": 214000,
		"good_ids": PackedStringArray(["grain"]),
		"cell_names": {3: "北岸", 4: "南岸", 5: "渡口"},
		"country_names": {ENEMY_SLOT: "赤原"},
		"army_names": {},
		"military": {
			"available": true,
			"facade": null,
			"country_handle": 0x100000000,
			"country_handles": {ENEMY_SLOT: 0x300000001},
			"region_names": {3: "青阳", 4: "青阳", 5: "洛雁"},
			"cell_owners": {"owners": owners},
			"snapshot": {
				"ok": true,
				"country_slot": PLAYER_SLOT,
				"country_handle": 0x100000000,
				"wars": [{
					"war_id": WAR_ID,
					"attacker_slot": PLAYER_SLOT,
					"defender_slot": ENEMY_SLOT,
					"start_day": 351,
					"score_q16": int(0.27 * Q16),
					"attacker_losses": 2140,
					"defender_losses": 3980,
					"fully_occupied": false,
				}],
				"wars_active": 1,
				"control": {
					"cells": PackedInt32Array(CANDIDATES),
					"controller_slots": PackedInt32Array(
						[PLAYER_SLOT, PLAYER_SLOT, PLAYER_SLOT]),
				},
				"engagements": [{
					"cell_a": 3, "cell_b": 2, "attacker_slot": PLAYER_SLOT,
					"defender_slot": ENEMY_SLOT, "progress_q16": int(0.62 * Q16),
					"start_day": 388, "battle": true, "zone_a": "青阳", "zone_b": "青阳",
				}],
				"front_edge_keys": PackedInt32Array([3 * 6, 3 * 6 + 1]),
				"front_edge_progress": PackedByteArray([200, 255]),
				"daily_wage": 4200,
			},
			"armies": [],
			"catalog": {"ok": true, "units": [], "categories": []},
			"researched_tech_ids": PackedStringArray(),
			"tech_gate_known": false,
		},
	}
