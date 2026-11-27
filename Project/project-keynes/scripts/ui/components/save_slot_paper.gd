extends PanelContainer

@onready var _button: Button = %LoadButton
@onready var _slip: Control = $Slip
var _slide: Tween


func _ready() -> void:
	for event in [_button.mouse_entered, _button.mouse_exited, _button.focus_entered, _button.focus_exited]:
		event.connect(_sync_selection)
	resized.connect(_sync_width)
	_sync_width()


func _sync_width() -> void:
	$Margin/Row/PreviewFrame.visible = size.x >= 680.0 and %Preview.texture != null
	%SavedAtLabel.visible = size.x >= 560.0
	%Description.visible = not %Description.text.is_empty()
	$Margin/Row/InfoColumn/HeaderRow.visible = %Description.visible or not %SavedAtLabel.text.is_empty()


func _sync_selection() -> void:
	var active := not _button.disabled and (_button.is_hovered() or _button.has_focus())
	$Locator.visible = active
	if _slide != null:
		_slide.kill()
	var shift := 7.0 if active else 0.0
	if UIAnimation.reduced_motion():
		_slip.position.x = shift
	else:
		_slide = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_slide.tween_property(_slip, "position:x", shift, 0.14)
