extends SceneTree

## 移动端 UI 缩放验收 harness（问题 1/3：安卓按钮过小点不中）。
##
## 作用
##   1) 在多种窗口尺寸下实例化 res://scenes/main_menu.tscn，依次切到
##      首页 / 新游戏 / 读档 / 设置 四个页面，每页等 3 帧后把
##      get_viewport().get_texture().get_image() 存成 PNG；
##   2) 顺带把「关键可点击控件」的 get_global_rect() 实测尺寸写进 metrics_*.json
##      并打印成 TSV，带设计像素 → 物理像素 → dp 的换算；
##   3) 结尾把玩家 HUD 的两条主操作栏（player_top_bar / country_action_bar）
##      单独挂到一个 CanvasLayer 上截一张 HUD 图，验证主操作栏没被裁。
##
## 运行（在 Project/project-keynes 目录，console 版才有 stdout）：
##   $godot = "D:\Godot\Godot_v4.6.2-stable_win64.exe\Godot_v4.6.2-stable_win64_console.exe"
##   & $godot --path . --resolution 2400x1080 -s res://tests/ui/mobile_ui_scaling_qa.gd -- `
##       --out=test_output/mobile_ui/before --label=before --profile=mobile --dpi=440
##
## 参数（都走 -- 之后的 user args，等价环境变量见下）
##   --out=<目录>           截图与 metrics 输出目录（默认 user://mobile_ui_qa）
##   --label=<名字>         写进 metrics 的标签（before / after / ...）
##   --profile=auto|mobile|desktop
##                          mobile：走移动端缩放策略（无移动端时是空操作）；
##                          desktop：强制桌面策略（因子 1.0）。
##   --dpi=<数字>           dp 换算用的假设 dpi（默认 0 → 用运行时报的 dpi）
##   --safe=x,y,w,h         安全区覆盖（测试用；缺省用 DisplayServer 上报值）
##   --sizes=WxH,WxH,...    尺寸清单（默认 2400x1080,2220x1080,1600x960,1280x720）
##
## 退出码：0 = 所有关键控件都在视口内且可点；1 = 有控件被裁/缺失。

const MENU_SCENE := "res://scenes/main_menu.tscn"
const TOP_BAR_SCENE := "res://scenes/ui/player_top_bar.tscn"
const ACTION_BAR_SCENE := "res://scenes/ui/country_action_bar.tscn"

const DEFAULT_SIZES := "2400x1080,2220x1080,1600x960,1280x720"

## 每个页面下要实测的关键控件：唯一名 → 人话
const PAGE_TARGETS := {
	"home": [
		["%HomePage", "首页容器"],
		["%NewGameButton", "新游戏"],
		["%LoadGameButton", "读档"],
		["%SettingsButton", "设置"],
		["%QuitButton", "退出"],
		["%NewGameButton/Content/Row/Label", "新游戏-文字"],
	],
	"new": [
		["%NewGamePage", "新游戏页"],
		["%StartButton", "开始游戏"],
		["%NewBackButton", "返回"],
		["%SizeOption", "地图尺寸下拉"],
		["%SeedBox", "地图种子"],
		["%CountryEdit", "国名输入"],
		["%AdvancedButton", "高级地图设置"],
	],
	"load": [
		["%LoadGamePage", "读档页"],
		["%LoadBackButton", "返回"],
		["%LoadSlots", "存档列表"],
	],
	"settings": [
		["%SettingsPage", "设置页"],
		["%ApplySettingsButton", "应用"],
		["%SettingsBackButton", "返回"],
		["%UIScale", "UI 缩放下拉"],
		["%Resolution", "分辨率下拉"],
		["%WindowMode", "窗口模式下拉"],
		["%Volume", "音量滑块"],
	],
}

var _out_dir := ""
var _label := "run"
var _profile := "auto"
var _fake_dpi := 0.0
var _safe_override := Rect2i()
var _has_safe_override := false
var _ui_scale_percent := 100
var _sizes: Array[Vector2i] = []
var _failures: Array[String] = []
var _records: Array[Dictionary] = []


func _initialize() -> void:
	_parse_args()
	call_deferred("_run")


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	_out_dir = OS.get_environment("PK_MOBILE_QA_OUT")
	var sizes_text := DEFAULT_SIZES
	for arg in args:
		if arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--label="):
			_label = arg.trim_prefix("--label=")
		elif arg.begins_with("--profile="):
			_profile = arg.trim_prefix("--profile=")
		elif arg.begins_with("--dpi="):
			_fake_dpi = float(arg.trim_prefix("--dpi="))
		elif arg.begins_with("--safe="):
			var parts := arg.trim_prefix("--safe=").split(",")
			if parts.size() == 4:
				_safe_override = Rect2i(int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3]))
				_has_safe_override = true
		elif arg.begins_with("--sizes="):
			sizes_text = arg.trim_prefix("--sizes=")
		elif arg.begins_with("--ui-scale="):
			_ui_scale_percent = int(arg.trim_prefix("--ui-scale="))
	for item in sizes_text.split(","):
		var pair := String(item).split("x")
		if pair.size() == 2:
			_sizes.append(Vector2i(int(pair[0]), int(pair[1])))
	if _out_dir.is_empty():
		_out_dir = "user://mobile_ui_qa"


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	# 设置里 ui_scale 可能是 125%，会让 before/after 的基线不可比：这里固定 100%
	# 且不落盘（persist=false），不动用户的 user://settings.cfg。
	var settings := root.get_node_or_null("/root/GameSettings")
	if settings != null:
		settings.call("update", {
			"ui_scale_percent": _ui_scale_percent, "window_mode": "windowed",
			"resolution_width": 1600, "resolution_height": 960,
		}, false)
		var scaling = settings.call("ui_scaling") if settings.has_method("ui_scaling") else null
		if scaling != null:
			scaling.call("set_qa_override", {
				"profile": _profile,
				"dpi": _fake_dpi,
				"safe_area": _safe_override if _has_safe_override else null,
			})
			settings.call("apply")
		else:
			print("[mobile-ui-qa] 无 MobileUIScaling（旧的：按物理像素绘制）profile=%s dpi=%.0f"
				% [_profile, _fake_dpi])
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	await process_frame

	if not await _capture_menu():
		_finish()
		return
	await _capture_hud()
	_finish()


func _set_window(size: Vector2i) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	await process_frame
	await process_frame
	await process_frame


func _capture_menu() -> bool:
	var packed := load(MENU_SCENE) as PackedScene
	if packed == null:
		_failures.append("主菜单场景加载失败")
		return false
	change_scene_to_file(MENU_SCENE)
	await process_frame
	await process_frame
	await process_frame
	var menu := current_scene as Control
	if menu == null:
		_failures.append("主菜单实例化失败")
		return false
	for target_size in _sizes:
		await _set_window(target_size)
		# 窗口实际尺寸（Windows 上可能被 DWM 夹住，报告里要按实测写）
		var actual := DisplayServer.window_get_size()
		for page in ["home", "new", "load", "settings"]:
			match page:
				"home":
					menu.call("_show_home", true)
				"new":
					menu.call("_show_new_game")
				"load":
					menu.call("_show_load_game")
				"settings":
					menu.call("_show_settings")
			await create_timer(0.7).timeout
			await process_frame
			await process_frame
			await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var file := "%s/%s_%s_%dx%d.png" % [_out_dir, _label, page, actual.x, actual.y]
			image.save_png(file)
			var non_black := _non_black_ratio(image)
			print("[mobile-ui-qa] page=%s size=%dx%d img=%s non_black=%.3f" % [
				page, actual.x, actual.y, file, non_black])
			if non_black < 0.2:
				_failures.append("%s %dx%d 截图疑似空白（non_black=%.3f）"
					% [page, actual.x, actual.y, non_black])
			_collect(page, target_size, actual, menu, non_black)
	if is_instance_valid(menu):
		menu.queue_free()
	await process_frame
	return true


## 一帧 HUD：把玩家顶栏 + 主操作栏挂到 CanvasLayer 上（不跑世界生成）。
func _capture_hud() -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(host)
	var top_bar := (load(TOP_BAR_SCENE) as PackedScene).instantiate() as Control
	var action_bar := (load(ACTION_BAR_SCENE) as PackedScene).instantiate() as Control
	host.add_child(top_bar)
	host.add_child(action_bar)
	# 与 GameUIManager._apply_touch_hud_metrics() 同一口径：移动端把栏内按钮抬到 52。
	var touch := _touch_profile_active()
	if touch:
		for bar in [top_bar, action_bar]:
			if bar.has_method("apply_touch_metrics"):
				bar.call("apply_touch_metrics", 52.0)
	for target_size in _sizes:
		await _set_window(target_size)
		var actual := DisplayServer.window_get_size()
		var view := root.get_visible_rect()
		# 安全区：镜像 GameUIManager._apply_ui_safe_area()（同一个 safe_insets() API、
		# 同一组 offset）。这里不跑世界生成，拿不到真实 UIRoot，只能用 host 复现同样的内缩。
		if touch:
			var insets := _safe_insets()
			host.offset_left = float(insets.get("left", 0.0))
			host.offset_top = float(insets.get("top", 0.0))
			host.offset_right = -float(insets.get("right", 0.0))
			host.offset_bottom = -float(insets.get("bottom", 0.0))
		# 顶栏贴顶、主操作栏贴底（与 player_game.tscn 中的锚点一致）
		top_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
		top_bar.offset_bottom = 0.0
		action_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		action_bar.offset_left = 64.0
		action_bar.offset_right = -64.0
		action_bar.offset_top = -94.0
		action_bar.offset_bottom = -8.0
		await process_frame
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var file := "%s/%s_hud_%dx%d.png" % [_out_dir, _label, actual.x, actual.y]
		image.save_png(file)
		print("[mobile-ui-qa] page=hud size=%dx%d img=%s" % [actual.x, actual.y, file])
		var scale := _pixel_scale()
		for spec in [
			[action_bar.get_node_or_null("Sections/Technology"), "HUD-科技"],
			[action_bar.get_node_or_null("Sections/Economy"), "HUD-经济"],
			[action_bar, "HUD-操作栏"],
			[top_bar.get_node_or_null("Margin/Row/DateBlock"), "HUD-日期块"],
		]:
			_record(target_size, actual, "hud", spec[0], spec[1], view, scale)
	if is_instance_valid(layer):
		layer.queue_free()
	await process_frame


func _collect(page: String, target_size: Vector2i, actual: Vector2i,
		menu: Control, non_black: float) -> void:
	var view := root.get_visible_rect()
	var scale := _pixel_scale()
	for spec in PAGE_TARGETS[page]:
		var path := String(spec[0])
		var control := menu.get_node_or_null(path) as Control
		_record(target_size, actual, page, control, String(spec[1]), view, scale)


func _record(target_size: Vector2i, actual: Vector2i, page: String, control: Control,
		human: String, view: Rect2, scale: float) -> void:
	var entry := {
		"page": page, "node": human, "requested": "%dx%d" % [target_size.x, target_size.y],
		"window": "%dx%d" % [actual.x, actual.y], "exists": control != null,
	}
	if control == null:
		entry.merge({"visible": false, "inside": false, "w": 0.0, "h": 0.0,
			"dp_w": 0.0, "dp_h": 0.0, "font_px": 0})
		_records.append(entry)
		_failures.append("%s/%s 控件缺失" % [page, human])
		return
	var rect := control.get_global_rect()
	var font_size := 0
	if control is Label:
		font_size = int((control as Label).get_theme_font_size("font_size"))
	var clip := _clip_state(control, rect, view)
	var inside := bool(clip.inside)
	entry.merge({
		"visible": control.is_visible_in_tree(), "inside": inside,
		"in_scroll": bool(clip.in_scroll),
		"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
		"w": rect.size.x, "h": rect.size.y,
		"px_w": rect.size.x * scale, "px_h": rect.size.y * scale,
		"dp_w": _dp(rect.size.x * scale), "dp_h": _dp(rect.size.y * scale),
		"font_px": font_size,
		"font_dp": _dp(float(font_size) * scale),
	})
	_records.append(entry)
	if not control.is_visible_in_tree():
		_failures.append("%s/%s 不可见" % [page, human])
	elif not inside:
		_failures.append("%s/%s 被裁 %s ⊄ %s" % [page, human, rect, view])
	elif rect.size.x < 1.0 or rect.size.y < 1.0:
		_failures.append("%s/%s 尺寸为零" % [page, human])


## 裁剪判定：普通控件必须完整落在视口里；若在 ScrollContainer 内（例如新游戏表单的
## NewLeftScroll、读档列表 LoadScroll），纵向由滚动条负责，只要求「横向不出框、
## 且滚动容器本身在视口里」——否则会把「需要滚动」误判成「被裁」。
func _clip_state(control: Control, rect: Rect2, view: Rect2) -> Dictionary:
	var node := control.get_parent()
	var scroll: ScrollContainer = null
	while node != null:
		if node is ScrollContainer:
			scroll = node as ScrollContainer
			break
		node = node.get_parent()
	if scroll == null:
		return {"inside": view.grow(1.0).encloses(rect), "in_scroll": false}
	var scroll_rect := scroll.get_global_rect()
	var fits_across := rect.position.x >= scroll_rect.position.x - 1.0 \
		and rect.end.x <= scroll_rect.end.x + 1.0
	return {
		"inside": fits_across and view.grow(1.0).encloses(scroll_rect),
		"in_scroll": true,
	}


## 物理像素 / 设计像素（content_scale 之后 1 设计像素对应多少物理像素）
func _pixel_scale() -> float:
	var view := root.get_visible_rect()
	var win := Vector2(DisplayServer.window_get_size())
	if view.size.x <= 0.0:
		return 1.0
	return win.x / view.size.x


func _dpi() -> float:
	if _fake_dpi > 0.0:
		return _fake_dpi
	var reported := float(DisplayServer.screen_get_dpi())
	if reported <= 0.0:
		return 96.0
	return reported


func _touch_profile_active() -> bool:
	var settings := root.get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return false
	var scaling = settings.call("ui_scaling")
	return scaling != null and bool(scaling.call("is_touch_profile"))


func _safe_insets() -> Dictionary:
	var settings := root.get_node_or_null("/root/GameSettings")
	if settings == null or not settings.has_method("ui_scaling"):
		return {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	var scaling = settings.call("ui_scaling")
	if scaling == null:
		return {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
	return scaling.call("safe_insets")


func _dp(physical: float) -> float:
	return physical * 160.0 / maxf(_dpi(), 1.0)


func _non_black_ratio(image: Image) -> float:
	if image == null or image.is_empty():
		return 0.0
	var data := image.get_data()
	var step := maxi(4 * 97, 4)  # 稀疏采样，别把 10 MB 像素全扫一遍
	var sampled := 0
	var lit := 0
	for i in range(0, data.size() - 3, step):
		sampled += 1
		if int(data[i]) + int(data[i + 1]) + int(data[i + 2]) > 24:
			lit += 1
	return float(lit) / maxf(float(sampled), 1.0)


func _finish() -> void:
	var view := root.get_visible_rect()
	var payload := {
		"label": _label, "profile": _profile, "assumed_dpi": _dpi(),
		"ui_scale_percent": _ui_scale_percent,
		"pixel_scale": _pixel_scale(),
		"window": [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y],
		"viewport_logical": [view.size.x, view.size.y],
		"screen": [DisplayServer.screen_get_size().x, DisplayServer.screen_get_size().y],
		"reported_dpi": DisplayServer.screen_get_dpi(),
		"safe_area": [DisplayServer.get_display_safe_area().position.x,
			DisplayServer.get_display_safe_area().position.y,
			DisplayServer.get_display_safe_area().size.x,
			DisplayServer.get_display_safe_area().size.y],
		"records": _records,
		"failures": _failures,
	}
	var metrics_file := "%s/metrics_%s.json" % [_out_dir, _label]
	var handle := FileAccess.open(ProjectSettings.globalize_path(metrics_file), FileAccess.WRITE)
	if handle != null:
		handle.store_string(JSON.stringify(payload, "  ", false, true))
		handle.close()
	print("[mobile-ui-qa] metrics=%s" % metrics_file)
	print("page\tnode\twindow\tlogical_w\tlogical_h\tphysical_w\tphysical_h\tdp_w\tdp_h\tin_scroll\tinside")
	for entry in _records:
		print("%s\t%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%s\t%s" % [
			entry.page, entry.node, entry.window, entry.get("w", 0.0), entry.get("h", 0.0),
			entry.get("px_w", 0.0), entry.get("px_h", 0.0),
			entry.get("dp_w", 0.0), entry.get("dp_h", 0.0),
			entry.get("in_scroll", false), entry.get("inside", false)])
	for failure in _failures:
		push_warning("[mobile-ui-qa] %s" % failure)
	print("[mobile-ui-qa] label=%s profile=%s records=%d failures=%d out=%s" % [
		_label, _profile, _records.size(), _failures.size(), _out_dir])
	quit(0 if _failures.is_empty() else 1)
