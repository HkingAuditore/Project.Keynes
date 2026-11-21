class_name NarrativeEventFlow
extends RefCounted

## Presents the executor's published offer and committed outcome.

signal offer_changed(offer: Dictionary)
signal event_resolved(record: Dictionary)

var _controller = null
var _ui_manager = null
var _service = null
var _ai_client = null

var _locked: bool = false
var _active_offer_id: int = 0
var _active_offer_generation: int = 0
var _outcome_record: Dictionary = {}
var _pending_image_request_offer_id: int = 0
var _settling_offer_id: int = 0


func configure(controller, _runtime_host, _clock, ui_manager, service, ai_client = null) -> void:
	_controller = controller
	_ui_manager = ui_manager
	_service = service
	_ai_client = ai_client

	if _service != null:
		if _service.has_signal("offer_ready"):
			var cb_ready := Callable(self, "_on_service_offer_ready")
			if not _service.offer_ready.is_connected(cb_ready):
				_service.offer_ready.connect(cb_ready)
		if _service.has_signal("offer_changed"):
			var cb_changed := Callable(self, "_on_service_offer_changed")
			if not _service.offer_changed.is_connected(cb_changed):
				_service.offer_changed.connect(cb_changed)
		if _service.has_signal("choice_resolved"):
			var cb_resolved := Callable(self, "_on_service_choice_resolved")
			if not _service.choice_resolved.is_connected(cb_resolved):
				_service.choice_resolved.connect(cb_resolved)

	if _ui_manager != null:
		if _ui_manager.has_signal("narrative_event_option_selected"):
			var cb_opt := Callable(self, "on_option_chosen")
			if not _ui_manager.narrative_event_option_selected.is_connected(cb_opt):
				_ui_manager.narrative_event_option_selected.connect(cb_opt)
		if _ui_manager.has_signal("narrative_event_outcome_acknowledged"):
			var cb_ack := Callable(self, "on_outcome_acknowledged")
			if not _ui_manager.narrative_event_outcome_acknowledged.is_connected(cb_ack):
				_ui_manager.narrative_event_outcome_acknowledged.connect(cb_ack)


func set_service(service) -> void:
	_service = service


func set_ai_client(ai_client) -> void:
	_ai_client = ai_client


func is_locked() -> bool:
	return _locked


func is_open() -> bool:
	return _locked


func _busy() -> bool:
	if _controller != null and _controller.has_method("player_confirmation_reason"):
		var reason := String(_controller.player_confirmation_reason())
		if not reason.is_empty() and reason != "narrative_choice_required":
			return true
	return _ui_manager != null and _ui_manager.has_method("is_era_ceremony_playing") \
		and bool(_ui_manager.is_era_ceremony_playing())


func _resolve_active_offer() -> Dictionary:
	if _service == null:
		return {}
	var offer: Dictionary = {}
	if _service.has_method("active_offer"):
		var raw = _service.active_offer()
		if raw is Dictionary:
			offer = raw
	if offer.is_empty():
		return {}
	var status := String(offer.get("status", "OPEN"))
	if status != "OPEN" and status != "ACTIVE" and int(offer.get("offer_id", 0)) <= 0:
		return {}
	if int(offer.get("offer_id", 0)) <= 0 and String(offer.get("event_id", "")).is_empty():
		return {}
	return offer


var _presenting := false
var _choosing := false


func try_present() -> void:
	if _presenting or _choosing:
		return
	_presenting = true
	_try_present_impl()
	_presenting = false


func _try_present_impl() -> void:
	if _service == null or _settling_offer_id != 0:
		return
	if _busy():
		if _locked and _ui_manager != null and _ui_manager.has_method("close_narrative_event_offer"):
			_ui_manager.close_narrative_event_offer()
		return
	if not _outcome_record.is_empty():
		if not _locked or not _ui_manager.is_narrative_event_modal_open():
			_locked = true
			_ui_manager.show_narrative_event_outcome({"record": _outcome_record})
		return

	var offer := _resolve_active_offer()
	if offer.is_empty():
		if _locked:
			if _ui_manager != null and _ui_manager.has_method("close_narrative_event_offer"):
				_ui_manager.close_narrative_event_offer()
			_locked = false
			_active_offer_id = 0
			_active_offer_generation = 0
			offer_changed.emit({})
		return
	var was_locked := _locked
	_locked = true

	var offer_id := int(offer.get("offer_id", 1))
	var offer_gen := int(offer.get("offer_generation", offer.get("generation", 1)))
	var changed := (not was_locked) or (offer_id != _active_offer_id) or (offer_gen != _active_offer_generation)
	_active_offer_id = offer_id
	_active_offer_generation = offer_gen

	var cell_idx := int(offer.get("cell_idx", offer.get("cell", -1)))
	if cell_idx >= 0 and _controller != null:
		if changed:
			if _controller.has_method("focus_family_founding_cell"):
				_controller.focus_family_founding_cell(cell_idx)
			elif _controller.has_method("highlight_cells"):
				_controller.highlight_cells(PackedInt32Array([cell_idx]))

	var modal_open := false
	if _ui_manager != null and _ui_manager.has_method("is_narrative_event_modal_open"):
		modal_open = bool(_ui_manager.is_narrative_event_modal_open())

	if _ui_manager != null and _ui_manager.has_method("show_narrative_event_offer"):
		if changed or not modal_open:
			_ui_manager.show_narrative_event_offer(offer)
			_maybe_request_ai_illustration(offer)

	if changed:
		offer_changed.emit(offer)


func _maybe_request_ai_illustration(offer: Dictionary) -> void:
	if _ai_client == null or _ui_manager == null:
		return
	var offer_id := int(offer.get("offer_id", 0))
	if offer_id <= 0 or offer_id == _pending_image_request_offer_id:
		return
	var image_path := String(offer.get("image_path", "")).strip_edges()
	if not image_path.is_empty() and (ResourceLoader.exists(image_path) or FileAccess.file_exists(image_path)):
		return
	var visual_prompt := String(offer.get("ai_visual_prompt", "")).strip_edges()
	var event_id := String(offer.get("event_id", "")).strip_edges()
	if visual_prompt.is_empty():
		return
	if _ai_client.has_method("request_event_illustration"):
		_pending_image_request_offer_id = offer_id
		_ai_client.request_event_illustration(event_id, visual_prompt, func(result: Dictionary) -> void:
			if int(_active_offer_id) != offer_id or not _locked:
				return
			var tex: Texture2D = result.get("texture", null) as Texture2D
			if tex != null and _ui_manager != null and _ui_manager.has_method("set_narrative_event_illustration"):
				_ui_manager.set_narrative_event_illustration(tex)
		)


func on_option_chosen(offer_id: int, offer_generation: int, option_index: int) -> Dictionary:
	_choosing = true
	var result: Dictionary = {}
	if _controller != null and _controller.has_method("request_command"):
		result = _controller.request_command(&"narrative.choose", {
			"offer_id": offer_id,
			"offer_generation": offer_generation,
			"option_index": option_index,
		})

	_choosing = false
	if not bool(result.get("ok", false)):
		var err_msg := String(result.get("message", result.get("reason", "操作未生效，请重试。")))
		if _ui_manager != null and _ui_manager.has_method("show_narrative_event_error"):
			_ui_manager.show_narrative_event_error(err_msg)
		return result

	_settling_offer_id = offer_id
	_locked = false
	if _ui_manager != null and _ui_manager.has_method("close_narrative_event_offer"):
		_ui_manager.close_narrative_event_offer()
	return result


func on_outcome_acknowledged() -> void:
	_outcome_record = {}
	_pending_image_request_offer_id = 0
	if _ui_manager != null and _ui_manager.has_method("close_narrative_event_offer"):
		_ui_manager.close_narrative_event_offer()
	if _controller != null and _controller.has_method("clear_cell_highlights"):
		_controller.clear_cell_highlights()

	_locked = false
	_active_offer_id = 0
	_active_offer_generation = 0
	offer_changed.emit({})
	try_present()


func _on_service_offer_ready(_offer: Dictionary = {}) -> void:
	try_present()


func _on_service_offer_changed(_offer: Dictionary = {}) -> void:
	try_present()


func _on_service_choice_resolved(record: Dictionary) -> void:
	event_resolved.emit(record)
	if _settling_offer_id == 0 or _settling_offer_id != int(record.get("offer_id", 0)):
		return
	_settling_offer_id = 0
	if _ui_manager != null and _ui_manager.has_method("show_narrative_event_outcome"):
		_outcome_record = record
		try_present()
	else:
		on_outcome_acknowledged()


func capture() -> Dictionary:
	return {"settling_offer": _settling_offer_id}


func restore(state: Dictionary) -> void:
	_locked = false
	_outcome_record = {}
	_active_offer_id = 0
	_active_offer_generation = 0
	_settling_offer_id = int(state.get("settling_offer", 0))
