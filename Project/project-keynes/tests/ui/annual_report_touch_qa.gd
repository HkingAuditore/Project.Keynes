extends SceneTree

## 移动档年报（年鉴）可关闭性验收。
##
## 背景：跨年时 AnnualReportFlow 会暂停 WorldClock，只有年鉴自己的 `closed`
## 信号能把时钟放回去。页脚“关闭”是一条 26 设计像素高的文字链，在 440dpi 手机上
## 约 12dp —— 手指压不中就变成“第二年 1 月 1 日模拟卡死”。
##
## 本 harness 在移动档分辨率下实例化真实的 annual_report_workspace.tscn，
## 用一份最小 model 开卷，实测页脚按钮的命中矩形（设计像素 + dp），并留截图。
##
## 用法（在 Project/project-keynes 目录，console 版才有 stdout）：
##   & $godot --path . --resolution 2160x1080 -s res://tests/ui/annual_report_touch_qa.gd -- `
##       --out=tmp/annual_touch --dpi=440 --layout=fit
##
## 退出码：0 = 所有页脚按钮命中尺寸达到 44dp；1 = 有按钮过小或开卷失败。

const WORKSPACE := "res://scenes/ui/annual_report_workspace.tscn"
const MIN_DP := 44.0

var _out_dir := "tmp/annual_touch"
var _fake_dpi := 440.0
var _layout := "fit"
var _failures: Array[String] = []


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--dpi="):
			_fake_dpi = float(arg.trim_prefix("--dpi="))
		elif arg.begins_with("--layout="):
			_layout = arg.trim_prefix("--layout=")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var settings := root.get_node_or_null("/root/GameSettings")
	if settings == null:
		print("[annual-touch-qa] GameSettings missing")
		quit(1)
		return
	settings.call("update", {
		"ui_scale_percent": 100, "window_mode": "windowed",
		"resolution_width": 1600, "resolution_height": 960,
		"ui_layout_mode": _layout,
	}, false)
	var scaling = settings.call("ui_scaling") if settings.has_method("ui_scaling") else null
	if scaling == null:
		print("[annual-touch-qa] MobileUIScaling missing")
		quit(1)
		return
	scaling.call("set_qa_override", {
		"profile": "mobile", "dpi": _fake_dpi, "layout": _layout,
	})
	settings.call("apply")
	DisplayServer.window_set_size(Vector2i(2160, 1080))
	for i in 3:
		await process_frame

	var packed := load(WORKSPACE) as PackedScene
	if packed == null:
		print("[annual-touch-qa] workspace scene missing")
		quit(1)
		return
	var ws := packed.instantiate() as Control
	root.add_child(ws)
	ws.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for i in 3:
		await process_frame

	var closed: Array[int] = []
	ws.closed.connect(func(id: int) -> void: closed.append(id))
	ws.present(_model(), false)
	for i in 4:
		await process_frame

	print("[annual-touch-qa] viewport=%s visible=%s" % [
		str(ws.get_viewport_rect().size), str(ws.visible)])
	if not ws.visible:
		_failures.append("workspace 未开卷（visible=false）")
		_finish()
		return

	var dp_per_unit := float(scaling.call("dp_per_unit"))
	var buttons := ws.find_children("*", "Button", true, false)
	print("[annual-touch-qa] dp_per_unit=%.3f layout=%s buttons=%d" % [
		dp_per_unit, _layout, buttons.size()])
	for node in buttons:
		var button := node as Button
		if button == null or not button.is_visible_in_tree():
			continue
		var rect := button.get_global_rect()
		var dp := rect.size * dp_per_unit
		print("[annual-touch-qa] button '%s' rect=%s dp=%.1fx%.1f" % [
			button.text, str(rect), dp.x, dp.y])
		# 只看页脚三条文字链：它们在视口下沿附近、文字很短。
		if button.text in ["关闭", "复制全文", "更早"]:
			if dp.x + 0.5 < MIN_DP or dp.y + 0.5 < MIN_DP:
				_failures.append("按钮「%s」命中区 %.1fx%.1f dp < %.0fdp" % [
					button.text, dp.x, dp.y, MIN_DP])

	await process_frame
	var image := root.get_texture().get_image()
	if image != null:
		var shot := "%s/annual_report_%s.png" % [_out_dir, _layout]
		image.save_png(shot)
		print("[annual-touch-qa] screenshot %s (%dx%d)" % [shot, image.get_width(), image.get_height()])

	# 关闭链路必须真的把 closed 发出来（AnnualReportFlow 靠它恢复时钟）。
	ws.call("_close")
	await process_frame
	if closed.is_empty():
		_failures.append("_close() 没有发出 closed 信号，时钟无法恢复")
	print("[annual-touch-qa] closed signal ids=%s visible_after=%s" % [str(closed), str(ws.visible)])
	_finish()


func _finish() -> void:
	if _failures.is_empty():
		print("[annual-touch-qa] PASS")
		quit(0)
	else:
		for failure in _failures:
			print("[annual-touch-qa] FAIL %s" % failure)
		quit(1)


func _model() -> Dictionary:
	return {
		"available": true,
		"id": 1,
		"year": 1,
		"country_name": "测试国",
		"grade": "B",
		"score": 72,
		"chapters": [{
			"title": "年度报告", "number": 1,
			"lead": "移动档可关闭性验收用最小年鉴。",
			"rows": [], "details": [], "figures": [], "visuals": [],
			"margin_notes": [], "has_previous": false,
		}],
	}
