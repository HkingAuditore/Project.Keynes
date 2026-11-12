extends SceneTree

## 军务档案页的视觉验收（需要渲染，不要加 --headless）。
##
## 把生产用的 military_dossier.tscn 放进两张真实页宽里截图：
##   1280×720 右侧分栏后详情页约 424 px（单列），1920×1080 约 604 px（双列）。
## 数据是固定 fixture —— 这页只读 view model 的输出，所以 fixture 足以验证视觉。
##
##   godot --path Project/project-keynes --resolution 1920x1080 \
##     -s res://tests/qa/military_dossier_screenshot_qa.gd

const SCENE := "res://scenes/ui/military_dossier.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"
const OUTPUT := "res://tmp/military_dossier_qa"
const PARCHMENT := Color(0.93, 0.87, 0.73, 1.0)
## 页宽 = 右侧面板宽 − 目录列 − 分栏间距。424/604 取自生产布局；
## 520 是窄栏下限，21:9 用 2560×1080 检查宽屏下不产生横向裁切。
const VIEWPORTS := [
	{"label": "1280", "window": Vector2i(1920, 1080), "page_width": 424.0},
	{"label": "1920", "window": Vector2i(1920, 1080), "page_width": 604.0},
	{"label": "narrow520", "window": Vector2i(1920, 1080), "page_width": 520.0},
	{"label": "21x9", "window": Vector2i(2560, 1080), "page_width": 604.0},
]
## 比页面内容高一点：截图要看到整页（动作按钮与同格名录也在画面里）。
const PAGE_HEIGHT := 940.0
## 卡片与图表首帧会「生长」一次（0.32s）+ 值补间（0.18s），截图前等它们落定。
const SETTLE_SECONDS := 0.55

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	for viewport in VIEWPORTS:
		await _run_width(viewport)
	_finish()


func _run_width(viewport: Dictionary) -> void:
	var label := String(viewport.get("label", "viewport"))
	var window: Vector2i = viewport.get("window", Vector2i(1920, 1080))
	var width := int(viewport.get("page_width", 424.0))
	DisplayServer.window_set_size(window)
	root.size = window
	await process_frame
	var backdrop := ColorRect.new()
	backdrop.color = PARCHMENT
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.theme = load(THEME) as Theme
	root.add_child(backdrop)
	await process_frame
	# 与真实挂载一致：DetailShell 是一个裁切的档案页（PKArchivePage），
	# 撕纸超出页面的部分会被裁掉，而不是像 MarginContainer 那样画到外面。
	var frame := PanelContainer.new()
	frame.theme_type_variation = &"PKArchivePage"
	frame.clip_contents = true
	frame.set_anchors_preset(Control.PRESET_TOP_LEFT)
	frame.custom_minimum_size = Vector2(width, PAGE_HEIGHT)
	frame.size = Vector2(width, PAGE_HEIGHT)
	frame.position = Vector2(40.0, 40.0)
	backdrop.add_child(frame)
	await process_frame
	var page := (load(SCENE) as PackedScene).instantiate() as Control
	frame.add_child(page)
	await process_frame
	# 页面用锚定布局（不是容器），所以最小宽度要看滚动区：它 + 页边距才是真实需求。
	var scroll_min := (page.get_node("%Scroll") as Control).get_combined_minimum_size().x
	if scroll_min + 60.0 > float(width):
		_failures.append("%s content needs %.0f px but the column is %d px"
			% [label, scroll_min + 60.0, width])

	page.set_model(_army_payload())
	await _settle()
	_dump_layout(label, page, "army")
	await _capture("army_%s" % label)
	var explore := page.get_node("%ExploreButton") as Button
	if explore == null or not explore.visible or explore.disabled:
		_failures.append("%s explore button is not available" % label)
	elif explore.custom_minimum_size.y < 44.0:
		_failures.append("%s explore hit target is %.1f dp" % [label, explore.custom_minimum_size.y])
	page.set_order_state({
		"army": 7, "mode": "explore", "radius": 3, "ready": true,
		"cell_count": 37, "message": "点击地图选择探查中心，再确认探查半径。",
	})
	await _settle()
	await _capture("explore_draft_%s" % label)
	if String((page.get_node("%ConfirmOrder") as Button).text) != "确认探查范围":
		_failures.append("%s explore draft lost its confirmation label" % label)
	if not String((page.get_node("%OrderSummary") as Label).text).contains("不会主动进入他国控制格"):
		_failures.append("%s explore draft lost the no-trespass contract" % label)
	page.set_order_state({})
	for state in [
		{"label": "active", "mission": "探路 12/31",
			"note": "探路 · 剩 9 格"},
		{"label": "paused", "mission": "探路暂停 · 交战中", "note": ""},
		{"label": "completed", "mission": "探路完成 · 已返回", "note": ""},
		{"label": "blocked", "mission": "探查结束 · 3 格无法探明 · 已返回", "note": ""},
	]:
		page.set_model(_army_payload(false, String(state.get("mission", "")),
			String(state.get("note", ""))))
		await _settle()
		await _capture("explore_%s_%s" % [String(state.get("label", "")), label])
	var nodes_before := _count_nodes(page)
	page.set_model(_army_payload(true, "探路 13/31", "探路 · 剩 8 格"))
	await _settle()
	if _count_nodes(page) != nodes_before:
		_failures.append("army refresh rebuilt nodes at %s" % label)
	if page.size.x > float(width) + 1.0:
		_failures.append("%s army page overflows its column (%s > %d)"
			% [label, page.size, width])

	page.set_model(_front_payload())
	await _settle()
	_dump_layout(label, page, "front")
	await _capture("front_%s" % label)
	if page.size.x > float(width) + 1.0:
		_failures.append("%s front page overflows its column (%s > %d)"
			% [label, page.size, width])
	page.queue_free()
	backdrop.queue_free()
	await process_frame


func _settle() -> void:
	await create_timer(SETTLE_SECONDS).timeout
	await process_frame


func _dump_layout(column: String, page: Control, tag: String) -> void:
	var scroll := page.get_node("%Scroll") as Control
	print("[military-dossier-qa] %s %s: page=%s pos=%s min=%s scroll_min=%s"
		% [tag, column, str(page.size), str(page.position),
			str(page.get_combined_minimum_size()),
			str(scroll.get_combined_minimum_size())])


func _capture(label: String) -> void:
	var shot := root.get_texture().get_image()
	var path := "%s/%s.png" % [OUTPUT, label]
	if shot == null or shot.is_empty() or shot.save_png(path) != OK:
		_failures.append("could not capture %s" % label)
		return
	print("[military-dossier-qa] wrote %s" % path)


func _army_payload(changed: bool = false, mission_text := "待命", note := "") -> Dictionary:
	return {
		"ok": true, "kind": "army", "identity": "army:7",
		"kicker": "部队档案", "title": "第 7 军", "subtitle": "青川 · 本国 · 推进",
		"icon": &"military.unit.line", "accent": Color(0.48, 0.16, 0.10),
		"focus_cell": 10, "selected": 7,
		"kpis": [
			{"id": "heads", "title": "兵力", "value": 42.0 if changed else 100.0,
				"kind": "count", "caption": "3 类兵种"},
			{"id": "morale", "title": "士气", "value": 0.45, "kind": "percent", "caption": ""},
			{"id": "supply", "title": "补给", "value": 0.42, "kind": "percent",
				"caption": "口粮 60%", "tone": "risk"},
			{"id": "pay", "title": "军饷", "value": 0.7, "kind": "percent", "caption": ""},
		],
		"army": {
			"own": true,
			"peer_stats": [
				{"label": "攻击", "text": "12.4", "color": Color(0.12, 0.075, 0.04)},
				{"label": "防御", "text": "8.1", "color": Color(0.12, 0.075, 0.04)},
				{"label": "速度", "text": "1.5", "color": Color(0.12, 0.075, 0.04)},
			],
			"composition": {"title": "", "total": "100 人", "segments": [
				{"label": "青铜矛兵 Q1", "text": "60", "value": 0.6,
					"color": Color(0.55, 0.42, 0.24)},
				{"label": "骑兵 Q2", "text": "25", "value": 0.25,
					"color": Color(0.36, 0.47, 0.36)},
				{"label": "野战炮 Q1", "text": "15", "value": 0.15,
					"color": Color(0.55, 0.24, 0.18)},
			]},
			"composition_rows": [
				{"id": "0_1", "cells": {
					"unit": {"text": "青铜矛兵", "icon": "military.unit.line"},
					"heads": {"text": "60", "sort": 60.0},
					"quality": {"text": "Q1"}}},
				{"id": "1_2", "cells": {
					"unit": {"text": "骑兵", "icon": "military.unit.mobile"},
					"heads": {"text": "25", "sort": 25.0},
					"quality": {"text": "Q2"}}},
				{"id": "2_1", "cells": {
					"unit": {"text": "野战炮", "icon": "military.unit.artillery"},
					"heads": {"text": "15", "sort": 15.0},
					"quality": {"text": "Q1"}}},
			],
			"supply_rows": [
				{"id": 0, "label": "口粮", "value": 0.66, "text": "20 日", "marker": 0.23,
					"color": Color(0.24, 0.46, 0.40)},
				{"id": 1, "label": "草料", "value": 0.33, "text": "10 日", "marker": 0.23,
					"color": Color(0.69, 0.49, 0.24)},
				{"id": 2, "label": "弹药", "value": 0.26, "text": "8 日", "marker": 0.23,
					"color": Color(0.69, 0.49, 0.24)},
				{"id": 4, "label": "维护", "value": 0.16, "text": "5 日", "marker": 0.23,
					"color": Color(0.55, 0.19, 0.13)},
			],
			"badges": [{"text": "补给低", "accent": Color(0.55, 0.19, 0.13)},
				{"text": "欠饷", "accent": Color(0.55, 0.19, 0.13)}],
			"mission_text": mission_text,
			"note": note,
			"actions": [
				{"id": "locate", "label": "定位", "enabled": true},
				{"id": "move", "label": "移动", "enabled": true},
				{"id": "area", "label": "军事控制", "enabled": true},
				{"id": "explore", "label": "探路", "enabled": true},
				{"id": "stop", "label": "停止任务", "enabled": true},
			],
			"same_cell_rows": [{
				"id": 202,
				"cells": {
					"name": {"text": "第 8 军", "icon": "military.banner", "sub": "青川"},
					"heads": {"text": "40", "sort": 40.0},
					"owner": {"text": "本国"},
				},
			}],
		},
	}


func _front_payload() -> Dictionary:
	return {
		"ok": true, "kind": "front", "identity": "front:4000",
		"kicker": "战线档案", "title": "青川·北境", "subtitle": "本国 ↔ 邻国",
		"icon": &"military.war.front", "accent": Color(0.48, 0.16, 0.10),
		"focus_cell": 44, "selected": 4000,
		"front": {
			"versus": {
				"rows": [
					{"label": "兵力", "own_value": 1000.0, "enemy_value": 600.0,
						"own_text": "1000", "enemy_text": "600"},
					{"label": "攻击", "own_value": 12.4, "enemy_value": 8.1,
						"own_text": "12.4", "enemy_text": "8.1"},
					{"label": "防御", "own_value": 8.1, "enemy_value": 9.4,
						"own_text": "8.1", "enemy_text": "9.4"},
					{"label": "士气", "own_value": 0.6, "enemy_value": 0.4,
						"own_text": "60%", "enemy_text": "40%"},
					{"label": "补给", "own_value": 0.55, "enemy_value": 0.62,
						"own_text": "55%", "enemy_text": "62%"},
				],
				"own_color": Color(0.24, 0.46, 0.40),
				"enemy_color": Color(0.55, 0.19, 0.13),
				"own_label": "我方", "enemy_label": "敌方",
			},
			"footnote": "推进 62% · 交战 3 段 · 接触 9 边",
			"army_rows": [
				{"id": 7, "cells": {
					"name": {"text": "第 7 军"},
					"heads": {"text": "1000", "sort": 1000.0},
					"attack": {"text": "12.4"},
					"owner": {"text": "本国"}}},
				{"id": 8, "cells": {
					"name": {"text": "第 3 军"},
					"heads": {"text": "420", "sort": 420.0},
					"attack": {"text": "5.2"},
					"owner": {"text": "本国"}}},
				{"id": 9, "cells": {
					"name": {"text": "北境守备"},
					"heads": {"text": "600", "sort": 600.0},
					"attack": {"text": "8.1"},
					"owner": {"text": "邻国"}}},
			],
			"army_visible": true,
			"engagement_rows": [
				{"id": 5000000, "cells": {
					"zone": {"text": "青川·北境"},
					"progress": {"text": "62%", "value": 0.62,
						"bar_color": Color(0.24, 0.46, 0.40)},
					"attacker": {"text": "本国"}}},
				{"id": 5000001, "cells": {
					"zone": {"text": "青川·东堡"},
					"progress": {"text": "38%", "value": 0.38,
						"bar_color": Color(0.55, 0.19, 0.13)},
					"attacker": {"text": "邻国"}}},
			],
			"engagement_visible": true,
		},
	}


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _finish() -> void:
	print("=== military dossier screenshot qa: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
