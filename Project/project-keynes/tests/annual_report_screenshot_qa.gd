extends SceneTree

## 年度报告截图 QA。
##
## 三类失败判据：
##   1. 书页（Book）越出视口 1px 以上；
##   2. 底栏高度超过 48px（会挤掉正文）；
##   3. 长卷内任何可见控件的右缘越出视口右缘 1px 以上 —— 纸本长卷不允许横向溢出。
##
## 输出：res://tmp/annual_report_qa/*.png（不入库，仅本地比图用）。

const Fixture = preload("res://tests/annual_report_test.gd")
const Model = preload("res://scripts/ui/annual_report_view_model.gd")
const Scene = preload("res://scenes/ui/annual_report_workspace.tscn")
const OUTPUT := "res://tmp/annual_report_qa"
var _failures: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.19, 0.23, 0.20)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(backdrop)
	var workspace = Scene.instantiate()
	root.add_child(workspace)

	for viewport_size in [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1920, 1080), Vector2i(2560, 1080)]:
		for scale_value in [1.0, 1.25]:
			root.content_scale_factor = scale_value
			root.size = viewport_size
			DisplayServer.window_set_size(viewport_size)
			workspace.present(Model.build(Fixture.fixture()), true)
			workspace.set_history([{"id": 1, "year": 0, "grade": "S"}], 0, false)
			await create_timer(1.6).timeout
			workspace.finish_opening()
			await _capture(workspace, "cover_%dx%d_%d" % [viewport_size.x, viewport_size.y, int(scale_value * 100)])
			workspace.call("_show_page", 1, false)
			await _capture(workspace, "reader_top_%dx%d_%d" % [viewport_size.x, viewport_size.y, int(scale_value * 100)], 4)
			workspace.reader().scroll_to_chapter(5, false)
			await _capture(workspace, "reader_mid_%dx%d_%d" % [viewport_size.x, viewport_size.y, int(scale_value * 100)], 4)
			workspace.reader().scroll_to_chapter(9, false)
			await _capture(workspace, "reader_end_%dx%d_%d" % [viewport_size.x, viewport_size.y, int(scale_value * 100)], 4)

	root.content_scale_factor = 1.0
	root.size = Vector2i(1280, 720)
	DisplayServer.window_set_size(root.size)
	for era in Model.ERA_IDS.size():
		var raw: Dictionary = Fixture.fixture()
		raw.era = era
		workspace.present(Model.build(raw), false)
		await _capture(workspace, "era_%s" % Model.ERA_IDS[era])
	for grade in ["SS", "S", "A", "B", "C", "D", "E"]:
		var raw: Dictionary = Fixture.fixture()
		raw.grade = grade
		raw.grade_index = ["SS", "S", "A", "B", "C", "D", "E"].find(grade)
		raw.score_bp = [9700, 9000, 8000, 6500, 5000, 3500, 2000][raw.grade_index]
		raw.reward_q16 = [72, 48, 36, 24, 12, 6, 0][raw.grade_index] * 65536
		workspace.present(Model.build(raw), false)
		await _capture(workspace, "grade_" + grade)
	var long_name: Dictionary = Fixture.fixture()
	long_name.country_name = "河湾与群山沿海地区联合共同体特别自治共和国"
	workspace.present(Model.build(long_name), false)
	await _capture(workspace, "long_country_name")

	# reduced_motion：所有 shader 必须摘掉，缩放必须是 1 —— 否则"关动效"只是关了一半。
	var settings = root.get_node("GameSettings")
	var saved_motion: bool = bool(settings.get("_settings").get("reduce_motion", false))
	settings.get("_settings")["reduce_motion"] = true
	workspace.present(Model.build(Fixture.fixture()), true)
	await _capture(workspace, "reduced_motion")
	if workspace.get("_book").scale != Vector2.ONE or workspace.get("_stamp").scale != Vector2.ONE:
		print("[FAIL] reduced_motion keeps element scaling")
		_failures += 1
	# 版画的材质现在是常驻的（下沿羽化在它身上），所以判据不是"摘掉材质"，
	# 而是"落墨已经全开、报头那次性的揭示材质没有挂上去"。
	if float(workspace.get("_art").material.get_shader_parameter("bleed")) < 1.19:
		print("[FAIL] reduced_motion keeps the art half-revealed")
		_failures += 1
	if workspace.reader().cover().get("_title").material != null:
		print("[FAIL] reduced_motion keeps the title reveal shader")
		_failures += 1
	if workspace.get("_transition").material != null:
		print("[FAIL] reduced_motion keeps the transition shader")
		_failures += 1
	settings.get("_settings")["reduce_motion"] = saved_motion
	print("annual_report_screenshot_qa: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)


func _capture(workspace, tag: String, frames: int = 2) -> void:
	for i in frames:
		await process_frame
	await RenderingServer.frame_post_draw
	var book: Control = workspace.get("_book")
	var visible_rect: Rect2 = root.get_visible_rect()
	var rect: Rect2 = book.get_global_rect()
	if not visible_rect.grow(1).encloses(rect):
		print("[FAIL] %s book=%s viewport=%s" % [tag, rect, visible_rect])
		_failures += 1
	if workspace.get("_footer").size.y > 48:
		print("[FAIL] %s footer is too tall" % tag)
		_failures += 1
	if workspace.reader().visible:
		var right_limit: float = visible_rect.end.x + 1.0
		for node in workspace.reader().find_children("*", "Control", true, false):
			var control := node as Control
			if control == null or not control.is_visible_in_tree() or control.size.x <= 0.0:
				continue
			if control.get_global_rect().end.x > right_limit:
				print("[FAIL] %s overflows the right edge: %s (%s)" % [tag, control.get_path(), control.get_global_rect()])
				_failures += 1
				break
	var image: Image = root.get_texture().get_image()
	_check_tear_pixels(workspace, image, visible_rect, tag)
	image.save_png(OUTPUT.path_join(tag + ".png"))


## 撕口的像素判据。几何断言抓不到最致命的一种失败：shader 里 has_mask = 1 但 sampler
## 没绑上 —— 那时拿到的是白图，纸变成一条直边、投影整条消失，而所有 Control 的矩形
## 依然分毫不差。这两条是唯一能在画面上看见它的手段。
func _check_tear_pixels(workspace, image: Image, viewport: Rect2, tag: String) -> void:
	var px: float = float(image.get_width()) / maxf(viewport.size.x, 1.0)
	var paper: Rect2 = AnnualReportTokens.paper_rect(viewport.size)
	var tear: float = AnnualReportTokens.tear_pad(viewport.size)
	var pad: float = AnnualReportTokens.paper_padding(viewport.size)
	var height: int = image.get_height()

	# ① 缺口里真的透出桌面：左缘外侧 tear * 0.45 处（比最深的外伸纤维还远），
	#    沿整列取值应当几乎全是深色桌面。
	var notch_x: int = clampi(int(round((paper.position.x - tear * 0.45) * px)), 0, image.get_width() - 1)
	var dark := 0
	var sampled := 0
	var y := 0
	while y < height:
		if image.get_pixel(notch_x, y).get_luminance() < 0.30:
			dark += 1
		sampled += 1
		y += 4
	var dark_ratio: float = float(dark) / maxf(1.0, float(sampled))
	if dark_ratio < 0.25:
		print("[FAIL] %s tear notch does not reveal the desk (%.0f%%)" % [tag, dark_ratio * 100.0])
		_failures += 1

	# ② 咬入不许吃进版心：正文起排位置的内侧半栏必须始终是纸。封面跳过 ——
	#    版画是满纸宽的，那一列在封面本来就可能是暗的（实测章节号 -1 时该列
	#    有 119 行压到 0.42，正是版画的位置）。封面也挂在 reader 里，所以判据
	#    只能看"当前章节"，不能看 reader 的可见性。
	if workspace.reader().current_chapter() < 0:
		return
	var body_x: int = clampi(int(round((paper.position.x + pad * 0.5) * px)), 0, image.get_width() - 1)
	var papery := 0
	sampled = 0
	y = 0
	while y < height:
		if image.get_pixel(body_x, y).get_luminance() > 0.60:
			papery += 1
		sampled += 1
		y += 4
	var paper_ratio: float = float(papery) / maxf(1.0, float(sampled))
	if paper_ratio < 0.98:
		print("[FAIL] %s tear bites into the text column (%.1f%% paper)" % [tag, paper_ratio * 100.0])
		_failures += 1
