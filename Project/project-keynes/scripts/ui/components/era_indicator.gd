extends Control
class_name EraIndicator

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

func set_model(model: Dictionary) -> void:
	if model.is_empty():
		return
	var advanced := not _model.is_empty() and int(model.era_index) > int(_model.era_index)
	var era_id := String(model.era_id)
	if _model.get("era_id", "") != era_id:
		if not _textures.has(era_id):
			_textures[era_id] = load("res://assets/icons/era/era_%s.png" % era_id)
		_icon.texture = _textures[era_id]
		_shadow.texture = _icon.texture
	_model = model
	var mat := _icon.material as ShaderMaterial
	mat.set_shader_parameter("progress", float(model.progress))
	mat.set_shader_parameter("researching", bool(model.researching))
	_update_tooltip()
	if advanced:
		play_era_advance_fx()
		era_advanced.emit(model)


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
	_update_reveal()

func _update_tooltip() -> void:
	_hit.tooltip_text = "国家概况"
	if bool(_model.get("researching", false)):
		_hit.tooltip_text += "\n%s · %d%%" % [String(_model.research_name), roundi(float(_model.progress) * 100.0)]

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
