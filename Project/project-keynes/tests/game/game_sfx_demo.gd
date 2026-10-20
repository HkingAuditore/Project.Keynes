extends Control
## 7 个游戏事件音效的试听台。点按钮听，状态栏显示是否被冷却挡下。

const CUES := [
	[&"tech_research", "科技研发完成"],
	[&"territory_expand", "开拓地块"],
	[&"ideology_draw", "抽取理念"],
	[&"ideology_use", "使用理念"],
	[&"building_complete", "建筑落成"],
	[&"population_grow", "人口增长（2.5s 冷却）"],
	[&"trade", "地块贸易（2.5s 冷却）"],
]

var _audio: Node
var _status: Label


func _ready() -> void:
	_audio = get_node("/root/GameAudio")
	DisplayServer.window_set_title("ProjectKeynes - 游戏事件音效")

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	var title := Label.new()
	title.text = "游戏事件音效 · CC0"
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	for entry in CUES:
		var cue: StringName = entry[0]
		var b := Button.new()
		b.text = String(entry[1])
		b.custom_minimum_size.y = 40
		b.pressed.connect(_on_press.bind(cue))
		box.add_child(b)

	var mute := CheckButton.new()
	mute.text = "静音主总线（当前会影响所有声音）"
	mute.button_pressed = bool(GameSettings.values().master_muted)
	mute.toggled.connect(func(value: bool) -> void:
		GameSettings.update({"master_muted": value}, false)
		_refresh())
	box.add_child(mute)

	await get_tree().process_frame
	_refresh()


func _on_press(cue: StringName) -> void:
	var ok: bool = _audio.play_event_cue(cue)
	_status.text = "上次: %s → %s" % [String(cue), "播放" if ok else "被冷却挡下/不可用"]
	_refresh()


func _refresh() -> void:
	var info: Dictionary = _audio.diagnostics()
	_status.text = "后端: %s   banks=%d   主音量=%.2f   静音=%s\n%s" % [
		String(_audio.status), int(info.get("banks", 0)),
		float(info.get("master_volume", -1.0)),
		"是" if bool(info.get("master_muted", true)) else "否",
		_status.text]


func _exit_tree() -> void:
	if _audio != null:
		_audio.stop_music()
