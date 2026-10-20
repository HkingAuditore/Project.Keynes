extends Control
## 马里探索音乐试听台：验证 FMOD 事件表接入是否真的能出声。
## 状态栏会持续显示 bank / 音量 / 静音 / 时间轴，方便定位"没声音"。

const Catalog := preload("res://scripts/audio/music_event_catalog.gd")
const ERA_LABELS := {
	&"dark": "黑暗", &"feudal": "封建", &"castle": "城堡", &"imperial": "帝王",
}

var _audio: Node
var _status: Label
var _current := ""
var _last := ""


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
		GameSettings.update({"master_volume": value}, false)
		_refresh())
	box.add_child(vol)

	var mute := CheckButton.new()
	mute.text = "静音主总线（当前会影响所有声音）"
	mute.button_pressed = bool(GameSettings.values().master_muted)
	mute.toggled.connect(func(value: bool) -> void:
		GameSettings.update({"master_muted": value}, false)
		_refresh())
	box.add_child(mute)

	await get_tree().process_frame
	_refresh()


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
	var ok: bool = _audio.play_music(key)
	_current = ("探索 · %s · %s" % [String(ERA_LABELS.get(era, era)), String(key)]) if ok else "播放失败"
	_last = ""
	_refresh()


func _on_transition(key: StringName) -> void:
	_last = "过渡 %s → %s" % [String(key), "成功" if _audio.play_transition(key) else "失败"]
	_refresh()


func _on_stinger(key: StringName) -> void:
	_last = "胜利 %s → %s" % [String(key), "成功" if _audio.play_stinger(key) else "失败"]
	_refresh()


func _on_stop() -> void:
	_audio.stop_music()
	_current = ""
	_last = "已停止"
	_refresh()


func _refresh() -> void:
	var info: Dictionary = _audio.diagnostics()
	var lines := PackedStringArray()
	lines.append("后端: %s" % String(_audio.status))
	lines.append("banks=%d   音乐=%s   主音量=%.2f   静音=%s" % [
		int(info.get("banks", 0)),
		"在播" if bool(info.get("music_playing", false)) else "无",
		float(info.get("master_volume", -1.0)),
		"是" if bool(info.get("master_muted", true)) else "否"])
	if info.has("timeline_ms"):
		lines.append("时间轴: %d ms" % int(info.get("timeline_ms", 0)))
	lines.append("当前: %s" % (_current if not _current.is_empty() else "无"))
	if not _last.is_empty():
		lines.append(_last)
	_status.text = "\n".join(lines)


func _process(_delta: float) -> void:
	if _audio != null and Engine.get_process_frames() % 30 == 0:
		_refresh()


func _exit_tree() -> void:
	if _audio != null:
		_audio.stop_music()
