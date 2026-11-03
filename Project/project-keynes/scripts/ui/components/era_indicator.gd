extends Control
class_name EraIndicator

const TouchUI = preload("res://scripts/ui/touch_ui.gd")

signal pressed()
signal era_advanced(model: Dictionary)
@onready var _badge: Control = %Badge
@onready var _icon: TextureRect = %Icon
@onready var _shadow: TextureRect = %Shadow
@onready var _hit: Button = %Hit
var _model: Dictionary = {}
var _offer_available := false
var _hovered := false
var _pinned := false
var _celebrating := false
var _slide: Tween
var _reveal_target_y := UITokens.ERA_BADGE_REST_Y
var _reveal_target_scale := 1.0
var _ceremony: Tween
var _textures: Dictionary = {}
var _fx := 0.0:
	set(value):
		_fx = value
		if is_node_ready():
			(_icon.material as ShaderMaterial).set_shader_parameter("ceremony", value if _celebrating else 0.0)
			_icon.scale = Vector2.ONE * (1.0 + 0.08 * sin(PI * value))
			_shadow.scale = _icon.scale
		queue_redraw()

func _ready() -> void:
	_hit.mouse_entered.connect(func() -> void: _hovered = true; _update_reveal())
	_hit.mouse_exited.connect(func() -> void: _hovered = false; _update_reveal())
	_hit.focus_entered.connect(_update_reveal)
	_hit.focus_exited.connect(_update_reveal)
	_hit.pressed.connect(func() -> void: pressed.emit())
	_badge.position.y = UITokens.ERA_BADGE_REST_Y
	_badge.pivot_offset = Vector2.ONE * UITokens.ERA_BADGE_SIZE * 0.5

func reset_for_world() -> void:
	if _slide != null and _slide.is_valid():
		_slide.kill()
	if _ceremony != null and _ceremony.is_valid():
		_ceremony.kill()
	_model.clear()
	_pending_era_id = ""
	set_advancement("", 0.0)
	_celebrating = false
	_pinned = false
	_hovered = false
	_hit.release_focus()
	# focus_exited 可能启动一次收起 Tween；世界切换必须直接回到静止基线。
	if _slide != null and _slide.is_valid():
		_slide.kill()
	_badge.position.y = UITokens.ERA_BADGE_REST_Y
	_badge.scale = Vector2.ONE
	_reveal_target_y = UITokens.ERA_BADGE_REST_Y
	_reveal_target_scale = 1.0
	_fx = 0.0
	set_offer_available(false)
	_update_reveal()

## 由 GameUIManager 打开：会话内晋升交给全屏大典演出，纸徽先保留旧图标，
## 等新徽记飞回顶栏时（reveal_pending_era）才换图并闪光。未接管时沿用纸徽自身的小礼花。
var defer_celebration := false
var _pending_era_id := ""
var _advancement_status := ""
var _advancement_progress := 0.0


func set_model(model: Dictionary) -> void:
	if model.is_empty():
		return
	var advanced := not _model.is_empty() and int(model.era_index) > int(_model.era_index)
	var era_id := String(model.era_id)
	if advanced and defer_celebration:
		_pending_era_id = era_id
	elif _pending_era_id.is_empty() and _model.get("era_id", "") != era_id:
		_apply_era_texture(era_id)
	_model = model
	_update_tooltip()
	if advanced:
		if not defer_celebration:
			play_era_advance_fx()
		era_advanced.emit(model)


static func era_texture(era_id: String) -> Texture2D:
	var path := "res://assets/icons/era/era_%s.png" % era_id
	return load(path) as Texture2D if not era_id.is_empty() and ResourceLoader.exists(path) else null


func _apply_era_texture(era_id: String) -> void:
	if not _textures.has(era_id):
		_textures[era_id] = era_texture(era_id)
	_icon.texture = _textures[era_id]
	_shadow.texture = _icon.texture


## 大典的新徽记落到纸徽上：换成新时代图标并播放纸徽自身的金环礼花。
## 以大典流程为准的同时，始终把图标对齐到当前模型，避免大典被跳过、被打断、
## 或 landed 信号因索引不匹配没走到时，纸徽永远停在旧时代图标上。
func reveal_pending_era(play_fx: bool = true) -> void:
	var target := _pending_era_id
	_pending_era_id = ""
	if target.is_empty():
		target = String(_model.get("era_id", ""))
	if not target.is_empty():
		_apply_era_texture(target)
	if play_fx:
		play_era_advance_fx()


func has_pending_era() -> bool:
	return not _pending_era_id.is_empty()


## 时代晋升收购状态：收购中金色自上而下漫过徽记（progress = 快照 progress），
## 暂停时淡金静止，条件达成未开始时外缘呼吸。研究里程碑不再驱动这层进度。
func set_advancement(status: String, progress: float) -> void:
	_advancement_status = status
	_advancement_progress = clampf(progress, 0.0, 1.0)
	var mat := _icon.material as ShaderMaterial
	mat.set_shader_parameter("progress", _advancement_progress)
	mat.set_shader_parameter("purchasing", status == "purchasing" or status == "completing")
	mat.set_shader_parameter("paused", status == "paused")
	mat.set_shader_parameter("advance_ready", status == "ready")
	_update_tooltip()


func icon_origin() -> Control:
	return _icon

func set_offer_available(available: bool) -> void:
	_offer_available = available
	(_icon.material as ShaderMaterial).set_shader_parameter("reward_available", available)
	_update_tooltip()

func set_expanded(expanded: bool) -> void:
	_pinned = expanded
	if not expanded:
		_hit.release_focus()
		if TouchUI.is_touch() or not _hit.get_global_rect().has_point(get_viewport().get_mouse_position()):
			_hovered = false
	_update_reveal()

func _update_tooltip() -> void:
	var lines := PackedStringArray([String(_model.get("era_name", "时代")), "点击打开时代晋升"])
	match _advancement_status:
		"ready":
			lines.append("前提条件已满足，可以开始晋升")
		"purchasing", "completing":
			lines.append("收购物资中 · %d%%" % int(floor(_advancement_progress * 100.0)))
		"paused":
			lines.append("收购已暂停 · %d%%" % int(floor(_advancement_progress * 100.0)))
	if _offer_available:
		lines.append("时代奖励待领取")
	_hit.tooltip_text = "\n".join(lines)

func _update_reveal() -> void:
	var hovering := _hovered or _hit.has_focus()
	var target_y := UITokens.ERA_BADGE_OPEN_Y if _pinned else (UITokens.ERA_BADGE_HOVER_Y if hovering else UITokens.ERA_BADGE_REST_Y)
	var target_scale := UITokens.ERA_BADGE_HOVER_SCALE if hovering and not _pinned else 1.0
	# 热区固定贴住屏幕顶沿，避免纸徽下滑后离开鼠标、反复展开/收起。
	_hit.size.y = target_y + UITokens.ERA_BADGE_SIZE + (target_scale - 1.0) * UITokens.ERA_BADGE_SIZE * 0.5
	(_icon.material as ShaderMaterial).set_shader_parameter("highlighted", _hovered or _hit.has_focus())
	# 同一展开状态不重启 Tween，悬停、焦点和晋升通知可平滑共存。
	if is_equal_approx(_reveal_target_y, target_y) and is_equal_approx(_reveal_target_scale, target_scale):
		return
	_reveal_target_y = target_y
	_reveal_target_scale = target_scale
	if _slide != null and _slide.is_valid():
		_slide.kill()
	var duration := UITokens.ERA_BADGE_SLIDE_SECONDS if _pinned else UITokens.ERA_BADGE_HOVER_SECONDS
	_slide = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide.tween_property(_badge, "position:y", target_y, duration)
	_slide.tween_property(_badge, "scale", Vector2.ONE * target_scale, duration)

func play_era_advance_fx() -> void:
	if _ceremony != null and _ceremony.is_valid():
		_ceremony.kill()
	_celebrating = true
	_update_reveal()
	_fx = 0.0
	_ceremony = create_tween()
	_ceremony.tween_property(self, "_fx", 1.0, UITokens.ERA_BADGE_ADVANCE_SECONDS)
	_ceremony.tween_callback(func() -> void:
		_celebrating = false
		_fx = 0.0
		_update_reveal())

func _draw() -> void:
	if not _celebrating or _fx <= 0.0:
		return
	var center := Vector2(UITokens.ERA_BADGE_SIZE * 0.5, _badge.position.y + UITokens.ERA_BADGE_SIZE * 0.5)
	var envelope := sin(PI * _fx)
	var gold := UITokens.ERA_BADGE_GOLD
	for ring in range(3):
		var radius := 75.0 + _fx * (135.0 + ring * 32.0)
		draw_arc(center, radius, 0, TAU, 96, Color(gold, envelope * (0.5 - ring * 0.1)), 2.0, true)
	for i in range(24):
		var direction := Vector2.from_angle(TAU * float(i) / 24.0 + 0.10 * _fx)
		draw_line(center + direction * 100.0, center + direction * (115.0 + envelope * (35.0 + (i % 3) * 20.0)), Color(gold, envelope * 0.75), 2.0, true)
	for i in range(40):
		var direction := Vector2.from_angle(TAU * float(i) / 40.0)
		var point := center + direction * (75.0 + _fx * (90.0 + (i % 5) * 17.0)) + Vector2(0, _fx * _fx * 145.0)
		var color := Color(gold if i % 3 else UITokens.CHRONICLE_PAPER, envelope)
		draw_set_transform(point, _fx * (i % 4 + 1) * PI)
		draw_rect(Rect2(-3, -5, 6, 10), color)
	draw_set_transform(Vector2.ZERO)
