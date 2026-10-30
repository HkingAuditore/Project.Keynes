extends ColorRect
class_name WorldLoadingOverlay

signal retry_requested
signal return_requested

var _failed := false

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
	_kill_tween()
	_failed = true
	visible = true
	modulate = Color.WHITE
	_card.scale = Vector2.ONE
	_title_label.text = "世界准备失败"
	_stage_label.text = reason
	_stage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	get_node("Center/Card/Content/FailureActions").show()
