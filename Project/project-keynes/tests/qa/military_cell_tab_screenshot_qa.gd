extends SceneTree

## 地块档案「军事」页的视觉验收（需要渲染，不要加 --headless）。
##
## 把生产用的 military_cell_ledger.tscn 放进两张真实页宽里截图：
##   1280×720 右侧分栏后详情页约 424 px（单列），1920×1080 约 604 px（双列）。
## 数据是固定 fixture —— 这页只读视图模型的输出，所以 fixture 足以验证视觉：
## 驻军条 / 两支部队（其中一支外国）/ 两个训练订单 / 三行官营建筑
## （兵营=拆除、城防=升级、军校=锁着），另加一张“城防在建”的变体。
##
##   godot --path Project/project-keynes --resolution 1920x1080 \
##     -s res://tests/qa/military_cell_tab_screenshot_qa.gd

const SCENE := "res://scenes/ui/military_cell_ledger.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"
const OUTPUT := "res://tmp/military_cell_tab_qa"
const PARCHMENT := Color(0.93, 0.87, 0.73, 1.0)
## 页宽 = 右侧面板宽 − 目录列 − 分栏间距；这两个值取自 1280×720 与 1920×1080。
const PAGE_WIDTHS := [424.0, 604.0]
const PAGE_HEIGHT := 360.0
## 首帧生长 0.32s + 值补间 0.18s，截图前等它们落定。
const SETTLE_SECONDS := 0.55

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	root.size = Vector2i(1920, 1080)
	for width in PAGE_WIDTHS:
		await _run_width(int(width))
	await _run_width(424, "building")
	await _run_width(424, "start")
	_finish()


func _run_width(width: int, state: String = "default") -> void:
	var backdrop := ColorRect.new()
	backdrop.color = PARCHMENT
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.theme = load(THEME) as Theme
	root.add_child(backdrop)
	await process_frame
	var frame := PanelContainer.new()
	frame.theme_type_variation = &"PKArchivePage"
	frame.clip_contents = true
	frame.custom_minimum_size = Vector2(width, PAGE_HEIGHT)
	frame.size = Vector2(width, PAGE_HEIGHT)
	frame.position = Vector2(40.0, 40.0)
	backdrop.add_child(frame)
	await process_frame
	var ledger := (load(SCENE) as PackedScene).instantiate() as Control
	frame.add_child(ledger)
	await process_frame
	var min_width := ledger.get_combined_minimum_size().x
	if min_width > float(width):
		_failures.append("ledger needs %.0f px but the column is %d px" % [min_width, width])
	ledger.set_model(_model(state))
	await _settle()
	# 真实面板里台账是 VBox 的子节点、按内容高度排布，所以截图框也收到内容高度，
	# 否则会看到一大片空白纸（只在 QA 里出现的假象）。
	var content_height: float = ledger.get_combined_minimum_size().y + 6.0
	frame.custom_minimum_size = Vector2(width, content_height)
	frame.size = Vector2(width, content_height)
	await process_frame
	if ledger.size.x > float(width) + 1.0:
		_failures.append("ledger overflows its column (%s > %d)" % [str(ledger.size), width])
	print("[military-cell-qa] %s %d: size=%s min=%s" % [
		state, width, str(ledger.size), str(min_width)])
	await _capture("%s_%d" % [state, width])
	ledger.queue_free()
	backdrop.queue_free()
	await process_frame


func _settle() -> void:
	await create_timer(SETTLE_SECONDS).timeout
	await process_frame


func _capture(label: String) -> void:
	var shot := root.get_texture().get_image()
	if shot == null or shot.is_empty():
		_failures.append("could not capture %s" % label)
		return
	var path := "%s/%s.png" % [OUTPUT, label]
	if shot.save_png(path) != OK:
		_failures.append("could not write %s" % path)
		return
	print("[military-cell-qa] wrote %s" % path)


func _model(state: String) -> Dictionary:
	if state == "start":
		return _start_model()
	return {
		"cell": 12,
		"garrison": {
			"present": 37, "posts": 50, "ratio": 0.74, "pending": 4,
			"open": 9, "quota": 5, "barracks_count": 2, "training_speed": 1.0,
			"paused": false, "disrepair": false, "occupied": false,
		},
		"troops": [
			{"handle": 4294967303, "name": "第 7 军", "heads": 1200, "foreign": false},
			{"handle": 4294967304, "name": "第 12 军", "heads": 300, "foreign": true},
		],
		"training": [
			{"id": 1, "from": "民兵", "to": "长枪兵", "icon": "military.unit.spearmen",
				"count": 12, "progress": 0.27, "remaining_days": 22, "foreign": false},
			{"id": 2, "from": "民兵", "to": "骑兵", "icon": "military.unit.cavalry",
				"count": 6, "progress": 0.82, "remaining_days": 3, "foreign": false},
		],
		"buildings": [
			{"role": "barracks", "label": "兵营", "icon": "military.building.palisade_barracks",
				"name": "戍卫营", "count": 2, "effect": "兵额 +25",
				"action": "rebuild", "primary_action": "rebuild",
				"action_label": "再建", "target": 2, "can_demolish": true,
				"demolish_target": 2, "pending_days": -1,
				"materials_text": "木材 30 · 砖石 40 · 熟铁 5",
				"cost_days_text": "30 日", "cost_reason": "",
				"tooltip": "戍卫营\n效果：兵额 +25\n"
					+ "建材：木材 30（国库 18 / 市购 12）\n"
					+ "建材：砖石 40（国库 40）\n"
					+ "建材：熟铁 5（国库 0 / 缺 5）\n"
					+ "建材合计：75，缺 5\n现金：750（一次性）\n"
					+ "维护：0.15/日（现有 2 座，共 0.3/日）\n工期：30 日"},
			{"role": "fortification", "label": "城防", "icon": "military.building.stone_wall",
				"name": "石砌城墙", "count": 1, "effect": "守备 +60%",
				"action": "building" if state == "building" else "upgrade",
				"primary_action": "none" if state == "building" else "upgrade",
				"action_label": "升级", "target": 3, "can_demolish": true,
				"demolish_target": 3,
				"pending_days": 18 if state == "building" else -1,
				"materials_text": "原石 120 · 砖石 60 · 青铜炮 4",
				"cost_days_text": "30 日",
				"cost_reason": "" if state != "building" else "",
				"tooltip": "石砌城墙\n效果：守备 +60%\n"
					+ "建材：原石 120（国库 90 / 市购 30）\n"
					+ "建材：砖石 60（国库 60）\n"
					+ "建材：青铜炮 4（国库 1 / 缺 3）\n"
					+ "建材合计：184，缺 3\n现金：1840（一次性）\n"
					+ "维护：0.15/日\n工期：30 日"},
			{"role": "war_college", "label": "军校", "icon": "military.building.academy",
				"name": "武学馆", "count": 0, "effect": "训练 ×1.5", "action": "locked",
				"primary_action": "none", "action_label": "", "target": -1,
				"can_demolish": false, "demolish_target": -1, "pending_days": -1,
				"materials_text": "", "cost_days_text": "", "cost_reason": "",
				"tooltip": "需 常备军"},
		],
	}


## 开局：没有兵营、没有部队、没有训练订单。这一页仍然要给数字（全是 0），
## 三行建筑也要写清"下一档叫什么、能给多少"，否则只剩三个类目名。
func _start_model() -> Dictionary:
	return {
		"cell": 12,
		"garrison": {
			"present": 0, "posts": 0, "ratio": 0.0, "pending": 0,
			"open": 0, "quota": 0, "barracks_count": 0, "training_speed": 1.0,
			"paused": false, "disrepair": false, "occupied": false,
		},
		"troops": [],
		"training": [],
		"buildings": [
			{"role": "barracks", "label": "兵营", "icon": "military.building.tribal_lodge",
				"name": "战士营地", "count": 0, "effect": "兵额 +4", "action": "build",
				"primary_action": "build", "action_label": "建造", "target": 0,
				"can_demolish": false, "demolish_target": -1, "pending_days": -1,
				"materials_text": "木材 20 · 草皮 10",
				"cost_days_text": "10 日", "cost_reason": "",
				"tooltip": "战士营地\n效果：兵额 +4\n"
					+ "建材：木材 20（国库 20）\n"
					+ "建材：草皮 10（国库 10）\n"
					+ "建材合计：30\n现金：300（一次性）\n"
					+ "维护：0.02/日\n工期：10 日"},
			{"role": "fortification", "label": "城防", "icon": "military.building.rampart",
				"name": "夯土城垣", "count": 0, "effect": "守备 +30%",
				"action": "locked", "primary_action": "none", "action_label": "",
				"target": -1, "can_demolish": false, "demolish_target": -1,
				"pending_days": -1, "materials_text": "", "cost_days_text": "",
				"cost_reason": "", "tooltip": "需 夯土城垣"},
			{"role": "war_college", "label": "军校", "icon": "military.building.academy",
				"name": "武学馆", "count": 0, "effect": "训练 ×1.5", "action": "locked",
				"primary_action": "none", "action_label": "", "target": -1,
				"can_demolish": false, "demolish_target": -1, "pending_days": -1,
				"materials_text": "", "cost_days_text": "", "cost_reason": "",
				"tooltip": "需 常备军"},
		],
	}


func _finish() -> void:
	print("=== military cell tab screenshot qa: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
