extends Control
class_name EraAscensionCeremony

## 时代晋升大典（约 6–8 秒，1 秒后可点击 / Esc / 触摸跳过）。
##
## 时间线（秒，未跳过时）：
##   0.0  全屏压暗 + 去色 + 暗角，旧时代徽记在屏幕中央浮现
##   0.55 旧徽记出现金色裂纹、轻微震动
##   1.15 旧徽记自边缘燃尽（dissolve 着色器 + 余烬粒子 + 碎片飞散）
##   2.0  竖直光柱自天而降；2.2 爆闪 + 冲击波环 + 金色粒子爆发 + 屏幕震动
##   2.25 新徽记从光中凝形升起，背后放射光芒缓慢旋转
##   3.25 书法大字「进入××时代」运笔揭示，随后副标题
##   4.3  「时代加成」逐条展开
##   T_fly 新徽记缩小并沿弧线飞回顶栏纸徽 → emblem_landed → 底幕淡出 → finished，自行释放
##
## 全部视觉在本场景内（着色器 + CPUParticles2D + _draw），不依赖外部美术；
## 徽记复用 assets/icons/era 的时代图标。CPUParticles2D 兼容 Mobile / Compatibility / Web。
## 时间推进只走 advance()，_process 调它；测试可逐帧推进而不依赖墙钟。

signal emblem_landed()
signal finished()

const SKIP_AFTER := 1.0
const T_FADE_IN := 0.6
const T_CRACK := 0.55
const T_BURN := 1.15
const T_BURN_END := 2.15
const T_SHARDS := 1.45
const T_PILLAR := 2.0
const T_FLASH := 2.2
const T_RISE := 2.25
const T_RISE_END := 3.45
const T_TITLE := 3.25
const T_TITLE_END := 4.05
const T_SUB := 3.85
const T_BUFF_HEAD := 4.3
const BUFF_STEP := 0.26
const FLY_MIN := 5.6
const FLY_MAX := 6.6
const FLY_DURATION := 0.9
const FADE_OUT := 0.5
const SKIP_SPEED := 2.2
const MAX_BUFF_SLOTS := 6
const BASE_EMBLEM := 260.0
const SHARD_COUNT := 16
const TRAIL_LENGTH := 18
const GOLD := Color(1.0, 0.79, 0.30)
const GOLD_HOT := Color(1.0, 0.95, 0.80)
const TITLE_INK := Color(1.0, 0.88, 0.58)
const OUTLINE_INK := Color(0.16, 0.08, 0.03, 0.92)

@onready var _backdrop: ColorRect = $Backdrop
@onready var _halo: Control = $Halo
@onready var _old: TextureRect = $OldEmblem
@onready var _new: TextureRect = $NewEmblem
@onready var _embers: CPUParticles2D = $Embers
@onready var _motes: CPUParticles2D = $Motes
@onready var _burst: CPUParticles2D = $Burst
@onready var _sparks: CPUParticles2D = $Sparks
@onready var _front: Control = $Front
@onready var _text: VBoxContainer = $Text
@onready var _kicker: Label = %Kicker
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _buff_heading: Control = %BuffHeading
@onready var _buff_label: Label = %BuffHeadingLabel
@onready var _buff_rows: VBoxContainer = %BuffRows
@onready var _skip_hint: Label = %SkipHint

var _t := 0.0
var _speed := 1.0
var _playing := false
var _landed := false
var _done := false
var _skipped := false
var _t_fly := FLY_MIN
var _scale := 1.0
var _center := Vector2.ZERO
var _emblem := BASE_EMBLEM
var _emblem_center := Vector2.ZERO
var _emblem_scale := 1.0
var _halo_strength := 0.0
var _rays_rot := 0.0
var _shake := Vector2.ZERO
var _reduced := false
var _burst_fired := false
var _sparks_fired := false
var _target: Control
var _buffs := PackedStringArray()
var _shards: Array[Dictionary] = []
var _trail := PackedVector2Array()
var _has_old := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(false)
	_halo.draw.connect(_draw_halo)
	_front.draw.connect(_draw_front)
	resized.connect(_layout)
	_style_text()
	for i in range(_buff_rows.get_child_count()):
		var icon := _buff_rows.get_child(i).get_node("Icon") as TextureRect
		icon.texture = IconCatalog.texture_for_key(&"technology.milestone")


## config: {old_era_id, new_era_id, new_era_name, subtitle, buffs: PackedStringArray, target: Control}
func play(config: Dictionary) -> void:
	_reduced = UIAnimation.reduced_motion()
	_target = config.get("target") as Control
	var old_texture := EraIndicator.era_texture(String(config.get("old_era_id", "")))
	var new_texture := EraIndicator.era_texture(String(config.get("new_era_id", "")))
	_has_old = old_texture != null
	_old.texture = old_texture
	_new.texture = new_texture
	_kicker.text = "时代晋升"
	_title.text = "进入 %s" % String(config.get("new_era_name", "新时代"))
	_subtitle.text = String(config.get("subtitle", ""))
	_subtitle.visible = not _subtitle.text.is_empty()
	_buff_label.text = "时代加成"
	set_buffs(PackedStringArray(config.get("buffs", PackedStringArray())))
	_rng_shards(hash(String(config.get("new_era_id", ""))))
	_t = 0.0
	_speed = 1.0
	_playing = true
	_landed = false
	_done = false
	_skipped = false
	_burst_fired = false
	_sparks_fired = false
	_trail.clear()
	visible = true
	_layout()
	_apply(0.0)
	set_process(true)


## 收到更完整的加成清单（例如 PlayerController.era_advanced 晚于纸徽检测到达）时替换。
## 加成段尚未开始时同时重算飞回时刻；已经开始展开则只更新文字。
func set_buffs(buffs: PackedStringArray) -> void:
	_buffs = buffs
	var count := mini(buffs.size(), MAX_BUFF_SLOTS)
	for i in range(_buff_rows.get_child_count()):
		var row := _buff_rows.get_child(i) as Control
		row.visible = i < count
		if i >= count:
			continue
		var text := String(buffs[i])
		if i == MAX_BUFF_SLOTS - 1 and buffs.size() > MAX_BUFF_SLOTS:
			text = "另有 %d 项加成，详见时代晋升面板" % (buffs.size() - MAX_BUFF_SLOTS + 1)
		(row.get_node("Text") as Label).text = text
	_buff_heading.visible = count > 0
	if _t < T_BUFF_HEAD:
		_t_fly = clampf(T_BUFF_HEAD + 0.35 + float(count) * BUFF_STEP + 1.1, FLY_MIN, FLY_MAX)


func buffs() -> PackedStringArray:
	return _buffs


func is_playing() -> bool:
	return _playing


func is_done() -> bool:
	return _done


func has_landed() -> bool:
	return _landed


func elapsed() -> float:
	return _t


func can_skip() -> bool:
	return _playing and _t >= SKIP_AFTER


## 演出总时长（未跳过）。
func total_duration() -> float:
	return _t_fly + FLY_DURATION + FADE_OUT


## 跳过：直接进入「徽记飞回顶栏」并加速收尾，仍保证 emblem_landed / finished 都会发出，
## 顶栏纸徽换图与日历换字不会因跳过而丢失。
func skip() -> bool:
	if not can_skip():
		return false
	if _skipped:
		_speed = SKIP_SPEED * 2.0
		return true
	_skipped = true
	if _t < _t_fly:
		_t = _t_fly
	_speed = SKIP_SPEED
	_embers.emitting = false
	_motes.emitting = false
	return true


## 世界切换：立即撤掉，不发信号（新世界不应补播旧世界的落地）。
func abort() -> void:
	_playing = false
	set_process(false)
	queue_free()


## 同一会话连续两次晋升：前一场立即完成并发出全部信号。
func finish_now() -> void:
	if not _playing:
		return
	if not _landed:
		_landed = true
		emblem_landed.emit()
	_finish()


func _process(delta: float) -> void:
	advance(delta)


func advance(delta: float) -> void:
	if not _playing:
		return
	_t += maxf(0.0, delta) * _speed
	_rays_rot += maxf(0.0, delta) * 0.22
	_apply(delta)
	if not _landed and _t >= _t_fly + FLY_DURATION:
		_landed = true
		emblem_landed.emit()
	if _t >= _t_fly + FLY_DURATION + FADE_OUT:
		_finish()


func _finish() -> void:
	if _done:
		return
	_playing = false
	_done = true
	set_process(false)
	visible = false
	finished.emit()
	queue_free()


func _gui_input(event: InputEvent) -> void:
	if not _playing:
		return
	var press := false
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		press = button.pressed and button.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]
	elif event is InputEventScreenTouch:
		press = (event as InputEventScreenTouch).pressed
	if press:
		skip()
	# 演出是模态的：指针事件一律消费，避免误选地图。
	accept_event()


func _input(event: InputEvent) -> void:
	if not _playing or not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if key.pressed and not key.echo:
		if key.keycode in [KEY_ESCAPE, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE] \
				or (InputMap.has_action(&"ui_cancel") and key.is_action_pressed(&"ui_cancel")):
			skip()
	# 演出期间键盘也不穿透到地图/时钟快捷键。
	get_viewport().set_input_as_handled()


# ─── 布局 ────────────────────────────────────────────────────────────────

func _style_text() -> void:
	var display := UITokens.dossier_font("serif")
	_title.add_theme_font_override("font", display)
	_title.add_theme_color_override("font_color", TITLE_INK)
	_title.add_theme_color_override("font_outline_color", OUTLINE_INK)
	_title.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.55))
	_kicker.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_kicker.add_theme_color_override("font_color", Color(UITokens.HUD_BRASS_GLOW, 0.92))
	_subtitle.add_theme_font_override("font", UITokens.DOSSIER_SERIF)
	_subtitle.add_theme_color_override("font_color", UITokens.CHRONICLE_PAPER)
	_subtitle.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.6))
	_buff_label.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_buff_label.add_theme_color_override("font_color", UITokens.HUD_BRASS_GLOW)
	for child in _buff_heading.get_children():
		if child is ColorRect:
			(child as ColorRect).color = Color(UITokens.HUD_BRASS_GLOW, 0.55)
	for i in range(_buff_rows.get_child_count()):
		var label := _buff_rows.get_child(i).get_node("Text") as Label
		label.add_theme_font_override("font", UITokens.dossier_font("sans"))
		label.add_theme_color_override("font_color", UITokens.HUD_ACTIVE_TEXT)
		label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.6))
	_skip_hint.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_skip_hint.add_theme_color_override("font_color", UITokens.CHRONICLE_PAPER)


func _layout() -> void:
	if not is_node_ready():
		return
	var view := size
	if view.x <= 1.0 or view.y <= 1.0:
		view = get_viewport_rect().size
	_scale = clampf(minf(view.x / 1600.0, view.y / 960.0), 0.62, 1.35)
	_emblem = BASE_EMBLEM * _scale
	_center = Vector2(view.x * 0.5, view.y * 0.34)
	for emblem in [_old, _new]:
		var rect := emblem as TextureRect
		rect.size = Vector2.ONE * _emblem
		rect.pivot_offset = rect.size * 0.5
	_title.add_theme_font_size_override("font_size", roundi(92.0 * _scale))
	_title.add_theme_constant_override("outline_size", maxi(4, roundi(12.0 * _scale)))
	_title.add_theme_constant_override("shadow_offset_y", roundi(4.0 * _scale))
	_kicker.add_theme_font_size_override("font_size", roundi(20.0 * _scale))
	_subtitle.add_theme_font_size_override("font_size", roundi(27.0 * _scale))
	_buff_label.add_theme_font_size_override("font_size", roundi(21.0 * _scale))
	for child in _buff_heading.get_children():
		if child is ColorRect:
			(child as ColorRect).custom_minimum_size = Vector2(72.0 * _scale, 1.0)
	for i in range(_buff_rows.get_child_count()):
		var row := _buff_rows.get_child(i)
		(row.get_node("Text") as Label).add_theme_font_size_override(
			"font_size", roundi(21.0 * _scale))
		(row.get_node("Icon") as Control).custom_minimum_size = Vector2.ONE * roundf(24.0 * _scale)
	_skip_hint.add_theme_font_size_override("font_size", roundi(15.0 * _scale))
	# 文字块落在刻度环（0.76×徽记）之外，避免压住光环。
	_text.position = Vector2(0.0, _center.y + _emblem * 0.78 + 6.0 * _scale)
	_text.size = Vector2(view.x, 0.0)
	_text.custom_minimum_size = Vector2(view.x, 0.0)
	# 运笔揭示的横向范围 = 标题字形实际宽度（标签水平居中）。
	var font := _title.get_theme_font("font")
	var font_size := _title.get_theme_font_size("font_size")
	var text_width := font.get_string_size(_title.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x \
		if font != null else view.x * 0.4
	var mat := _title.material as ShaderMaterial
	mat.set_shader_parameter("x_min", (view.x - text_width) * 0.5)
	mat.set_shader_parameter("x_max", (view.x + text_width) * 0.5)
	mat.set_shader_parameter("softness", 46.0 * _scale)
	_embers.position = _center
	_embers.emission_sphere_radius = _emblem * 0.40
	_motes.position = _center + Vector2(0.0, -view.y * 0.10)
	_motes.emission_rect_extents = Vector2(46.0 * _scale, view.y * 0.24)
	_burst.position = _center
	_burst.initial_velocity_min = 260.0 * _scale
	_burst.initial_velocity_max = 640.0 * _scale
	_burst.gravity = Vector2(0.0, 300.0 * _scale)
	_sparks.initial_velocity_min = 140.0 * _scale
	_sparks.initial_velocity_max = 380.0 * _scale
	var bmat := _backdrop.material as ShaderMaterial
	bmat.set_shader_parameter("aspect", view.x / maxf(1.0, view.y))
	bmat.set_shader_parameter("center", Vector2(_center.x / view.x, _center.y / view.y))


func _rng_shards(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	_shards.clear()
	for i in range(SHARD_COUNT):
		var angle := TAU * (float(i) + rng.randf_range(-0.35, 0.35)) / float(SHARD_COUNT)
		var points := PackedVector2Array()
		var corners := rng.randi_range(3, 4)
		for c in range(corners):
			var a := TAU * float(c) / float(corners) + rng.randf_range(-0.4, 0.4)
			points.append(Vector2.from_angle(a) * rng.randf_range(0.55, 1.0))
		_shards.append({
			"dir": Vector2.from_angle(angle), "speed": rng.randf_range(160.0, 430.0),
			"start": rng.randf_range(0.18, 0.42), "spin": rng.randf_range(-7.0, 7.0),
			"size": rng.randf_range(9.0, 24.0), "points": points,
			"delay": rng.randf_range(0.0, 0.18),
		})


# ─── 逐帧状态 ────────────────────────────────────────────────────────────

static func _seg(t: float, a: float, b: float) -> float:
	return clampf((t - a) / maxf(b - a, 0.0001), 0.0, 1.0)


static func _ease_out(x: float) -> float:
	return 1.0 - pow(1.0 - x, 3.0)


static func _smooth(x: float) -> float:
	return x * x * (3.0 - 2.0 * x)


static func _back(x: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	return 1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0)


func _apply(_delta: float) -> void:
	var t := _t
	var fly := _smooth(_seg(t, _t_fly, _t_fly + FLY_DURATION))
	var out := _seg(t, _t_fly + FLY_DURATION, _t_fly + FLY_DURATION + FADE_OUT)
	var fade := _ease_out(_seg(t, 0.0, T_FADE_IN)) * (1.0 - _smooth(out))

	# 屏幕震动：裂纹期细颤，爆闪重震，新徽记落定轻震。
	var amp := 0.0
	if not _reduced:
		amp += 2.0 * _seg(t, T_CRACK, T_BURN) * (1.0 - _seg(t, T_BURN_END - 0.3, T_BURN_END))
		if t >= T_FLASH and t < _t_fly:
			amp += 15.0 * exp(-(t - T_FLASH) * 4.2)
		var settle := T_RISE_END - 0.25
		if t >= settle and t < _t_fly:
			amp += 5.0 * exp(-(t - settle) * 6.0)
	_shake = Vector2(sin(t * 71.3), cos(t * 53.7 + 1.3)) * amp * _scale

	# 光柱、放射、冲击波、爆闪。
	var rise := _seg(t, T_RISE, T_RISE_END)
	var pillar := _ease_out(_seg(t, T_PILLAR, T_PILLAR + 0.35)) \
		* (1.0 - 0.55 * _seg(t, T_RISE_END, T_RISE_END + 1.2)) * (1.0 - fly)
	var burst := _ease_out(_seg(t, T_FLASH, T_FLASH + 0.5)) \
		* (1.0 - 0.35 * _seg(t, T_RISE_END, T_RISE_END + 1.5)) * (1.0 - fly)
	var ring_radius := 0.0
	var ring_alpha := 0.0
	var ring_a := _seg(t, T_FLASH, T_FLASH + 1.1)
	var ring_b := _seg(t, T_RISE_END - 0.2, T_RISE_END + 0.8)
	if ring_b > 0.0 and ring_b < 1.0 and t < _t_fly:
		ring_radius = _ease_out(ring_b) * 0.55
		ring_alpha = (1.0 - ring_b) * 0.6
	elif ring_a > 0.0 and ring_a < 1.0 and t < _t_fly:
		ring_radius = _ease_out(ring_a) * 1.2
		ring_alpha = 1.0 - ring_a
	var flash := 0.0
	if t < _t_fly:
		flash = _seg(t, T_FLASH - 0.08, T_FLASH) if t < T_FLASH else exp(-(t - T_FLASH) * 5.5)
	var bmat := _backdrop.material as ShaderMaterial
	bmat.set_shader_parameter("fade", fade)
	bmat.set_shader_parameter("pillar", pillar)
	bmat.set_shader_parameter("burst", burst)
	bmat.set_shader_parameter("ring_radius", ring_radius)
	bmat.set_shader_parameter("ring_alpha", ring_alpha)
	bmat.set_shader_parameter("flash", flash * 0.6)
	bmat.set_shader_parameter("rays_angle", _rays_rot)

	# 旧徽记：浮现 → 裂纹 → 燃尽。
	var appear := _ease_out(_seg(t, 0.1, T_FADE_IN + 0.1))
	var crack := _seg(t, T_CRACK, T_BURN + 0.2)
	var burn := _smooth(_seg(t, T_BURN, T_BURN_END))
	_old.visible = _has_old and burn < 1.0 and t < _t_fly
	if _old.visible:
		var jitter := Vector2(sin(t * 97.0), cos(t * 83.0)) * crack * 3.0 * _scale * (0.0 if _reduced else 1.0)
		_old.position = _center - _old.size * 0.5 + _shake + jitter
		_old.scale = Vector2.ONE * (0.82 + 0.18 * appear + 0.04 * crack)
		var omat := _old.material as ShaderMaterial
		omat.set_shader_parameter("opacity", appear)
		omat.set_shader_parameter("dissolve", burn)
		omat.set_shader_parameter("crack", crack)
		omat.set_shader_parameter("glow", 0.35 * appear + 0.55 * crack)
		omat.set_shader_parameter("flash", 0.0)
	_embers.emitting = _has_old and t >= T_BURN and t < T_BURN_END and not _skipped
	_motes.emitting = t >= T_PILLAR and t < _t_fly - 0.4 and not _skipped

	if not _burst_fired and t >= T_FLASH and t < _t_fly:
		_burst_fired = true
		_burst.restart()
	if not _sparks_fired and t >= T_RISE_END - 0.2 and t < _t_fly:
		_sparks_fired = true
		_sparks.position = _center
		_sparks.restart()

	# 新徽记：从光中凝形升起 → 呼吸 → 飞回顶栏纸徽。
	var formed := _ease_out(rise)
	var scale_now := lerpf(0.35, 1.0, _back(rise)) if rise > 0.0 else 0.35
	if rise >= 1.0:
		scale_now *= 1.0 + 0.015 * sin((t - T_RISE_END) * 2.4)
	var position_now := _center + Vector2(0.0, (1.0 - formed) * 90.0 * _scale)
	var target := _target_point()
	if fly > 0.0:
		var control := Vector2(lerpf(_center.x, target.x, 0.5) + 90.0 * _scale,
			minf(_center.y, target.y) + 30.0 * _scale)
		var a := 1.0 - fly
		position_now = a * a * _center + 2.0 * a * fly * control + fly * fly * target
		scale_now = lerpf(scale_now, _target_size() / maxf(1.0, _emblem), fly)
	_emblem_center = position_now
	_emblem_scale = scale_now
	_new.visible = rise > 0.0 and out < 0.45
	_new.position = position_now - _new.size * 0.5 + _shake * (1.0 - fly)
	_new.scale = Vector2.ONE * scale_now
	_new.rotation = 0.0
	var nmat := _new.material as ShaderMaterial
	nmat.set_shader_parameter("opacity", 1.0 - _seg(out, 0.0, 0.45))
	nmat.set_shader_parameter("dissolve", 1.0 - formed)
	nmat.set_shader_parameter("crack", 0.0)
	nmat.set_shader_parameter("glow", (1.0 - 0.6 * fly) * minf(1.0, rise * 3.0))
	nmat.set_shader_parameter("flash", (1.0 - formed) * 0.9)
	_halo_strength = formed * (1.0 - fly)

	# 文字：书法运笔 → 副标题 → 加成逐条。飞回时整体淡出。
	var text_alpha := 1.0 - _seg(fly, 0.0, 0.6)
	_text.modulate.a = text_alpha
	_text.position.x = _shake.x * 0.5
	_kicker.modulate.a = _seg(t, T_TITLE - 0.2, T_TITLE + 0.3)
	var brush := _smooth(_seg(t, T_TITLE, T_TITLE_END))
	(_title.material as ShaderMaterial).set_shader_parameter("progress", brush)
	_title.modulate.a = 1.0 if brush > 0.0 else 0.0
	_subtitle.modulate.a = _seg(t, T_SUB, T_SUB + 0.5)
	_subtitle.visible_ratio = _seg(t, T_SUB, T_SUB + 0.6)
	_buff_heading.modulate.a = _seg(t, T_BUFF_HEAD, T_BUFF_HEAD + 0.35)
	for i in range(_buff_rows.get_child_count()):
		var row := _buff_rows.get_child(i) as Control
		var start := T_BUFF_HEAD + 0.35 + float(i) * BUFF_STEP
		row.modulate.a = _seg(t, start, start + 0.3)
		(row.get_node("Text") as Label).visible_ratio = _seg(t, start, start + 0.45)
	_skip_hint.modulate.a = 0.7 * _seg(t, SKIP_AFTER, SKIP_AFTER + 0.4) * (1.0 - fly)

	if fly > 0.0 and fly < 1.0:
		_trail.append(position_now)
		if _trail.size() > TRAIL_LENGTH:
			_trail.remove_at(0)
	elif fly >= 1.0 and not _trail.is_empty():
		_trail.remove_at(0)
	_halo.queue_redraw()
	_front.queue_redraw()


func _target_point() -> Vector2:
	if _target != null and is_instance_valid(_target) and _target.is_inside_tree():
		var global_center := _target.get_global_rect().get_center()
		return get_global_transform().affine_inverse() * global_center
	return Vector2(size.x * 0.5, 0.0)


func _target_size() -> float:
	if _target != null and is_instance_valid(_target) and _target.is_inside_tree():
		var rect := _target.get_global_rect()
		var local_scale := get_global_transform().get_scale()
		return rect.size.x / maxf(0.001, local_scale.x)
	return UITokens.ERA_BADGE_SIZE


# ─── 自绘层 ──────────────────────────────────────────────────────────────

## 徽记背后的放射光瓣与天文仪式刻度环（缓慢反向旋转）。
func _draw_halo() -> void:
	if _halo_strength <= 0.001:
		return
	var c := _emblem_center
	var s := _emblem * _emblem_scale
	var strength := _halo_strength
	var rays := 18
	for i in range(rays):
		var angle := _rays_rot * 1.4 + TAU * float(i) / float(rays)
		var reach := s * (0.95 + 0.30 * sin(float(i) * 1.7 + _t * 1.3))
		var half := 0.055 + 0.02 * float(i % 3)
		var inner := s * 0.30
		var points := PackedVector2Array([
			c + Vector2.from_angle(angle - half) * inner,
			c + Vector2.from_angle(angle) * reach,
			c + Vector2.from_angle(angle + half) * inner,
		])
		var base := Color(GOLD, 0.30 * strength)
		var tip := Color(GOLD, 0.0)
		_halo.draw_polygon(points, PackedColorArray([base, tip, base]))
	# 内外两道刻度环，一顺一逆。
	var ring_color := Color(GOLD_HOT, 0.55 * strength)
	_halo.draw_arc(c, s * 0.64, 0.0, TAU, 128, ring_color, maxf(1.0, 1.6 * _scale), true)
	_halo.draw_arc(c, s * 0.71, 0.0, TAU, 128, Color(GOLD, 0.30 * strength), maxf(1.0, 1.0 * _scale), true)
	for i in range(48):
		var angle := -_rays_rot * 2.0 + TAU * float(i) / 48.0
		var dir := Vector2.from_angle(angle)
		var long := i % 4 == 0
		_halo.draw_line(c + dir * s * 0.71, c + dir * s * (0.76 if long else 0.735),
			Color(GOLD, (0.65 if long else 0.35) * strength), maxf(1.0, 1.4 * _scale), true)
	for i in range(8):
		var angle := _rays_rot * 3.0 + TAU * float(i) / 8.0
		var p := c + Vector2.from_angle(angle) * s * 0.82
		_halo.draw_circle(p, 3.0 * _scale, Color(GOLD_HOT, 0.75 * strength))


## 燃尽时飞散的徽记碎片 + 飞回顶栏时的彗尾。
func _draw_front() -> void:
	var st := _t - T_SHARDS
	if _has_old and st > 0.0 and st < 1.6 and _t < _t_fly:
		for shard in _shards:
			var local_t := st - float(shard.delay)
			if local_t <= 0.0:
				continue
			var alpha := 1.0 - _seg(local_t, 0.6, 1.35)
			if alpha <= 0.0:
				continue
			var dir: Vector2 = shard.dir
			var origin := _center + dir * _emblem * float(shard.start)
			var pos := origin + dir * float(shard.speed) * _scale * local_t \
				+ Vector2(0.0, 260.0 * _scale) * local_t * local_t
			var rot := float(shard.spin) * local_t
			var radius := float(shard.size) * _scale
			var pts := PackedVector2Array()
			for p: Vector2 in shard.points:
				pts.append(pos + p.rotated(rot) * radius)
			_front.draw_colored_polygon(pts, Color(0.20, 0.12, 0.06, 0.92 * alpha))
			var edge := pts.duplicate()
			edge.append(pts[0])
			_front.draw_polyline(edge, Color(GOLD_HOT.lerp(Color(1.0, 0.45, 0.1), local_t), alpha),
				maxf(1.0, 1.5 * _scale), true)
	if _trail.size() >= 2:
		for i in range(_trail.size()):
			var k := float(i + 1) / float(_trail.size())
			_front.draw_circle(_trail[i], (3.0 + 9.0 * k) * _scale, Color(GOLD, 0.10 * k))
			_front.draw_circle(_trail[i], (1.5 + 2.5 * k) * _scale, Color(GOLD_HOT, 0.65 * k))
