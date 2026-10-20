extends Control
## 马里探索音乐试听台：验证 FMOD 事件表接入是否真的能出声。

const Catalog := preload("res://scripts/audio/music_event_catalog.gd")
const ERA_LABELS := {
	&"dark": "黑暗", &"feudal": "封建", &"castle": "城堡", &"imperial": "帝王",
}

var _audio: Node
var _status: Label
var _current := ""


func _ready() -> void:
	_audio = get_node("/root/GameAudio")
	DisplayServer.window_set_title("ProjectKeynes - 马里探索音乐")

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	var title := Label.new()
	title.text = "马里 · 探索音乐"
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_refresh()

	box.add_child(_section("时代 · 同代三段随机轮播"))
	var eras := HBoxContainer.new()
	eras.add_theme_constant_override("separation", 8)
	box.add_child(eras)
	for era in [&"dark", &"feudal", &"castle", &"imperial"]:
		var b := _button(String(ERA_LABELS[era]) + "时代")
		b.pressed.connect(_on_era.bind(era))
		eras.add_child(b)

	box.add_child(_section("时代升级过渡 · 叠加，不打断音乐"))
	var trans := HBoxContainer.new()
	trans.add_theme_constant_override("separation", 8)
	box.add_child(trans)
	for key in Catalog.TRANSITION.keys():
		var b := _button(String(key).replace("trans_explore_", ""))
		b.pressed.connect(_on_transition.bind(key))
		trans.add_child(b)

	box.add_child(_section("胜利 stinger · 叠加，不打断音乐"))
	var sting := HBoxContainer.new()
	sting.add_theme_constant_override("separation", 8)
	box.add_child(sting)
	for key in Catalog.STINGER.keys():
		var b := _button(String(key).replace("sting_", ""))
		b.pressed.connect(_on_stinger.bind(key))
		sting.add_child(b)

	var stop := _button("停止音乐")
	stop.pressed.connect(_on_stop)
	box.add_child(stop)

	var vol_label := Label.new()
	vol_label.text = "主音量"
	box.add_child(vol_label)
	var vol := HSlider.new()
	vol.max_value = 1.0
	vol.step = 0.01
	vol.value = float(GameSettings.values().master_volume)
	vol.value_changed.connect(func(value: float) -> void:
		GameSettings.update({"master_volume": value}, false))
	box.add_child(vol)


func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	return label


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 38
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return button


func _on_era(era: StringName) -> void:
	var tracks := Catalog.tracks_for(era)
	if tracks.is_empty():
		return
	var key: StringName = tracks[randi() % tracks.size()]
	if _audio.play_music(key):
		_current = "探索 · %s · %s" % [String(ERA_LABELS.get(era, era)), String(key)]
		_refresh()


func _on_transition(key: StringName) -> void:
	if _audio.play_transition(key):
		_status.text = "当前: %s\n过渡: %s" % [_current, String(key)]


func _on_stinger(key: StringName) -> void:
	if _audio.play_stinger(key):
		_status.text = "当前: %s\n胜利: %s" % [_current, String(key)]


func _on_stop() -> void:
	_audio.stop_music()
	_current = ""
	_refresh()


func _refresh() -> void:
	var backend: String = String(_audio.status)
	if _current.is_empty():
		_status.text = "后端: %s\n当前: 无" % backend
	else:
		_status.text = "后端: %s\n当前: %s" % [backend, _current]


func _exit_tree() -> void:
	if _audio != null:
		_audio.stop_music()
