extends SceneTree
## WorldLoadingOverlay 失败面板测试（问题 3/3 的"错误可诊断"验收）。
##
## 不起整个世界，只实例化 scenes/ui/world_loading_overlay.tscn，喂一段假的
## 生成失败详情，然后断言：
##   1) 摘要进了 Stage 标签、详细文本进了 DetailText（可全选）；
##   2) 详情落盘到 user://logs/map_generation_failure_<时间戳>.txt 且内容一致；
##   3) "复制详情"按钮存在，点击后剪贴板（有剪贴板的平台）等于详情全文；
##   4) 复制按钮文案反馈为"已复制"。
##
## 跑法：
##   Godot_v4.6.2-stable_win64_console.exe --headless --path <project> \
##       --script res://tests/world/world_loading_overlay_failure_test.gd

const OVERLAY_SCENE := "res://scenes/ui/world_loading_overlay.tscn"

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(OVERLAY_SCENE)
	if packed == null:
		push_error("[overlay-failure-test] cannot load %s" % OVERLAY_SCENE)
		quit(1)
		return
	var overlay := packed.instantiate() as WorldLoadingOverlay
	if overlay == null:
		push_error("[overlay-failure-test] instantiate failed")
		quit(1)
		return
	root.add_child(overlay)
	await process_frame
	await process_frame

	var summary := "C++ 地图生成失败（forced_by_env_PK_FORCE_MAPGEN_FAIL）。阶段=native_base 原因=forced 排查：重建 gdext Android arm64。"
	var detail := "=== 地图生成失败 / mapgen fatal ===\n阶段 stage     : native_base\n原因 reason    : forced_by_env_PK_FORCE_MAPGEN_FAIL\n摘要 summary   : 测试注入\n地图/种子      : 40x28  seed=20261101\n平台/架构      : os=Windows arch=x86_64 platform=desktop\n自检 preflight : ok=true extension_loaded=true world_ext=True bound=False native_mode=2\n--- native_generation_base_report (大数组已折叠) ---\n{\"rc\": -7, \"fallback_reason\": \"forced_by_env_PK_FORCE_MAPGEN_FAIL\"}"
	overlay.show_failure_detailed(summary, detail)
	await process_frame

	# 1) 摘要 + 详细文本
	var stage_label := overlay.get_node_or_null("Center/Card/Content/StageRow/Stage") as Label
	_expect("Stage label shows summary", stage_label != null and stage_label.text == summary,
		stage_label.text if stage_label != null else "<null>")
	var detail_edit := overlay.get_node_or_null("Center/Card/Content/FailureDetail/DetailText") as TextEdit
	_expect("DetailText exists", detail_edit != null, null)
	if detail_edit != null:
		_expect("DetailText carries full detail", detail_edit.text == detail,
			detail_edit.text.substr(0, 80))
		_expect("DetailText is read-only for selection", not detail_edit.editable, detail_edit.editable)
	var box := overlay.get_node_or_null("Center/Card/Content/FailureDetail") as Control
	_expect("FailureDetail visible", box != null and box.visible, null)
	var actions := overlay.get_node_or_null("Center/Card/Content/FailureActions") as Control
	_expect("FailureActions visible", actions != null and actions.visible, null)

	# 2) 落盘
	var log_path_label := overlay.get_node_or_null("Center/Card/Content/FailureDetail/LogPath") as Label
	_expect("LogPath label filled", log_path_label != null and log_path_label.text.contains("map_generation_failure_"),
		log_path_label.text if log_path_label != null else "<null>")
	var written := _find_latest_failure_log()
	_expect("failure log file written", not written.is_empty(), written)
	if not written.is_empty():
		var f := FileAccess.open(written, FileAccess.READ)
		var on_disk := f.get_as_text() if f != null else ""
		if f != null:
			f.close()
		_expect("failure log content matches detail", on_disk.strip_edges() == detail.strip_edges(),
			on_disk.substr(0, 80))
		print("[overlay-failure-test] wrote %s (%d bytes)" % [written, on_disk.length()])

	# 3) 复制按钮
	var copy_btn := overlay.get_node_or_null("Center/Card/Content/FailureActions/CopyDetail") as Button
	_expect("CopyDetail button exists", copy_btn != null, null)
	if copy_btn != null:
		copy_btn.emit_signal("pressed")
		await process_frame
		_expect("copy button feedback", copy_btn.text.contains("已复制"), copy_btn.text)
		if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
			# Windows/部分平台会把 \n 规范化成 \r\n，比较前统一换行符。
			var clip := DisplayServer.clipboard_get().replace("\r\n", "\n").strip_edges()
			_expect("clipboard holds detail", clip == detail.strip_edges(),
				clip.substr(0, 60))
			print("[overlay-failure-test] clipboard bytes=%d (normalized=%d, expected=%d)"
				% [DisplayServer.clipboard_get().length(), clip.length(), detail.length()])
		else:
			print("[overlay-failure-test] clipboard feature unavailable on this DisplayServer; skipped")

	# 4) 截图（仅窗口模式）：给报告留一张真实的失败面板证据。
	var shot := OS.get_environment("PK_MAPGEN_SCREENSHOT")
	if not shot.is_empty() and DisplayServer.get_name() != "headless":
		# 多等几帧让 PanelContainer 重新布局 + 字体渲染完成。
		for _i in range(6):
			await process_frame
		var img: Image = root.get_texture().get_image()
		if img == null:
			_expect("screenshot captured", false, "viewport image null")
		else:
			var rc := img.save_png(shot)
			_expect("screenshot saved", rc == OK, rc)
			print("[overlay-failure-test] screenshot %s (%dx%d)" % [shot, img.get_width(), img.get_height()])
	else:
		print("[overlay-failure-test] screenshot skipped (headless or PK_MAPGEN_SCREENSHOT unset)")

	overlay.queue_free()
	await process_frame

	if _failures.is_empty():
		print("[overlay-failure-test] PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error("[overlay-failure-test] FAIL: %s" % failure)
		print("[overlay-failure-test] FAIL count=%d" % _failures.size())
		quit(1)


## 找 user://logs 里最新的 map_generation_failure_*.txt。
func _find_latest_failure_log() -> String:
	var dir_path := ProjectSettings.globalize_path("user://logs")
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var best := ""
	var best_time := -1
	var name := dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir() and name.begins_with("map_generation_failure_") and name.ends_with(".txt"):
			var full := dir_path.path_join(name)
			var mtime := int(FileAccess.get_modified_time(full))
			if mtime > best_time:
				best_time = mtime
				best = full
		name = dir.get_next()
	dir.list_dir_end()
	return best


func _expect(label: String, condition: bool, extra) -> void:
	if not condition:
		_failures.append("%s | got=%s" % [label, str(extra)])
