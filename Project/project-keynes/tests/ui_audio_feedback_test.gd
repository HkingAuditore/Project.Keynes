extends Node

var _failed := false
var _heard: Array[StringName] = []
var _audio: Node
var _before: Dictionary


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	print("[ui-audio] ", "PASS " if ok else "FAIL ", label)
	_failed = _failed or not ok


func _click(control: Control) -> void:
	await get_tree().create_timer(.14).timeout
	var point := control.get_global_rect().get_center()
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		event.pressed = down
		get_viewport().push_input(event, true)
	await get_tree().process_frame


func _button(cue: StringName = &"") -> Button:
	var button := Button.new()
	button.position = Vector2(20, 20)
	button.size = Vector2(180, 50)
	if cue != &"":
		button.set_meta(&"ui_sound", cue)
	add_child(button)
	return button


func _run() -> void:
	get_window().size = Vector2i(1280, 720)
	get_window().content_scale_size = Vector2i(1280, 720)
	get_window().content_scale_factor = 1.0
	_audio = get_node("/root/GameAudio")
	_check(_audio.status == "ready", "FMOD backend ready")
	if _audio.status != "ready":
		get_tree().quit(1)
		return
	_before = GameSettings.values()
	GameSettings.update({"master_muted": true, "reduce_motion": true}, false)
	_audio.ui_sound_played.connect(func(cue: StringName) -> void: _heard.append(cue))
	for cue in _audio.UI_EVENTS:
		await get_tree().create_timer(.14).timeout
		_check(_audio.play_ui(cue), "bank event plays: " + String(cue))
	_check(not _audio.play_ui(&"unknown"), "unknown cue rejected")
	_heard.clear()
	var button := _button()
	# Rebinding a branch must not add a second handler.
	_audio.get_node("UIFeedback")._bind_branch(self)
	_check(button.pressed.get_connections().size() == 1, "rebind retains one activation handler")
	await _click(button)
	_check(_heard == [&"click"], "dynamic mouse click plays exactly once")
	button.disabled = true
	await _click(button)
	_check(_heard.size() == 1, "disabled button remains silent")
	button.disabled = false
	button.set_meta(&"ui_sound", &"none")
	await _click(button)
	_check(_heard.size() == 1, "explicit opt-out remains silent")
	button.set_meta(&"ui_sound", &"page")
	button.grab_focus()
	await get_tree().create_timer(.14).timeout
	for down in [true, false]:
		var event := InputEventAction.new()
		event.action = &"ui_accept"
		event.pressed = down
		get_viewport().push_input(event)
	await get_tree().process_frame
	_check(_heard.back() == &"page" and _heard.size() == 2, "keyboard accept uses semantic cue once")
	button.queue_free()
	await get_tree().process_frame
	var toggle := _button()
	toggle.toggle_mode = true
	preload("res://scripts/ui/ui_audio_feedback.gd").tag_icon(toggle, &"hud.clock.play")
	_check(not toggle.has_meta(&"ui_sound"), "state-changing toggle icon preserves toggle cues")
	_heard.clear()
	toggle.button_pressed = true
	toggle.set_pressed_no_signal(false)
	_check(_heard.is_empty(), "programmatic toggle synchronization is silent")
	await _click(toggle)
	await _click(toggle)
	_check(_heard == [&"toggle_on", &"toggle_off"], "toggle states have distinct cues")
	toggle.queue_free()
	await get_tree().process_frame
	var closing := Button.new()
	closing.position = Vector2(20, 20)
	closing.size = Vector2(180, 50)
	closing.set_meta(&"ui_sound", &"close")
	closing.pressed.connect(closing.hide) # Connected before node_added binding.
	add_child(closing)
	await _click(closing)
	_check(_heard.back() == &"close", "activation still sounds when earlier callback hides panel")
	closing.queue_free()
	await get_tree().process_frame
	var option := OptionButton.new()
	option.add_item("one")
	option.add_item("two")
	add_child(option)
	_heard.clear()
	option.select(1)
	_check(_heard.is_empty(), "programmatic dropdown selection is silent")
	option.queue_free()
	var slider := HSlider.new()
	slider.position = Vector2(20, 20)
	slider.size = Vector2(200, 40)
	add_child(slider)
	_heard.clear()
	slider.value = 10
	_check(_heard.is_empty(), "programmatic slider refresh is silent")
	await _click(slider)
	_check(_heard == [&"tick"], "slider release gives one quiet material tick")
	slider.queue_free()
	await get_tree().process_frame
	_heard.clear()
	var paused_button := _button(&"confirm")
	paused_button.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = true
	await _click(paused_button)
	_check(_heard == [&"confirm"], "pause menu feedback survives paused tree")
	get_tree().paused = false
	paused_button.queue_free()
	await get_tree().create_timer(.14).timeout
	_heard.clear()
	_check(_audio.play_ui(&"click") and not _audio.play_ui(&"click"), "same-cue burst limited")
	await get_tree().create_timer(.8).timeout
	_check(int(_audio.diagnostics().ui_voices) == 0, "completed one-shots release their FMOD instances")
	# Exercise the real product menu, including the page hiding itself on activation.
	var menu := load("res://scenes/main_menu.tscn").instantiate() as Control
	add_child(menu)
	await get_tree().create_timer(.4).timeout
	_heard.clear()
	await _click(menu.get_node("%SettingsButton"))
	_check(_heard == [&"open"], "production settings entry opens with paper cue")
	await get_tree().create_timer(.3).timeout
	await _click(menu.get_node("%SettingsBackButton"))
	_check(_heard == [&"open", &"close"], "production return closes with different cue: " + str(_heard))
	menu.queue_free()
	await get_tree().process_frame
	GameSettings.update(_before, false)
	print("UI_AUDIO_FEEDBACK_TEST_OK=", not _failed)
	get_tree().quit(1 if _failed else 0)
