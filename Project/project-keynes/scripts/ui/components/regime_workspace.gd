extends Control
class_name RegimeWorkspace

## Political regime selector. The workspace only emits a player intent; the
## Country runtime remains the authority and reports the committed state back
## through the political view model.
signal regime_change_requested(regime_id: StringName)

var _model: Dictionary = {}
var _player_controller = null
var _compact := false
var _current_title: Label
var _current_detail: Label
var _current_capabilities: Label
var _options: VBoxContainer
var _status: Label
var _first_action: Button
var _option_buttons: Dictionary = {}
var _option_signature := ""


func _ready() -> void:
	_build_runtime_nodes()
	if not _model.is_empty():
		_apply_model()
	call_deferred("_focus_initial_action")


func _build_runtime_nodes() -> void:
	if _options != null:
		return
	var root := get_node_or_null("Root") as VBoxContainer
	if root == null:
		return
	_current_title = get_node_or_null("Root/Current/Body/Column/Title") as Label
	_current_detail = get_node_or_null("Root/Current/Body/Column/Detail") as Label
	_current_capabilities = get_node_or_null("Root/Current/Body/Column/Capabilities") as Label
	_options = get_node_or_null("Root/OptionsScroll/Options") as VBoxContainer
	_status = get_node_or_null("Root/Status") as Label


func set_player_controller(controller) -> void:
	_player_controller = controller


func set_model(model: Dictionary) -> void:
	_model = model
	_build_runtime_nodes()
	_apply_model()


func refresh_model(model: Dictionary) -> void:
	_model = model
	_build_runtime_nodes()
	_apply_model()


func set_compact(compact: bool) -> void:
	_compact = compact
	if _current_title != null:
		_current_title.add_theme_font_size_override("font_size", 20 if compact else 24)
	_apply_model()


func _regime_model() -> Dictionary:
	var political: Dictionary = _model.get("politics", _model)
	if political.has("regime") and political.get("regime") is Dictionary:
		return political.get("regime", {})
	return political


func _apply_model() -> void:
	if _options == null:
		return
	var regime := _regime_model()
	var current_name := String(regime.get("current_name", regime.get("name", "未定体制")))
	var current_detail := String(regime.get("current_detail", regime.get("detail", "")))
	var capabilities: Array = regime.get("current_capabilities", regime.get("capabilities", []))
	if _current_title != null:
		_current_title.text = current_name
	if _current_detail != null:
		_current_detail.text = current_detail
		_current_detail.visible = not current_detail.is_empty()
	if _current_capabilities != null:
		var capability_text := PackedStringArray()
		for raw in capabilities:
			if raw is Dictionary:
				var label := String(raw.get("label", raw.get("name", "")))
				if not label.is_empty():
					capability_text.append(label)
			else:
				var value := String(raw)
				if not value.is_empty():
					capability_text.append(value)
		_current_capabilities.text = "、".join(capability_text)
		_current_capabilities.visible = not capability_text.is_empty()
	if _status != null:
		_status.text = String(regime.get("status", ""))
		_status.visible = not _status.text.is_empty()
	_apply_options(regime)


func _apply_options(regime: Dictionary) -> void:
	var current_id := String(regime.get("current_id", regime.get("regime_id", "")))
	var pending_id := String(regime.get("pending_id", ""))
	var rows: Array = regime.get("options", regime.get("definitions", []))
	var signature_parts := PackedStringArray([current_id, pending_id])
	for raw in rows:
		if raw is Dictionary:
			signature_parts.append(String((raw as Dictionary).get("id", "")))
	var signature := "|".join(signature_parts)
	if signature != _option_signature:
		_option_signature = signature
		for child in _options.get_children():
			_options.remove_child(child)
			child.queue_free()
		_option_buttons.clear()
		for raw in rows:
			if not raw is Dictionary:
				continue
			var row: Dictionary = raw
			var regime_id := String(row.get("id", row.get("regime_id", "")))
			if regime_id.is_empty():
				continue
			var button := UIControlParts.button()
			button.custom_minimum_size.y = 54 if not _compact else 48
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.focus_mode = Control.FOCUS_ALL
			button.theme_type_variation = &"PKCountryNavButton"
			button.pressed.connect(_on_regime_pressed.bind(StringName(regime_id)))
			_options.add_child(button)
			_option_buttons[regime_id] = button
		if _option_buttons.is_empty():
			var note := UIControlParts.label()
			note.text = "体制目录尚未就绪。"
			note.theme_type_variation = &"PKWorkspaceLabel"
			_options.add_child(note)
	_first_action = null
	for raw in rows:
		if not raw is Dictionary:
			continue
		var row: Dictionary = raw
		var regime_id := String(row.get("id", row.get("regime_id", "")))
		if regime_id.is_empty():
			continue
		var button := _option_buttons.get(regime_id) as Button
		if button == null:
			continue
		var name := String(row.get("name", row.get("display_name", regime_id)))
		var detail := String(row.get("detail", ""))
		button.text = name if detail.is_empty() else "%s\n%s" % [name, detail]
		button.tooltip_text = detail
		button.disabled = regime_id == current_id or not bool(row.get("selectable", true)) \
			or not pending_id.is_empty()
		if regime_id == current_id:
			button.text += "（当前）"
		elif regime_id == pending_id:
			button.text += "（待生效）"
		if _first_action == null and not button.disabled:
			_first_action = button


func _on_regime_pressed(regime_id: StringName) -> void:
	regime_change_requested.emit(regime_id)
	if _player_controller != null and _player_controller.has_method("request_command"):
		_player_controller.request_command(&"politics.regime.set", {
			"regime_id": regime_id,
		})


func _focus_initial_action() -> void:
	if not is_visible_in_tree() or _first_action == null:
		return
	var owner := get_viewport().gui_get_focus_owner()
	if owner == null or not is_ancestor_of(owner):
		_first_action.grab_focus()
