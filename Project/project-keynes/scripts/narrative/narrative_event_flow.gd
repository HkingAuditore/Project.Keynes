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
## GM「屏蔽弹窗」：切换后所有待展示事件走默认选项自动确认，不留锁着时钟的弹窗。
var _popups_suppressed: bool = false

## [popup-deferral 2026-11-20] 玩家正泡在自己的窗口里（科技 / 经济(税收) / 军事 / 政治 /
## 外交国家卷宗，营造、家族档案、军务档案、派遣、议和、史册、GM 面板、时代纸笺）时，
## 事件不再抢窗口。以前 show_narrative_event_offer 直接关掉国家面板，这就是
## 「每次有事件都强行打断」的根因；现在改成静置：弹窗留到窗口关闭的那一刻
## （各关闭路径回调 try_present / recheck_narrative_popup）。
##
## 提示音复用已烘焙的纸页揭示音：bank 与原生后端都没有专门的「待阅」音。
## 停表由原生 event_pause_mask 负责（本代流程不再自己 pause/restore 时钟）。
const DEFERRAL_CUE := &"ideology_reveal"
## 兜底重试间隔：关闭路径少接一个入口就会变成「事件一直不弹」，
## 静置期间按这个节拍自查一次 active_offer。
const DEFERRAL_RETRY_SEC := 0.2

var _deferred: bool = false
var _deferred_offer_id: int = 0
var _deferred_retry_token: int = 0
var _deferred_retry_scheduled: bool = false


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


func set_popups_suppressed(value: bool) -> void:
	_popups_suppressed = value
	if value and _controller != null and _controller is Node and (_controller as Node).is_inside_tree():
		# 让当前事件也走自动选择/确认路径，避免开关切换后留下锁定的
		# 事件弹窗并继续持有暂停状态。
		(_controller as Node).call_deferred("sync_ui")


func is_locked() -> bool:
	return _locked


func is_open() -> bool:
	return _locked


## 事件已就绪但玩家窗口还开着：弹窗等窗口关闭后再展示。
func is_deferred() -> bool:
	return _deferred


func _workspace_blocks_popup() -> bool:
	if _ui_manager == null or not _ui_manager.has_method("is_player_workspace_open"):
		return false
	return bool(_ui_manager.is_player_workspace_open())


## 静置：offer 留在服务的 active_offer 里（不再继续出队），只在第一次挡下时响一声。
func _hold_for_workspace(offer: Dictionary) -> void:
	var offer_id := int(offer.get("offer_id", 0))
	var newly_held := not _deferred or offer_id != _deferred_offer_id
	_deferred = true
	_deferred_offer_id = offer_id
	if newly_held:
		_play_deferral_cue()
	_schedule_deferral_retry()


func _clear_deferral() -> void:
	if not _deferred and _deferred_offer_id == 0:
		return
	_deferred = false
	_deferred_offer_id = 0
	# 抬高令牌让在途重试自行退出。
	_deferred_retry_token += 1
	_deferred_retry_scheduled = false


func _play_deferral_cue() -> void:
	if _controller == null or not (_controller is Node):
		return
	var audio := (_controller as Node).get_node_or_null("/root/GameAudio")
	if audio != null and audio.has_method("play_event_cue"):
		audio.play_event_cue(DEFERRAL_CUE)


func _schedule_deferral_retry() -> void:
	if _deferred_retry_scheduled:
		return
	if _controller == null or not (_controller is Node) \
			or not (_controller as Node).is_inside_tree():
		return
	var tree := (_controller as Node).get_tree()
	if tree == null:
		return
	_deferred_retry_scheduled = true
	_deferred_retry_token += 1
	var token := _deferred_retry_token
	tree.create_timer(DEFERRAL_RETRY_SEC).timeout.connect(func() -> void:
		if token != _deferred_retry_token:
			return
		_deferred_retry_scheduled = false
		if not _deferred:
			return
		try_present()
		if _deferred:
			_schedule_deferral_retry()
	)


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
	if _popups_suppressed:
		_clear_deferral()
		_outcome_record = {}
		var suppressed_offer := _resolve_active_offer()
		if not suppressed_offer.is_empty():
			var options: Array = suppressed_offer.get("options", [])
			if not options.is_empty():
				on_option_chosen(int(suppressed_offer.get("offer_id", 0)),
					int(suppressed_offer.get("offer_generation",
						suppressed_offer.get("generation", 1))),
					clampi(int(suppressed_offer.get("default_option_index", 0)), 0, options.size() - 1))
				return
		if _ui_manager != null and _ui_manager.has_method("close_narrative_event_offer"):
			_ui_manager.close_narrative_event_offer()
		if _locked:
			_locked = false
			_active_offer_id = 0
			_active_offer_generation = 0
			offer_changed.emit({})
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
		_clear_deferral()
		if _locked:
			if _ui_manager != null and _ui_manager.has_method("close_narrative_event_offer"):
				_ui_manager.close_narrative_event_offer()
			_locked = false
			_active_offer_id = 0
			_active_offer_generation = 0
			offer_changed.emit({})
		return
	# [popup-deferral 2026-11-20] 玩家正在读自己的窗口：不抢窗口，先静置。
	# 这里不改锁、不动 offer，窗口关闭后由各关闭路径回调 try_present 接上。
	if _workspace_blocks_popup():
		_hold_for_workspace(offer)
		return
	if _deferred:
		_clear_deferral()
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
	_clear_deferral()
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
	if _popups_suppressed:
		on_outcome_acknowledged()
		return
	if _ui_manager != null and _ui_manager.has_method("show_narrative_event_outcome"):
		_outcome_record = record
		try_present()
	else:
		on_outcome_acknowledged()


func capture() -> Dictionary:
	return {"settling_offer": _settling_offer_id}


func restore(state: Dictionary) -> void:
	_clear_deferral()
	_locked = false
	_outcome_record = {}
	_active_offer_id = 0
	_active_offer_generation = 0
	_settling_offer_id = int(state.get("settling_offer", 0))
