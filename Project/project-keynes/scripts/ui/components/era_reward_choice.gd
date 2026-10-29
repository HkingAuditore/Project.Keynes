extends PanelContainer
class_name EraRewardChoice

signal selected()

@onready var _icon: IconBadge = %Icon
@onready var _title: Label = %Title
@onready var _description: Label = %Description
@onready var _choose: Button = %Choose

var _option_empty := true
var _paper_motion: Tween
var _entering := false

func _ready() -> void:
	_choose.pressed.connect(func() -> void: selected.emit())
	mouse_entered.connect(_hover_paper.bind(true))
	mouse_exited.connect(_hover_paper.bind(false))
	_choose.focus_entered.connect(_hover_paper.bind(true))
	_choose.focus_exited.connect(_hover_paper.bind(false))
	resized.connect(func() -> void: pivot_offset = size * 0.5)

func play_reveal(delay: float) -> void:
	if _paper_motion != null and _paper_motion.is_valid():
		_paper_motion.kill()
	pivot_offset = size * 0.5
	rotation = 0.0
	scale = Vector2.ONE
	modulate = Color.WHITE
	if UIAnimation.reduced_motion():
		return
	_entering = true
	rotation = deg_to_rad(-0.8)
	scale = Vector2(0.98, 0.92)
	modulate.a = 0.0
	_paper_motion = create_tween()
	_paper_motion.tween_interval(delay)
	_paper_motion.tween_property(self, "modulate:a", 1.0, 0.10)
	_paper_motion.parallel().tween_property(self, "rotation", 0.0, 0.20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_paper_motion.parallel().tween_property(self, "scale", Vector2.ONE, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_paper_motion.tween_callback(func() -> void: _entering = false)

func _hover_paper(hovered: bool) -> void:
	if _entering or _choose.disabled or UIAnimation.reduced_motion():
		return
	if _paper_motion != null and _paper_motion.is_valid():
		_paper_motion.kill()
	pivot_offset = size * 0.5
	_paper_motion = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_paper_motion.tween_property(self, "scale", Vector2.ONE * (1.01 if hovered else 1.0), 0.12)
	_paper_motion.tween_property(self, "rotation", deg_to_rad(-0.25) if hovered else 0.0, 0.12)

func mark_selected(selected_choice: bool) -> void:
	if _paper_motion != null and _paper_motion.is_valid():
		_paper_motion.kill()
	_entering = false
	rotation = 0.0
	scale = Vector2.ONE
	_paper_motion = create_tween()
	_paper_motion.tween_property(self, "modulate:a", 1.0 if selected_choice else 0.55, 0.12)

func set_option(option: Dictionary) -> void:
	_option_empty = option.is_empty()
	var icon_key := StringName(option.get("icon_key", "system.unknown"))
	_icon.set_semantic(icon_key, UITokens.ARCHIVE_BRASS)
	_title.text = String(option.get("title", "暂无方案"))
	_description.text = String(option.get("description", "当前没有可用的时代奖励。"))
	var reasons: PackedStringArray = option.get("reasons", PackedStringArray())
	_choose.disabled = _option_empty
	tooltip_text = "%s\n作用对象：%s" % [String(option.get("category", "时代方案")), String(option.get("target_summary", "玩家国家"))]
	if not reasons.is_empty():
		tooltip_text += "\n适配：" + "；".join(reasons)
	_choose.tooltip_text = "当前没有可用的时代方案" if _option_empty else "采纳「%s」\n%s" % [_title.text, tooltip_text]

func choose_button() -> Button:
	return _choose

func set_pending(pending: bool) -> void:
	_choose.disabled = pending or _option_empty

func option_empty() -> bool:
	return _option_empty
