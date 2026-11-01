extends ColorRect
class_name WorldLoadingOverlay

signal retry_requested
signal return_requested

var _failed := false

# ─── 失败诊断 UI（mapgen-diagnostics）────────────────────────────────────
# 需求（问题 3/3）：安卓上"点创建地图直接失败"只显示 map_generator_failed，
# 玩家/开发者拿不到细节。这里把失败面板升级成：
#   摘要（一句中文） + 可滚动/可全选的详细文本 + "复制详情" + 落盘到 user://logs。
var _failure_detail_edit: TextEdit
var _failure_detail_box: Control
var _failure_log_path_label: Label
var _copy_button: Button
var _last_failure_summary: String = ""
var _last_failure_detail: String = ""
var _last_failure_log_path: String = ""

const STAGE_LABELS := {
	"preparing": "准备地图数据",
	"continents": "生成陆地",
	"climate": "生成气候",
	"terrain": "生成地形和水文",
	"physical": "生成河流",
	"atlas": "生成地图图层",
	"encode": "生成地貌和植被",
	"ecology": "生成生态系统",
	"simulation": "生成初始聚落",
	# ── simulation(92%) 之后的装配引导链（map_generator._loading_profile_step）──
	"world_bind": "绑定世界数据",
	"resources": "勘测自然资源",
	"ecology_bind": "播种生态分布",
	"gameplay_bind": "初始化玩法系统",
	"runtime_bind": "启动仿真运行时",
	"done": "即将进入世界",
	# ── 生成器返回后的渲染/视觉层装载（world_runtime_host）──
	"bind": "绑定世界状态",
	"visual": "构建地表植被",
	"upload": "进入世界",
}

## 这些阶段的 fraction 由发射方直接给"UI 完成度绝对值"（0.96..0.99），不再乘以 0.96：
## 生成器返回后的绑定/视觉层阶段要跨越多个发射点（host 步骤 + 逐层回调），
## 只有绝对完成度才能保证跨发射点严格单调、不回退。
const ABSOLUTE_STAGES := ["bind", "visual"]

var _backdrop: Control
var _card: PanelContainer
var _compass_dial: Control
var _title_label: Label
var _stage_label: Label
var _percent_label: Label
var _progress: ProgressBar
var _active_tween: Tween
var _last_stage: String = ""
var _last_fraction: float = 0.0
var _anim_fraction: float = 0.0
var _spin_time: float = 0.0


func _ready() -> void:
	if _card != null:
		return
	_backdrop = get_node_or_null("AtlasBackdrop") as Control
	_card = get_node_or_null("Center/Card") as PanelContainer
	_compass_dial = get_node_or_null("Center/Card/Content/CompassDial") as Control
	_title_label = get_node_or_null("Center/Card/Content/Title") as Label
	_stage_label = get_node_or_null("Center/Card/Content/StageRow/Stage") as Label
	_percent_label = get_node_or_null("Center/Card/Content/StageRow/Percent") as Label
	_progress = get_node_or_null("Center/Card/Content/Progress") as ProgressBar
	var icon := get_node_or_null("Center/Card/Content/StageRow/Icon") as IconBadge
	if _card == null or _title_label == null or _stage_label == null \
			or _percent_label == null or _progress == null or icon == null:
		push_error("WorldLoadingOverlay 必须通过 world_loading_overlay.tscn 实例化。")
		return
	icon.set_semantic(&"country.world", UITokens.ACCENT)
	if _compass_dial != null:
		_compass_dial.draw.connect(_draw_compass_dial)
	if _progress != null:
		_progress.draw.connect(_draw_progress_shimmer)
	resized.connect(func() -> void: _card.custom_minimum_size.x = minf(640.0, maxf(240.0,size.x-64.0)))
	get_node("Center/Card/Content/FailureActions/Retry").pressed.connect(func() -> void: retry_requested.emit())
	get_node("Center/Card/Content/FailureActions/Return").pressed.connect(func() -> void: return_requested.emit())
	# 失败详情区：可滚动 + 可全选 + 一键复制（安卓无 Ctrl+C，只能靠按钮）。
	_failure_detail_box = get_node_or_null("Center/Card/Content/FailureDetail")
	_failure_detail_edit = get_node_or_null("Center/Card/Content/FailureDetail/DetailText") as TextEdit
	_failure_log_path_label = get_node_or_null("Center/Card/Content/FailureDetail/LogPath") as Label
	_copy_button = get_node_or_null("Center/Card/Content/FailureActions/CopyDetail") as Button
	if _copy_button != null:
		_copy_button.pressed.connect(_on_copy_detail_pressed)
	if _failure_detail_box != null:
		_failure_detail_box.hide()
	visibility_changed.connect(func() -> void: set_process(is_visible_in_tree()))
	set_process(is_visible_in_tree())


func _process(delta: float) -> void:
	if not visible:
		return
	if _failed or UIAnimation.reduced_motion():
		return
	_spin_time += delta
	var target_anim := maxf(_last_fraction, minf(0.12, _spin_time * 0.045))
	_anim_fraction = lerpf(_anim_fraction, target_anim, minf(delta * 6.0, 1.0))

	if _backdrop != null and _backdrop.has_method("set_loading_progress"):
		_backdrop.call("set_loading_progress", _anim_fraction)
	if _compass_dial != null:
		_compass_dial.queue_redraw()
	if _progress != null:
		_progress.queue_redraw()


func _draw_compass_dial() -> void:
	if _compass_dial == null:
		return
	var c := _compass_dial.size * 0.5
	var r := minf(c.x, c.y) - 3.0
	if r <= 4.0:
		return
	var brass := UITokens.DOSSIER_BRASS
	var oxblood := UITokens.DOSSIER_OXBLOOD
	var ink_soft := Color(0.28, 0.19, 0.12, 0.32)

	# 底盘与外环
	_compass_dial.draw_circle(c, r, Color(0.95, 0.90, 0.78, 0.85))
	_compass_dial.draw_arc(c, r, 0.0, TAU, 48, ink_soft, 1.5, true)
	_compass_dial.draw_arc(c, r * 0.76, 0.0, TAU, 40, Color(brass, 0.45), 1.2, true)

	# 进度圆弧
	var sweep := clampf(maxf(_anim_fraction, 0.08), 0.0, 1.0) * TAU
	_compass_dial.draw_arc(c, r, -PI * 0.5, -PI * 0.5 + sweep, 48, oxblood, 2.6, true)

	# 旋转刻度环
	for i in range(12):
		var a := _spin_time * 0.85 + float(i) * TAU / 12.0
		var dir := Vector2(cos(a), sin(a))
		var inner_r := r * (0.80 if i % 3 == 0 else 0.86)
		_compass_dial.draw_line(c + dir * inner_r, c + dir * (r - 1.5), brass, 1.4 if i % 3 == 0 else 1.0)

	# 旋转罗盘指针
	var needle_a := _spin_time * 2.1
	var n_dir := Vector2(cos(needle_a), sin(needle_a))
	var n_perp := Vector2(-n_dir.y, n_dir.x)
	var north_poly := PackedVector2Array([
		c + n_dir * (r * 0.64),
		c + n_perp * 3.8,
		c - n_perp * 3.8,
	])
	var south_poly := PackedVector2Array([
		c - n_dir * (r * 0.56),
		c + n_perp * 3.2,
		c - n_perp * 3.2,
	])
	_compass_dial.draw_colored_polygon(north_poly, oxblood)
	_compass_dial.draw_colored_polygon(south_poly, Color(0.36, 0.25, 0.16, 0.75))
	_compass_dial.draw_circle(c, 3.2, brass)
	_compass_dial.draw_circle(c, 1.5, Color(0.99, 0.95, 0.84, 1.0))


func _draw_progress_shimmer() -> void:
	if _progress == null or _progress.size.x <= 4.0:
		return
	var fill_ratio := clampf(_progress.value / maxf(_progress.max_value, 1.0), 0.0, 1.0)
	var fill_w := _progress.size.x * fill_ratio
	if fill_w <= 6.0:
		return
	var phase := fmod(_spin_time * 0.85, 1.0)
	var band_x := lerpf(-24.0, fill_w + 12.0, phase)
	var x0 := clampf(band_x, 1.0, fill_w - 1.0)
	var x1 := clampf(band_x + 28.0, 1.0, fill_w - 1.0)
	if x1 > x0:
		_progress.draw_rect(
			Rect2(Vector2(x0, 1.0), Vector2(x1 - x0, maxf(2.0, _progress.size.y - 2.0))),
			Color(1.0, 0.92, 0.68, 0.36)
		)


func show_message(message: String) -> void:
	if _card == null:
		_ready()
	_kill_tween()
	_failed = false
	get_node("Center/Card/Content/FailureActions").hide()
	if _failure_detail_box != null:
		_failure_detail_box.hide()
	if _progress != null:
		_progress.show()
	if _percent_label != null:
		_percent_label.show()
	_set_failure_card_expanded(false)
	visible = true
	set_process(true)
	modulate = Color.WHITE
	_card.modulate = Color.WHITE
	_title_label.text = message
	_stage_label.text = "准备中"
	_percent_label.text = "0%"
	_progress.value = 0.0
	_last_stage = ""
	_last_fraction = 0.0
	_anim_fraction = 0.0
	if _backdrop != null and _backdrop.has_method("set_loading_progress"):
		_backdrop.call("set_loading_progress", _anim_fraction)


func set_progress(stage: String, fraction: float) -> void:
	if _card == null:
		_ready()
	if _failed:
		return
	var clamped := clampf(fraction,0.0,1.0)
	# 默认：生成器内部 0..1 的进度线性映射到 0..96%。
	var completed := clamped*.96
	if stage == "upload":
		# 旧语义（保留兼容）：upload 阶段占最后 96%..98.5%。
		completed = .96 + .025*clamped
	elif stage in ABSOLUTE_STAGES:
		# 生成器返回后的绑定/视觉层阶段：fraction 就是 UI 完成度绝对值，
		# 由 world_runtime_host 的单调游标按 0.96→0.99 逐步骤/逐图层推进。
		completed = clamped
	# 单调闸门：任何阶段都只能前进不能后退（hide_completed 仍是唯一的 100%）。
	_last_fraction = maxf(_last_fraction,minf(completed,.99))
	_anim_fraction = maxf(_anim_fraction, _last_fraction)
	var percent := clampi(int(round(_last_fraction * 100.0)), 0, 100)
	_title_label.text = "正在生成世界"
	_percent_label.text = "%d%%" % percent
	_progress.value = percent
	if _backdrop != null and _backdrop.has_method("set_loading_progress"):
		_backdrop.call("set_loading_progress", _last_fraction)
	if stage != _last_stage:
		_last_stage = stage
		_stage_label.text = String(STAGE_LABELS.get(stage, stage))


func hide_completed() -> void:
	if not visible:
		return
	_kill_tween()
	_title_label.text = "世界生成完成"
	_stage_label.text = "正在进入世界"
	_percent_label.text = "100%"
	_progress.value = 100.0
	_last_fraction = 1.0
	_anim_fraction = 1.0
	_active_tween = create_tween()
	_active_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_active_tween.tween_property(_card, "modulate", Color(1.06, 1.03, 0.94, 1.0), 0.12)
	_active_tween.tween_interval(0.10)
	_active_tween.parallel().tween_property(self, "modulate:a", 0.0, UITokens.ANIM_SLOW)
	if not UIAnimation.reduced_motion():
		_active_tween.parallel().tween_property(_card, "scale", Vector2(0.985, 0.985), UITokens.ANIM_SLOW)
	_active_tween.tween_callback(func() -> void:
		visible = false
		set_process(false)
		modulate = Color.WHITE
		_card.modulate = Color.WHITE
		_card.scale = Vector2.ONE
	)


func _kill_tween() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null


func set_layout_state(state: Dictionary) -> void:
	if _backdrop != null and _backdrop.has_method("set_layout_state"):
		_backdrop.call("set_layout_state", state)

func show_failure(reason: String) -> void:
	show_failure_detailed(reason, "")


## 失败面板（详细版）。
## summary : 一句中文摘要（含阶段/原因/排查建议），显示在标题行
## detail  : 完整多行详情（stage/reason/native_report/preflight/平台）。空则自动生成。
## 行为：
##   1) 详情区显示摘要 + 可滚动/可全选的详细文本；
##   2) 详情自动落盘 user://logs/map_generation_failure_<时间戳>.txt（安卓无控制台）；
##   3) 打一行 [mapgen][fatal] 到 stdout/push_error，方便 adb logcat 过滤；
##   4) "复制详情" 按钮走 DisplayServer.clipboard_set（安卓没有 Ctrl+C）。
func show_failure_detailed(summary: String, detail: String) -> void:
	_kill_tween()
	_failed = true
	visible = true
	modulate = Color.WHITE
	_card.scale = Vector2.ONE
	if _title_label == null:
		_ready()
	_last_failure_summary = summary
	_last_failure_detail = detail if not detail.is_empty() else summary
	_title_label.text = "世界准备失败"
	_stage_label.text = summary
	_stage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 失败时进度条和百分比都无意义，藏掉以免和"世界准备失败"矛盾。
	if _progress != null:
		_progress.hide()
	if _percent_label != null:
		_percent_label.hide()
	if _failure_detail_edit != null:
		_failure_detail_edit.text = _last_failure_detail
		# editable=false 才能避免误改；选中/全选由玩家手动或走"复制详情"按钮。
		_failure_detail_edit.editable = false
	if _failure_detail_box != null:
		_failure_detail_box.show()
	_set_failure_card_expanded(true)
	# 落盘：安卓上玩家没法看 stdout，这是唯一能事后取证的持久化位置。
	_last_failure_log_path = _write_failure_log()
	if _failure_log_path_label != null:
		_failure_log_path_label.text = ("详情已保存：%s" % _last_failure_log_path) \
			if not _last_failure_log_path.is_empty() else "详情保存失败（user:// 不可写）"
	# 单行、带固定前缀：`adb logcat -s godot:* | findstr "[mapgen][fatal]"` 一条命中。
	var one_line := summary.replace("\n", " ")
	print("[mapgen][fatal] %s" % one_line)
	push_error("[mapgen][fatal] %s" % one_line)
	if not _last_failure_log_path.is_empty():
		print("[mapgen][fatal] detail_file=%s" % _last_failure_log_path)
	get_node("Center/Card/Content/FailureActions").show()


## 把失败详情写到 user://logs/map_generation_failure_<时间戳>.txt。
## 返回写入路径（失败返回空串，绝不抛错——失败面板本身必须能显示出来）。
func _write_failure_log() -> String:
	var dir := "user://logs"
	var abs_dir := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs_dir):
		var mk := DirAccess.make_dir_recursive_absolute(abs_dir)
		if mk != OK:
			return ""
	var stamp := Time.get_datetime_string_from_system(false, true)
	# 文件名里不能有冒号（Windows/部分 Android 文件系统），统一换成 '-'
	stamp = stamp.replace(":", "-").replace("T", "_").replace(" ", "_")
	var path := "%s/map_generation_failure_%s.txt" % [dir, stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(_last_failure_detail)
	if not _last_failure_detail.ends_with("\n"):
		f.store_string("\n")
	f.close()
	return ProjectSettings.globalize_path(path)


## 失败面板比分发面板高得多：Center 是贴底的定高 CenterContainer（offset_top=-244），
## 详情区塞进去会被裁掉，所以在失败时把它向上撑开，恢复进度态时还原。
func _set_failure_card_expanded(expanded: bool) -> void:
	var center := get_node_or_null("Center") as Control
	if center == null:
		return
	center.offset_top = -minf(maxf(size.y - 48.0, 240.0), 620.0) if expanded else -244.0


func _on_copy_detail_pressed() -> void:
	var payload := _last_failure_detail
	if payload.is_empty():
		payload = _last_failure_summary
	DisplayServer.clipboard_set(payload)
	if _copy_button != null:
		# 轻量反馈：按钮文案闪一下"已复制"，不额外弹窗。
		_copy_button.text = "已复制 ✓"
		var timer := get_tree().create_timer(1.2)
		timer.timeout.connect(func() -> void:
			if is_instance_valid(_copy_button):
				_copy_button.text = "复制详情"
		)

