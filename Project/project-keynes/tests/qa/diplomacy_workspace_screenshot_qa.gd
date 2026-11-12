extends SceneTree

## 外交章的渲染验收。需要渲染（不要加 --headless）：
##   godot --path Project/project-keynes -s res://tests/qa/diplomacy_workspace_screenshot_qa.gd
##
## 两种 UI 宽（1280×720 / 1600×900）各跑两遍：工作区单独成一页，以及挂进真实的
## CountryPanel 外壳。模型来自 `tests/ui/diplomacy_workspace_test.gd` 的 fixture，
## 所以断言与截图看的是同一组数字。
##
## 除了出图，这里还做三件事后检查（都是「肉眼才看得出」的退化的自动化版本）：
##   1. 章节页签不许退化成纯图标；
##   2. 名录必须真的列出国家、两张档案的标题必须是国名/敌名；
##   3. 主按钮在 1280 宽下不能被裁掉（页脚宽度够用）。

const OUTPUT_DIR := "D:/Godot/ProjectKeynes/Project.Keynes/tmp/diplomacy_ui"
const SCENE := "res://scenes/ui/diplomacy_workspace.tscn"
const PANEL_SCENE := "res://scenes/ui/country_panel.tscn"
const THEME := "res://assets/themes/player_session_theme.tres"
const HARNESS := preload("res://tests/ui/diplomacy_workspace_test.gd")
const PARCHMENT := Color("e4d9bf")
const CHAPTER_IDS := ["overview", "countries", "wars"]

var _failures := PackedStringArray()
var _fixture


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	_fixture = HARNESS.new()
	for size in [Vector2i(1280, 720), Vector2i(1600, 900)]:
		await _run_size(size)
	print("diplomacy screenshot qa: %d failures" % _failures.size())
	for failure in _failures:
		print("  [FAIL] %s" % failure)
	quit(0 if _failures.is_empty() else 1)


func _run_size(size: Vector2i) -> void:
	DisplayServer.window_set_size(size)
	root.size = size
	await _settle()
	var backdrop := ColorRect.new()
	backdrop.color = PARCHMENT
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.theme = load(THEME) as Theme
	root.add_child(backdrop)
	await process_frame

	# 1) 工作区单独成一页
	var frame := MarginContainer.new()
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		frame.add_theme_constant_override("margin_" + side, 24)
	backdrop.add_child(frame)
	var workspace := (load(SCENE) as PackedScene).instantiate()
	frame.add_child(workspace)
	await process_frame
	workspace.call("set_model", _fixture.call("fixture_model"))
	for chapter_id in CHAPTER_IDS:
		workspace.call("select_chapter", String(chapter_id))
		await _capture("diplomacy_%s_%dx%d" % [chapter_id, size.x, size.y])
		await _check_page(workspace, "%s page" % chapter_id)
	_check_chapters(workspace)
	frame.queue_free()
	await process_frame

	# 2) 挂进真实的 CountryPanel 外壳（书脊 / 页头都在）
	var panel := (load(PANEL_SCENE) as PackedScene).instantiate()
	backdrop.add_child(panel)
	await process_frame
	var model: Dictionary = _fixture.call("fixture_model")
	model["country_name"] = "青川"
	panel.call("show_section", "diplomacy", model)
	await process_frame
	var shell_workspace := panel.get("_diplomacy_workspace") as Control
	if shell_workspace == null:
		_failures.append("country panel does not mount the diplomacy workspace")
	else:
		for chapter_id in CHAPTER_IDS:
			shell_workspace.call("select_chapter", String(chapter_id))
			await _capture("diplomacy_%s_shell_%dx%d" % [chapter_id, size.x, size.y])
		await _check_page(shell_workspace, "shell")
		_check_chapters(shell_workspace)
	backdrop.queue_free()
	await process_frame


## 页签不许退化成纯图标（中文标签在窄页头上最容易先被吞掉）。
func _check_chapters(workspace: Control) -> void:
	var nav := workspace.get_node_or_null("%ChapterNav") as Control
	if nav == null:
		_failures.append("chapter nav missing")
		return
	if bool(nav.get("icon_only")):
		_failures.append("chapter tabs fell back to icon-only at %s" % nav.size)
	if int((nav.get("chapters") as Array).size()) != CHAPTER_IDS.size():
		_failures.append("chapter nav exposes the wrong number of tabs")


func _check_page(workspace: Control, tag: String) -> void:
	if not bool(workspace.call("view_model").call("available")):
		_failures.append("%s: view model unavailable" % tag)
		return
	var snapshot: Dictionary = workspace.call("debug_snapshot")
	var chapter := String(snapshot.get("chapter", ""))
	# 名录只在「国家」章填充；其余章读的是同一个视图模型的名单长度。
	if chapter == "countries" and int(snapshot.get("roster_rows", 0)) <= 0:
		_failures.append("%s: roster ledger is empty" % tag)
	var title := workspace.get_node_or_null("%SheetTitle") as Label
	if chapter == "countries":
		if title == null or String(title.text) == "未选择国家":
			_failures.append("%s: country sheet has no selection" % tag)
	# 印章按钮在窄屏上被裁掉是旧账，这里按实际矩形判一次。
	if chapter == "wars":
		var peace := workspace.get_node_or_null("%WarPeaceButton") as Button
		if peace == null or peace.size.x < 60.0:
			_failures.append("%s: 议和 button is clipped (%.1f px)" % [tag, peace.size.x if peace != null else 0.0])


func _capture(name: String) -> void:
	await create_timer(UITokens.ANIM_MED + 0.05).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image == null:
		_failures.append("%s: capture failed" % name)
		return
	var path := OUTPUT_DIR.path_join("%s.png" % name)
	print("[capture] %s error=%d" % [path, image.save_png(path)])


func _settle() -> void:
	for _index in range(3):
		await process_frame
