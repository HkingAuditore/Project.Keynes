class_name NarrativeEventFlow
extends RefCounted

## Modal presentation and clock-pause coordinator for the Narrative Event System.
## Modeled directly on AnnualReportFlow and FamilyFoundingDialog in PlayerController.

signal offer_changed(offer: Dictionary)
signal event_resolved(record: Dictionary)

var _controller = null
var _runtime_host = null
var _clock = null
var _ui_manager = null
var _service = null
var _ai_client = null

var _locked: bool = false
var _was_paused: bool = true
var _previous_speed: float = 1.0
var _active_offer_id: int = 0
var _active_offer_generation: int = 0
var _awaiting_outcome_ack: bool = false
var _restore_pending: bool = false
var _reopen_pending: bool = false
var _pending_image_request_offer_id: int = 0
var _popups_suppressed: bool = false

## [popup-deferral 2026-11-20] 玩家正泡在自己的窗口里（科技 / 经济(税收) / 军事 / 政治 /
## 外交国家卷宗，营造、家族档案、军务档案、派遣、议和、史册、GM 面板、时代纸笺）时，
## 事件不再抢窗口。以前 `show_narrative_event_offer` 直接 `close_country_panel()`，
## 这就是「每次有事件都强行打断」的根因。现在改成静置：先把时钟停下、响一声提示，
## 弹窗留到窗口关闭的那一刻（各关闭路径回调 try_present）。
##
## 提示音复用已烘焙的纸页揭示音：bank 与原生后端都没有专门的「待阅」音，新增事件要重烘焙
## bank 并补 native/events 的 ogg，不在本次范围。
const DEFERRAL_CUE := &"ideology_reveal"
## 兜底重试间隔：关闭路径少接一个入口就会变成「时钟停着、事件不弹」，
## 静置期间按这个节拍自查一次 active_offer。
const DEFERRAL_RETRY_SEC := 0.2

var _deferred: bool = false
var _deferred_offer_id: int = 0
var _deferred_retry_token: int = 0
var _deferred_retry_scheduled: bool = false

func set_popups_suppressed(value: bool) -> void:
	_popups_suppressed = value
	if value and _controller != null and _controller is Node and (_controller as Node).is_inside_tree():
		# 让当前事件也走自动选择/确认路径，避免开关切换后留下锁定的
		# 事件弹窗并继续持有暂停状态。
		(_controller as Node).call_deferred("sync_ui")


func configure(controller, runtime_host, clock, ui_manager, service, ai_client = null) -> void:
	_controller = controller
	_runtime_host = runtime_host
	_clock = clock
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
		if _service.has_signal("event_resolved"):
			var cb_resolved := Callable(self, "_on_service_event_resolved")
			if not _service.event_resolved.is_connected(cb_resolved):
				_service.event_resolved.connect(cb_resolved)

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


## 事件已就绪但玩家窗口还开着：时钟由本流程停下，弹窗等窗口关闭。
func is_deferred() -> bool:
	return _deferred


func _workspace_blocks_popup() -> bool:
	if _ui_manager == null or not _ui_manager.has_method("is_player_workspace_open"):
		return false
	return bool(_ui_manager.is_player_workspace_open())


## 静置：offer 留在服务的 active_offer 里（不再继续出队），时钟停下并响一声。
## 暂停快照只在「本流程第一次拿到暂停锁」时登记，避免覆盖读档/其他弹窗的现场。
func _hold_for_workspace(offer: Dictionary) -> void:
	var offer_id := int(offer.get("offer_id", 0))
	var newly_held := not _deferred or offer_id != _deferred_offer_id
	if not _deferred:
		_deferred = true
		if not _locked:
			_was_paused = bool(_clock.paused)
			_previous_speed = float(_clock.speed_multiplier)
			_restore_pending = true
	_deferred_offer_id = offer_id
	if newly_held:
		# 只在这个事件第一次被挡下时停表。玩家随后按空格继续读卷宗是他的选择，
		# 兜底重试每次再把表按回去等于让空格失灵。
		_hold_clock()
		_play_deferral_cue()
	_schedule_deferral_retry()


func _hold_clock() -> void:
	if _clock == null or bool(_clock.paused):
		return
	_clock.pause(true)
	if _controller != null and _controller.has_method("sync_ui"):
		# 与 _pause_clock 同理：暂停必须推给 worker 日历，否则画面停了年份还在走。
		_controller.call_deferred("sync_ui")


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
	if _controller != null:
		if _controller.has_method("era_reward_locked") and bool(_controller.era_reward_locked()):
			return true
		if _controller.has_method("family_founding_locked") and bool(_controller.family_founding_locked()):
			return true
		if _controller.has_method("ideology_draw_locked") and bool(_controller.ideology_draw_locked()):
			return true
		if _controller.has_method("ideology_draw_phase") and not String(_controller.ideology_draw_phase()).is_empty():
			return true
	if _ui_manager != null:
		if _ui_manager.has_method("is_annual_report_open") and bool(_ui_manager.is_annual_report_open()):
			return true
		if _ui_manager.has_method("is_era_ceremony_playing") and bool(_ui_manager.is_era_ceremony_playing()):
			return true
	return false


func _pause_clock() -> void:
	if _clock == null:
		return
	# [pause-loop-guard 2026-11-03] 以前这里每次都 sync_ui()。改成 call_deferred 之后，
	# 只要事件还挂着，就会变成"每帧 sync_ui → try_present → _pause_clock → 再 defer"
	# 的无限循环（真机表现为整个游戏卡死：心跳停、日期不动）。这里只在"本流程第一次
	# 把时钟停下"时刷一次 UI，已经处于暂停状态就直接返回。
	if bool(_clock.paused):
		return
	_clock.pause(true)
	if _controller != null and _controller.has_method("sync_ui"):
		_controller.call_deferred("sync_ui")


func _restore_clock() -> void:
	# 自动处理的事件没有取得暂停锁，不能恢复未捕获或上一事件的时钟状态。
	if not _restore_pending:
		return
	_restore_pending = false
	if _clock == null:
		return
	if _runtime_host != null and _runtime_host.has_method("is_runtime_fault_paused") \
			and bool(_runtime_host.is_runtime_fault_paused()):
		return
	_clock.set_speed(_previous_speed)
	_clock.pause(_was_paused)
	if _controller != null and _controller.has_method("sync_ui"):
		_controller.sync_ui()


func _resolve_active_offer() -> Dictionary:
	if _service == null:
		return {}
	var offer: Dictionary = {}
	if _service.has_method("active_offer"):
		var raw = _service.active_offer()
		if raw is Dictionary:
			offer = raw
	if offer.is_empty() or int(offer.get("offer_id", 0)) <= 0:
		if _service.has_method("promote_next_offer"):
			var promoted = _service.promote_next_offer()
			if promoted is Dictionary:
				offer = promoted
		elif _service.has_method("pop_next_ready_offer"):
			var popped = _service.pop_next_ready_offer()
			if popped is Dictionary:
				offer = popped
		elif _service.has_method("ready_queue"):
			var q = _service.ready_queue()
			if q is Array and not q.is_empty() and q[0] is Dictionary:
				offer = q[0]
	if offer.is_empty():
		return {}
	var status := String(offer.get("status", "OPEN"))
	if status != "OPEN" and status != "ACTIVE" and int(offer.get("offer_id", 0)) <= 0:
		return {}
	if int(offer.get("offer_id", 0)) <= 0 and String(offer.get("event_id", "")).is_empty():
		return {}
	return offer


## [narrative-reentry-guard 2026-11-03] 真机崩溃的根因就是这个环（带符号引擎 +
## 低 MAX_CALL_DEPTH 的诊断包打出的 GDScript backtrace 证据）：
##   player_controller.sync_ui → narrative_event_flow.try_present
##     → _pause_clock → controller.sync_ui → try_present → …（无限递归 → 栈溢出）
## 这里用重入闩切断：presenting 期间再次 try_present 直接返回；真正的二次请求会由
## 下一次 sync_ui/镜头事件重新触发，不会丢事件。
var _presenting := false


func try_present() -> void:
	if _presenting:
		return
	_presenting = true
	_try_present_impl()
	_presenting = false


func _try_present_impl() -> void:
	if _service == null or _clock == null:
		return
	# 屏蔽是运行时策略，不应只影响“显示”分支；必须在所有会锁时钟的
	# busy/outcome 检查之前拦截，覆盖开关切换时已经处于锁定中的事件。
	if _popups_suppressed:
		_clear_deferral()
		var suppressed_offer := _resolve_active_offer()
		if not suppressed_offer.is_empty():
			var options: Array = suppressed_offer.get("options", [])
			if not options.is_empty():
				on_option_chosen(int(suppressed_offer.get("offer_id", 0)),
					int(suppressed_offer.get("offer_generation", suppressed_offer.get("generation", 1))),
					clampi(int(suppressed_offer.get("default_option_index", 0)), 0, options.size() - 1))
				return
		if _locked or _reopen_pending:
			_locked = false
			_reopen_pending = false
			_active_offer_id = 0
			_active_offer_generation = 0
			_restore_pending = true
		if _restore_pending and not _busy():
			_restore_clock()
		return
	if _busy():
		if _locked and _ui_manager != null and _ui_manager.has_method("close_narrative_event_offer"):
			_ui_manager.close_narrative_event_offer()
		return
	if _awaiting_outcome_ack:
		if _locked and _ui_manager != null and _ui_manager.has_method("is_narrative_event_modal_open") \
				and not bool(_ui_manager.is_narrative_event_modal_open()):
			var current_offer := _resolve_active_offer()
			if not current_offer.is_empty() and _ui_manager.has_method("show_narrative_event_offer"):
				_ui_manager.show_narrative_event_offer(current_offer)
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
			_restore_pending = true
			_restore_clock()
			offer_changed.emit({})
		elif _restore_pending:
			_restore_clock()
		return
	# [popup-deferral 2026-11-20] 玩家正在读自己的窗口：不抢窗口，先静置。
	# 这里不改锁、不动 offer，窗口关闭后由各关闭路径回调 try_present 接上。
	if _workspace_blocks_popup():
		_hold_for_workspace(offer)
		return
	var was_deferred := _deferred
	if was_deferred:
		_clear_deferral()
	_reopen_pending = false
	var was_locked := _locked
	if not _locked:
		# 静置期间时钟是本流程停下的，快照才是玩家真正的现场；这里再取一次会把
		# 「暂停」当成玩家本来的状态，关掉弹窗后就再也跑不起来。
		if not was_deferred or not bool(_clock.paused):
			_was_paused = bool(_clock.paused)
			_previous_speed = float(_clock.speed_multiplier)
		_locked = true

	var offer_id := int(offer.get("offer_id", 1))
	var offer_gen := int(offer.get("offer_generation", offer.get("generation", 1)))
	var changed := (not was_locked) or (offer_id != _active_offer_id) or (offer_gen != _active_offer_generation)
	_active_offer_id = offer_id
	_active_offer_generation = offer_gen

	_pause_clock()

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
	var result: Dictionary = {}
	if _controller != null and _controller.has_method("request_command"):
		result = _controller.request_command(&"narrative.choose", {
			"offer_id": offer_id,
			"offer_generation": offer_generation,
			"option_index": option_index,
		})

	if (result.is_empty() or String(result.get("code", "")) == "unsupported_command") and _service != null:
		if _service.has_method("choose_option"):
			result = _service.choose_option(offer_id, offer_generation, option_index)
		elif _service.has_method("resolve_active_offer"):
			result = _service.resolve_active_offer(option_index)

	if not bool(result.get("ok", false)):
		var err_msg := String(result.get("message", result.get("reason", "操作未生效，请重试。")))
		if _ui_manager != null and _ui_manager.has_method("show_narrative_event_error"):
			_ui_manager.show_narrative_event_error(err_msg)
		return result

	var resolution: Dictionary = result.get("resolution", result)
	var record: Dictionary = result.get("record", resolution.get("record", {}))
	if not record.is_empty():
		event_resolved.emit(record)

	if _popups_suppressed:
		on_outcome_acknowledged()
	elif _ui_manager != null and _ui_manager.has_method("show_narrative_event_outcome"):
		_awaiting_outcome_ack = true
		_ui_manager.show_narrative_event_outcome(resolution)
	else:
		on_outcome_acknowledged()

	return result


func on_outcome_acknowledged() -> void:
	_awaiting_outcome_ack = false
	_pending_image_request_offer_id = 0
	_clear_deferral()
	if _ui_manager != null and _ui_manager.has_method("close_narrative_event_offer"):
		_ui_manager.close_narrative_event_offer()
	if _controller != null and _controller.has_method("clear_cell_highlights"):
		_controller.clear_cell_highlights()

	var next_offer := _resolve_active_offer()
	if not next_offer.is_empty() and int(next_offer.get("offer_id", 0)) != _active_offer_id:
		_active_offer_id = 0
		_active_offer_generation = 0
		if _controller != null and _controller is Node and (_controller as Node).is_inside_tree():
			call_deferred("try_present")
		else:
			try_present()
		return

	_restore_pending = _restore_pending or _locked or _reopen_pending
	_locked = false
	_reopen_pending = false
	_active_offer_id = 0
	_active_offer_generation = 0
	if not _busy():
		_restore_clock()
	offer_changed.emit({})

	if not _resolve_active_offer().is_empty():
		if _controller != null and _controller is Node and (_controller as Node).is_inside_tree():
			call_deferred("try_present")
		else:
			try_present()


func _on_service_offer_ready(_offer: Dictionary = {}) -> void:
	try_present()


func _on_service_offer_changed(_offer: Dictionary = {}) -> void:
	try_present()


func _on_service_event_resolved(record: Dictionary) -> void:
	event_resolved.emit(record)


func capture() -> Dictionary:
	return {
		"locked": _locked or _reopen_pending,
		"was_paused": _was_paused,
		"previous_speed": _previous_speed,
		"active_offer_id": _active_offer_id,
		"active_offer_generation": _active_offer_generation,
		"awaiting_outcome_ack": _awaiting_outcome_ack,
		"restore_pending": _restore_pending,
	}


func restore(state: Dictionary) -> void:
	_clear_deferral()
	_was_paused = bool(state.get("was_paused", true))
	_previous_speed = float(state.get("previous_speed", 1.0))
	_active_offer_id = int(state.get("active_offer_id", 0))
	_active_offer_generation = int(state.get("active_offer_generation", 0))
	_awaiting_outcome_ack = false
	_restore_pending = bool(state.get("restore_pending", false))
	_locked = false
	if bool(state.get("locked", false)):
		_reopen_pending = true
		if _clock != null:
			_clock.pause(true)
