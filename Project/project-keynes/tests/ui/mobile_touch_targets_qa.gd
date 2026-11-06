extends SceneTree

## 触摸命中区验收 harness（问题：经济面板页签「手指点不中」）。
##
## 作用
##   1) 按 --profile/--dpi 复用 MobileUIScaling 的换算口径，把关键面板单独实例化；
##   2) 对每个关键控件测量 get_global_rect()（+ touch_hit_button 扩展出来的命中带），
##      换算成设计像素 / 物理像素 / dp，并按目标档位判 PASS/FAIL：
##        - chrome（页签、关闭、下拉、搜索、列表行）目标 44dp
##        - dense（密集数据网格、滑条行）目标 36dp
##   3) 顺带把 ScrollContainer 的滚动条宽度也测出来（≥32dp 才算「捏得住」）；
##   4) 每张面板存一张 PNG 到 <out>/<label>_<case>.png，肉眼复核。
##
## 运行（在 Project/project-keynes 目录；console 版才有 stdout）：
##   & "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe" `
##       --path . -s res://tests/ui/mobile_touch_targets_qa.gd -- `
##       --out=test_output/mobile_ui/touch --label=after --profile=mobile --dpi=440 --size=2670x1200
##
## 桌面回归：--profile=desktop --size=1600x960，此时所有目标应当保持改动前的尺寸
## （TouchUI 在桌面档是 no-op）。
##
## 退出码：0 = 全部达标；1 = 有未达标项（会逐条列出来）。

const TOUCH_UI_SCRIPT := "res://scripts/ui/touch_ui.gd"

## 面板用例：name → {scene, expected(可选), probes}
## probes 里每项：[节点路径, 人话, 目标档位("chrome"/"dense")]
const CASES := {
	"economy": {
		"scene": "res://scenes/ui/economy_workspace.tscn",
		"setup": "economy",
		"probes": [
			["Column/Tabs", "国库/税制/贸易页签条", "chrome"],
			["Column/Tabs/CategoryTabButton", "页签按钮#1", "chrome"],
			["Column/TaxTabs/CategoryTabButton", "税种页签按钮（税制页）", "chrome"],
			["Column/Ledger/LedgerColumn/Tools/Search", "搜索框", "chrome"],
			["Column/Ledger/LedgerColumn/Tools/OverridesOnly", "仅看覆盖项", "chrome"],
			["Column/Ledger/LedgerColumn/Scroll", "国库账本滚动区", "chrome"],
		],
	},
	"pause": {
		"scene": "res://scenes/ui/pause_menu.tscn",
		"setup": "pause",
		"probes": [
			["**MenuButton", "暂停菜单按钮#1", "chrome"],
			["**Frame", "暂停菜单面板", "chrome"],
		],
	},
	"technology": {
		"scene": "res://scenes/ui/technology_workspace.tscn",
		"setup": "technology",
		"probes": [
			["Root/Toolbar/Row/Relocate", "科技-迁移按钮", "chrome"],
			["Root/Toolbar/Row/Search", "科技-搜索框", "chrome"],
			["Root/Toolbar/Row/EraPlate/EraRow/PrevEra", "上一时代", "chrome"],
			["Root/Main/DetailHost/Body/Header/Close", "科技-详情关闭", "chrome"],
			["Root/Main/PolicyPanel/Scroll/Body/Header/Close", "科技-政策关闭", "chrome"],
			["Root/Main/DetailHost/Body/Header/Pin", "科技-详情钉住", "chrome"],
		],
	},
	"colonization": {
		"scene": "res://scenes/ui/colonization_planner_panel.tscn",
		"probes": [
			["Margin/Root/Header/CloseButton", "殖民-关闭", "chrome", true],
			["Margin/Root/Header/CategoryTabs/CategoryTabButton", "殖民-页签", "chrome"],
			["Margin/Root/Footer/StartButton", "殖民-开始按钮", "chrome", true],
			["Margin/Root/Tools/FamilySort", "殖民-排序下拉", "chrome"],
		],
	},
	"era_reward": {
		"scene": "res://scenes/ui/era_reward_dialog.tscn",
		"setup": "era",
		"probes": [
			["**Close", "时代奖励-关闭/稍后", "chrome", true],
			["**Popup", "时代奖励-弹窗本体", "chrome", true],
			["**Rewards", "时代奖励-奖励区", "chrome"],
		],
	},
	"family_founding": {
		"scene": "res://scenes/ui/family/family_founding_dialog.tscn",
		"setup": "founding",
		"probes": [
			["**CollapseButton", "家族创立-折叠", "chrome", true],
			["**ArchiveSurface", "家族创立-面板", "chrome", true],
			["**CardsScroll", "家族创立-卡片滚动区", "chrome"],
		],
	},
	"annual_report": {
		"scene": "res://scenes/ui/annual_report_workspace.tscn",
		"setup": "annual",
		"probes": [
			["##关闭", "年报-关闭（页脚）", "chrome", true],
			["**Reader", "年报-阅读器", "chrome", true],
		],
	},
}

var _out_dir := ""
var _label := "run"
var _profile := "mobile"
var _dpi := 440.0
var _size := Vector2i(2400, 1080)
var _rows: Array[Dictionary] = []
var _failures: Array[String] = []
var _touch_ui: GDScript
var _debug := false


func _initialize() -> void:
	_parse_args()
	call_deferred("_run")


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--label="):
			_label = arg.trim_prefix("--label=")
		elif arg.begins_with("--profile="):
			_profile = arg.trim_prefix("--profile=")
		elif arg.begins_with("--dpi="):
			_dpi = float(arg.trim_prefix("--dpi="))
		elif arg.begins_with("--size="):
			var pair := arg.trim_prefix("--size=").split("x")
			if pair.size() == 2:
				_size = Vector2i(int(pair[0]), int(pair[1]))
		elif arg == "--debug-layout":
			_debug = true
	if _out_dir.is_empty():
		_out_dir = "user://mobile_touch_qa"
	_touch_ui = load(TOUCH_UI_SCRIPT) as GDScript


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	# 固定 100% 用户缩放，保证 before/after 基线可比，且不落盘。
	var settings := root.get_node_or_null("/root/GameSettings")
	if settings != null and settings.has_method("ui_scaling"):
		settings.call("update", {"ui_scale_percent": 100, "window_mode": "windowed",
			"resolution_width": 1600, "resolution_height": 960}, false)
		var scaling = settings.call("ui_scaling")
		if scaling != null:
			scaling.call("set_qa_override", {"profile": _profile, "dpi": _dpi,
				"safe_area": null})
			settings.call("apply")
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(_size)
	for i in range(4):
		await process_frame

	var touch := _is_touch()
	var dp_unit := _dp_per_unit()
	print("[touch-qa] profile=%s dpi=%.0f window=%dx%d touch=%s dp_per_unit=%.3f" % [
		_profile, _dpi, DisplayServer.window_get_size().x, DisplayServer.window_get_size().y,
		touch, dp_unit])

	for case_name in CASES.keys():
		await _run_case(String(case_name), CASES[case_name])

	_write_report(touch, dp_unit)
	quit(0 if _failures.is_empty() else 1)


func _run_case(case_name: String, case: Dictionary) -> void:
	var path := String(case.scene)
	var packed := load(path) as PackedScene
	if packed == null:
		_failures.append("%s: 场景加载失败 %s" % [case_name, path])
		return
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	var panel := packed.instantiate() as Control
	host.add_child(panel)
	# 隐藏的 Control 不参与 Container 布局（rect 会停成初始值），量出来没有意义。
	panel.visible = true
	# 与 GameUIManager._watch_touch_panels() 同一条路径；桌面档内部自判 no-op。
	_touch_ui.call("watch", panel)
	_setup(panel, String(case.get("setup", "")))
	for i in range(3):
		await process_frame
	await RenderingServer.frame_post_draw

	var image := root.get_texture().get_image()
	if image != null:
		image.save_png(ProjectSettings.globalize_path("%s/%s_%s.png" % [_out_dir, _label, case_name]))

	var probes: Array = case.probes
	for spec in probes:
		var must_visible: bool = spec.size() >= 4 and bool(spec[3])
		_measure(case_name, panel, String(spec[0]), String(spec[1]), String(spec[2]),
			must_visible)
	_measure_scrollbars(case_name, panel)
	if _debug and case_name == "pause":
		_debug_layout(case_name, panel)
	if panel.get_node_or_null("Column/Tabs") != null:
		_measure_tab_hit(case_name, panel)
		await _verify_hit_band(case_name, panel)

	host.queue_free()
	await process_frame


## 经济工作区没有模型时只会画骨架；这里给 tabs 一个有内容的假模型，
## 让「税制页」的 TaxTabs 也真正建出来（否则测不到第二排页签）。
func _setup(panel: Control, kind: String) -> void:
	match kind:
		"economy":
			if panel.has_method("set_model"):
				panel.call("set_model", {
					"available": true, "country_name": "测试国", "current_day": 3,
					"treasury": {"cash_text": "1,234", "nonzero_good_count": 4, "goods": []},
					"fiscal": {},
				})
			if panel.has_method("_select_page"):
				panel.call("_select_page", "income")
		"pause":
			if panel.has_method("open"):
				panel.call("open")
		"technology":
			pass
		"era":
			# 只做静态可达性测量：显示 + 让它自己按视口摆位（_layout_popup）。
			panel.visible = true
			if panel.has_method("_layout_popup"):
				panel.call("_layout_popup")
		"founding":
			panel.visible = true
		"annual":
			# 阅读器（含页脚「关闭」）在 _ready 里就建好，但页脚 offset 只在 present() 里
			# 由 _apply_paper_rects() 设置；不给一个空模型会量到「页脚在屏幕下方」的假象。
			panel.visible = true
			if panel.has_method("present"):
				panel.call("present", {}, false)
			if panel.has_method("_update_layout"):
				panel.call("_update_layout")


func _measure(case_name: String, root_node: Control, path: String, human: String,
		tier: String, must_visible: bool = false) -> void:
	var node := _resolve(root_node, path)
	var expected := 44.0 if tier == "chrome" else 36.0
	# 桌面档只记录基线尺寸，不做触摸达标判定（那里的 44dp 要求不适用）。
	var enforce := _is_touch()
	if node == null:
		_rows.append({"case": case_name, "node": human, "path": path, "exists": false,
			"expected_dp": expected, "pass": not enforce})
		if enforce:
			_failures.append("%s/%s: 节点缺失 %s" % [case_name, human, path])
		return
	var rect := node.get_global_rect()
	var hit := _hit_rect(node)
	var dp_h := rect.size.y * _dp_per_unit()
	var hit_dp_h := hit.size.y * _dp_per_unit()
	# 是否整块落在视口内（20:9 手机上「面板超出屏幕」的硬指标）。
	var view := root_node.get_viewport_rect()
	var inside := view.grow(1.0).encloses(rect)
	var entry := {
		"case": case_name, "node": human, "path": path, "exists": true,
		"visible": node.is_visible_in_tree(), "inside": inside,
		"w": rect.size.x, "h": rect.size.y,
		"hit_w": hit.size.x, "hit_h": hit.size.y,
		"px": [rect.position.x, rect.position.y],
		"dp_w": rect.size.x * _dp_per_unit(), "dp_h": dp_h,
		"hit_dp_h": hit_dp_h,
		"tier": tier, "expected_dp": expected, "must_visible": must_visible,
		# 隐藏的控件不参与布局，尺寸不能当判据：记 skipped，不算通过也不算失败。
		"skipped": "invisible" if not node.is_visible_in_tree() else "",
		"pass": (not enforce) or (not node.is_visible_in_tree()) \
			or hit_dp_h + 0.01 >= expected,
	}
	_rows.append(entry)
	if not node.is_visible_in_tree():
		if enforce and must_visible:
			_failures.append("%s/%s: 不可见（必须可见的出口/面板）" % [case_name, human])
	elif enforce and not bool(entry.pass):
		_failures.append("%s/%s: 命中高 %.1fdp < 目标 %.0fdp" % [
			case_name, human, hit_dp_h, expected])
	if enforce and must_visible and not inside:
		_failures.append("%s/%s: 超出屏幕 %s ⊄ %s" % [case_name, human, rect, view])


## 路径解析：
##   `**名字` → 子树里递归找同名节点
##   `##文字` → 子树里找 text 等于该文字的 Button（年报页脚按钮是代码建的无名按钮）
## 触摸档会运行期重排暂停菜单（Frame 铺满视口、Rows 塞进 RowsScroll），写死路径会失效。
func _resolve(root_node: Node, path: String) -> Control:
	if path.begins_with("**"):
		return root_node.find_child(path.substr(2), true, false) as Control
	if path.begins_with("##"):
		return _find_button_by_text(root_node, path.substr(2))
	return root_node.get_node_or_null(path) as Control


func _find_button_by_text(root_node: Node, text_value: String) -> Button:
	var stack: Array[Node] = [root_node]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Button and (node as Button).text.strip_edges() == text_value:
			return node as Button
		for child in node.get_children():
			stack.append(child)
	return null


## 页签的命中带 = 本体 + touch_hit_button 的上下扩展（相邻页签横向不重叠）。
func _measure_tab_hit(case_name: String, panel: Control) -> void:
	var tabs := panel.get_node_or_null("Column/Tabs")
	if tabs == null:
		return
	for child in tabs.get_children():
		if not (child is Control):
			continue
		var control := child as Control
		var hit := _hit_rect(control)
		var entry := {
			"case": case_name, "node": "%s（命中带）" % String(control.name),
			"path": String(tabs.get_path()) + "/" + String(control.name), "exists": true,
			"w": control.get_global_rect().size.x, "h": control.get_global_rect().size.y,
			"hit_w": hit.size.x, "hit_h": hit.size.y,
			"dp_h": control.get_global_rect().size.y * _dp_per_unit(),
			"hit_dp_h": hit.size.y * _dp_per_unit(),
			"tier": "chrome", "expected_dp": 44.0,
			"pass": (not _is_touch()) or hit.size.y * _dp_per_unit() + 0.01 >= 44.0,
		}
		_rows.append(entry)
		if _is_touch() and not bool(entry.pass):
			_failures.append("%s/%s: 页签命中带 %.1fdp < 44dp" % [
				case_name, String(control.name), entry.hit_dp_h])


## 真刀真枪验证 `_has_point` 命中带：往「纸签本体之外、命中带之内」的点注入一次
## 鼠标按下+抬起，看 tab_selected 是否真的被触发。
## （`Control.has_point()` 在 Godot 4 没有暴露给脚本，所以不能直接调——只能走输入管线。）
func _verify_hit_band(case_name: String, panel: Control) -> void:
	var tabs := panel.get_node_or_null("Column/Tabs")
	if tabs == null or tabs.get_child_count() < 2:
		return
	var button := tabs.get_child(1) as Control
	if button == null or not button.has_method("touch_hit_padding"):
		return
	var pad = button.call("touch_hit_padding")
	if not (pad is Vector2) or (pad as Vector2).y <= 0.5:
		return
	var rect := button.get_global_rect()
	var point := Vector2(rect.get_center().x, rect.position.y - (pad as Vector2).y * 0.5)
	var fired := {"hit": false}
	var handler := func(_tab_id: String) -> void: fired["hit"] = true
	tabs.tab_selected.connect(handler)
	_send_click(point)
	await process_frame
	await process_frame
	tabs.tab_selected.disconnect(handler)
	var inside_rect := Rect2(rect.position, rect.size).has_point(point)
	_rows.append({
		"case": case_name, "node": "纸签命中带-真实点击注入", "exists": true,
		"path": "输入注入 @ %s" % str(point), "visible": true,
		"w": rect.size.x, "h": rect.size.y, "hit_w": 0.0, "hit_h": 0.0,
		"dp_h": 0.0, "hit_dp_h": 0.0, "tier": "input", "expected_dp": 0.0,
		"inside_visual_rect": inside_rect, "fired": bool(fired["hit"]),
		"pass": (not _is_touch()) or bool(fired["hit"]),
	})
	if _is_touch() and not bool(fired["hit"]):
		_failures.append("%s: 在纸签外侧(命中带内)点击未触发 tab_selected —— "
			% case_name + "_has_point 未参与拾取，命中带是假的")


## 布局插桩：暂停菜单的按钮被压成 8px 宽时，必须能一眼看出是哪一层塌了。
func _debug_layout(case_name: String, panel: Control) -> void:
	var frame := panel.find_child("Frame", true, false) as Control
	var scroll := panel.find_child("RowsScroll", true, false) as Control
	var rows := panel.find_child("Rows", true, false) as Control
	var button := panel.find_child("MenuButton", true, false) as Control
	for entry in [["Frame", frame], ["RowsScroll", scroll], ["Rows", rows], ["MenuButton", button]]:
		var control := entry[1] as Control
		if control == null:
			print("[%s-debug] %s = <null>" % [case_name, String(entry[0])])
			continue
		print("[%s-debug] %s size=%s min=%s hflags=%d vflags=%d" % [
			case_name, String(entry[0]), str(control.size), str(control.get_combined_minimum_size()),
			control.size_flags_horizontal, control.size_flags_vertical])


func _send_click(point: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	press.global_position = point
	Input.parse_input_event(press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = point
	release.global_position = point
	Input.parse_input_event(release)


func _measure_scrollbars(case_name: String, panel: Control) -> void:
	var stack: Array[Node] = [panel]
	var found := 0
	while not stack.is_empty() and found < 4:
		var node: Node = stack.pop_back()
		if node is ScrollContainer:
			found += 1
			var scroll := node as ScrollContainer
			var bar := scroll.get_v_scroll_bar()
			var w := bar.custom_minimum_size.x if bar != null else 0.0
			var dp_w := w * _dp_per_unit()
			_rows.append({
				"case": case_name, "node": "滚动条（%s）" % String(scroll.name),
				"path": String(scroll.get_path()), "exists": true,
				"w": w, "h": 0.0, "hit_w": w, "hit_h": 0.0,
				"dp_w": dp_w, "dp_h": 0.0, "hit_dp_h": 0.0,
				"tier": "scrollbar", "expected_dp": 32.0,
				"pass": (not _is_touch()) or dp_w + 0.01 >= 32.0,
			})
			if _is_touch() and dp_w + 0.01 < 32.0:
				_failures.append("%s/滚动条 %s: %.1fdp < 32dp" % [
					case_name, String(scroll.name), dp_w])
		for child in node.get_children():
			stack.append(child)


func _hit_rect(control: Control) -> Rect2:
	var rect := Rect2(control.global_position, control.size)
	if control.has_method("touch_hit_padding"):
		var pad = control.call("touch_hit_padding")
		if pad is Vector2:
			rect = rect.grow_individual((pad as Vector2).x, (pad as Vector2).y,
				(pad as Vector2).x, (pad as Vector2).y)
	return rect


func _write_report(touch: bool, dp_unit: float) -> void:
	var payload := {
		"label": _label, "profile": _profile, "dpi": _dpi, "touch": touch,
		"dp_per_unit": dp_unit,
		"window": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"viewport": [root.get_visible_rect().size.x, root.get_visible_rect().size.y],
		"records": _rows, "failures": _failures,
	}
	var file := "%s/touch_metrics_%s.json" % [_out_dir, _label]
	var handle := FileAccess.open(ProjectSettings.globalize_path(file), FileAccess.WRITE)
	if handle != null:
		handle.store_string(JSON.stringify(payload, "  ", false, true))
		handle.close()
	print("[touch-qa] metrics=%s" % file)
	print("case\tnode\tw\th\thit_h\tdp_h\thit_dp_h\ttier\texpected_dp\tpass")
	for row in _rows:
		print("%s\t%s\t%.0f\t%.0f\t%.0f\t%.1f\t%.1f\t%s\t%.0f\t%s" % [
			String(row.get("case", "")), String(row.get("node", "")),
			float(row.get("w", 0.0)), float(row.get("h", 0.0)),
			float(row.get("hit_h", 0.0)), float(row.get("dp_h", 0.0)),
			float(row.get("hit_dp_h", 0.0)), String(row.get("tier", "")),
			float(row.get("expected_dp", 0.0)), bool(row.get("pass", false))])
	for failure in _failures:
		push_warning("[touch-qa] %s" % failure)
	print("[touch-qa] label=%s profile=%s rows=%d failures=%d out=%s" % [
		_label, _profile, _rows.size(), _failures.size(), _out_dir])


func touch_active() -> bool:
	if _touch_ui == null:
		return false
	return bool(_touch_ui.call("is_touch"))


func _is_touch() -> bool:
	return touch_active()


func _dp_per_unit() -> float:
	if _touch_ui == null:
		return 1.0
	return float(_touch_ui.call("dp_per_unit"))
