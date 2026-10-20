extends Node
## GameAudio owns this signal adapter. No per-frame scan or simulation reads.
## Controls may override metadata/ui_sound; "none" opts out of automatic feedback.

var audio: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_bind_node)
	_bind_branch(get_tree().root)


func _bind_branch(node: Node) -> void:
	_bind_node(node)
	for child in node.get_children():
		_bind_branch(child)


func _bind_node(node: Node) -> void:
	if node is BaseButton:
		_connect_once(node.button_down, _on_button_down.bind(node))
		_connect_once(node.button_up, _on_button_up.bind(node))
		_connect_once(node.pressed, _on_button_pressed.bind(node))
		if node is OptionButton:
			# Selection emits only on user activation, unlike ordinary state synchronization.
			_connect_once(node.item_selected, _on_option_selected.bind(node))
	elif node is TabBar:
		_connect_once(node.tab_clicked, _on_tab_clicked.bind(node))
	elif node is Slider:
		_connect_once(node.drag_ended, _on_slider_released.bind(node))


func _connect_once(source: Signal, callback: Callable) -> void:
	if not source.is_connected(callback):
		source.connect(callback)


func _enabled(control: Control) -> bool:
	if not is_instance_valid(control) or not control.is_inside_tree() or not control.is_visible_in_tree():
		return false
	if control is BaseButton and control.disabled:
		return false
	var node: Node = control
	while node != null:
		if StringName(node.get_meta(&"ui_sound", &"")) == &"none":
			return false
		node = node.get_parent()
	return true


func _on_button_pressed(button: BaseButton) -> void:
	# A pre-existing activation callback may hide the panel before this callback runs.
	if not bool(button.get_meta(&"_ui_audio_armed", false)) and not _enabled(button):
		return
	button.set_meta(&"_ui_audio_armed", false)
	var cue := StringName(button.get_meta(&"ui_sound", &""))
	if cue == &"":
		if button is OptionButton:
			cue = &"open"
		elif button is CheckBox or button is CheckButton or button.toggle_mode:
			cue = &"toggle"
		else:
			cue = &"click"
	if cue == &"toggle":
		cue = &"toggle_on" if button.button_pressed else &"toggle_off"
	elif cue == &"fold":
		cue = &"open" if button.button_pressed else &"close"
	audio.play_ui(cue)


func _on_button_down(button: BaseButton) -> void:
	button.set_meta(&"_ui_audio_armed", _enabled(button))


func _on_button_up(button: BaseButton) -> void:
	_clear_armed.call_deferred(weakref(button))


func _clear_armed(reference: WeakRef) -> void:
	var button = reference.get_ref()
	if button != null:
		button.set_meta(&"_ui_audio_armed", false)


func _on_option_selected(_index: int, button: OptionButton) -> void:
	if _enabled(button):
		audio.play_ui(&"click")


func _on_tab_clicked(index: int, tabs: TabBar) -> void:
	if _enabled(tabs) and not tabs.is_tab_disabled(index):
		audio.play_ui(&"page")


func _on_slider_released(changed: bool, slider: Slider) -> void:
	if changed and slider.editable and _enabled(slider):
		audio.play_ui(&"tick")


## Material/icon semantics supply cues without depending on localized button text.
static func tag_icon(button: BaseButton, semantic: StringName) -> void:
	if button.has_meta(&"ui_sound") or button.toggle_mode:
		return
	var key := String(semantic).get_slice(".", String(semantic).count("."))
	var cues := {"close": &"close", "back": &"close", "confirm": &"confirm",
		"check": &"confirm", "play": &"confirm", "save": &"confirm",
		"settings": &"open", "history": &"open", "chevron_right": &"page"}
	if cues.has(key):
		button.set_meta(&"ui_sound", cues[key])


## Custom paper controls call this only after accepting an intentional gesture.
static func play_for(control: Control, cue: StringName) -> void:
	if not control.is_inside_tree() or not control.is_visible_in_tree():
		return
	var service := control.get_node_or_null("/root/GameAudio")
	if service != null:
		service.play_ui(cue)
