extends Control
var _settings_before: Dictionary = {}

func _ready() -> void:
	_settings_before = GameSettings.values()
	GameSettings.update({"window_mode":"windowed","resolution_width":900,"resolution_height":540},false)
	DisplayServer.window_set_title("ProjectKeynes - FMOD music prototype")
	var audio := get_node("/root/GameAudio")
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left","right","top","bottom"]:
		margin.add_theme_constant_override("margin_" + side,32)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation",18)
	margin.add_child(box)
	var title := Label.new()
	title.text = "FMOD layered music prototype"
	title.add_theme_font_size_override("font_size",28)
	box.add_child(title)
	var note := Label.new()
	note.text = "Temporary synthesized audio. Tension adds melody, then percussion.\nBackend: " + audio.status
	box.add_child(note)
	var label := Label.new()
	label.text = "Tension: 0.00"
	box.add_child(label)
	var slider := HSlider.new()
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value_changed.connect(func(value: float) -> void:
		audio.set_tension(value)
		label.text = "Tension: %.2f" % value)
	box.add_child(slider)
	var click := Button.new()
	click.text = "Play UI click"
	click.pressed.connect(audio.play_ui_click)
	box.add_child(click)
	var volume_label := Label.new()
	volume_label.text = "Master volume"
	box.add_child(volume_label)
	var volume := HSlider.new()
	volume.max_value = 1.0
	volume.step = 0.01
	volume.value = float(GameSettings.values().master_volume)
	volume.tooltip_text = "Master volume (this preview does not save settings)"
	volume.value_changed.connect(func(value: float) -> void: GameSettings.update({"master_volume":value},false))
	box.add_child(volume)
	var mute := CheckButton.new()
	mute.text = "Mute Master"
	mute.button_pressed = bool(GameSettings.values().master_muted)
	mute.toggled.connect(func(value: bool) -> void: GameSettings.update({"master_muted":value},false))
	box.add_child(mute)
	audio.play_prototype()
	slider.grab_focus()
	if OS.get_environment("PK_FMOD_CAPTURE") != "":
		_capture_preview.call_deferred()

func _capture_preview() -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_environment("PK_FMOD_CAPTURE"))
	get_tree().quit()

func _exit_tree() -> void:
	get_node("/root/GameAudio").stop_music()
	GameSettings.update(_settings_before,false)
