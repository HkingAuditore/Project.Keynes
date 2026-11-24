extends RefCounted
class_name AnnualReportFlow

const ViewModel = preload("res://scripts/ui/annual_report_view_model.gd")
const ScribeScript = preload("res://scripts/annual/annual_chronicle_scribe.gd")
var _controller
var _host
var _ui
var _scribe = null
var _queued: int = 0
var _report_id: int = 0
var _open: bool = false
var _history_offset: int = 0
var _catalogs: Dictionary = {}
var _reopen_pending: bool = false
var _viewed: Array[int] = []
var _confirmation_error := ""
var _popups_suppressed: bool = false
func configure(controller, host, ui) -> void:
	_controller = controller
	_host = host
	_ui = ui
	if _host != null and _host.has_signal("annual_report_ready"):
		_host.annual_report_ready.connect(queue_report)
	if _ui != null and _ui.has_signal("annual_history_requested"):
		_ui.annual_history_requested.connect(request_history)
		_ui.annual_report_closed.connect(_on_closed)
		_ui.annual_report_selected.connect(_select_report)
		_ui.annual_history_page_requested.connect(_load_history)
	if _ui != null and _ui.has_signal("annual_report_workspace_available"):
		# Present after Godot finishes mounting or showing the workspace.
		_ui.annual_report_workspace_available.connect(try_present, CONNECT_DEFERRED)
	_ensure_scribe()


## 年度纪事需要一个能 add_child 的宿主，而 PlayerController 上已经挂着叙事用的
## NarrativeAiClient。复用它，不再建第二个客户端——凭据、endpoint 归一化、超时全在那一份里。
## 客户端由叙事运行时配置，可能晚于年报流程；所以每次用前再试一次，不在 configure 里一次定生死。
func _ensure_scribe() -> void:
	if _scribe != null:
		return
	if _controller == null or not (_controller is Node):
		return
	var client = null
	# 用 get() 而不是 `in`：属性不存在时两者都返回空，但 get() 不会因为
	# 属性名写错而在运行时抛「Invalid get index」之外的东西，读起来也更直白。
	client = _controller.get("_narrative_ai_client")
	if client == null:
		return
	var node = ScribeScript.new()
	node.name = "AnnualChronicleScribe"
	_controller.add_child(node)
	node.configure(client)
	_scribe = node

func is_open() -> bool:
	return _open

## GM「屏蔽弹窗」：清掉已排队/恢复中的年报，并立即确认待确认年报以解除后台停表栅栏。
func set_popups_suppressed(value: bool) -> void:
	_popups_suppressed = value
	if not value:
		return
	var pending_ids: Array[int] = _collect_pending_report_ids()
	_queued = 0
	_reopen_pending = false
	_viewed.clear()
	if _open:
		_open = false
		if _ui != null and _ui.has_method("is_annual_report_open") \
				and _ui.is_annual_report_open() and _ui.has_method("close_annual_report"):
			_ui.close_annual_report()
	_acknowledge_report_ids(pending_ids)


func _collect_pending_report_ids() -> Array[int]:
	var ids: Array[int] = []
	if _queued > 0:
		ids.append(_queued)
	for viewed_id in _viewed:
		if viewed_id > 0 and not ids.has(viewed_id):
			ids.append(viewed_id)
	if _host != null and _host.has_method("annual_report_status"):
		var ready_id: int = int(_host.annual_report_status().get("ready_report_id", 0))
		if ready_id > 0 and not ids.has(ready_id):
			ids.append(ready_id)
	return ids


func _acknowledge_report_ids(ids: Array[int]) -> void:
	if _host == null or not _host.has_method("mark_annual_report_presented"):
		return
	for id in ids:
		if id > 0:
			_host.mark_annual_report_presented(id)

func queue_report(id: int) -> void:
	if _popups_suppressed:
		if _host != null and _host.has_method("mark_annual_report_presented"):
			_host.mark_annual_report_presented(id)
		return
	# 纪事在「报告就绪」时预生成：从就绪到玩家开卷通常隔几秒以上，异步请求基本赶得上。
	# 赶不上的话本次不显示，下次开卷自然就有——历史报告也一样命中缓存。
	_prewarm_chronicle(id)
	_queued = id
	try_present()


func _prewarm_chronicle(id: int) -> void:
	_ensure_scribe()
	if _scribe == null or id <= 0 or _host == null:
		return
	if not _scribe.cached_text(id).is_empty():
		return
	if not _host.has_method("annual_report_snapshot") \
			or not _host.has_method("annual_report_catalogs"):
		return
	var report: Dictionary = _host.annual_report_snapshot(id)
	if not bool(report.get("ok", false)):
		return
	var previous: Dictionary = _host.annual_report_snapshot(id - 1) if id > 1 else {}
	_scribe.request(ViewModel.build(report, previous, _host.annual_report_catalogs()))

func _confirmation_reason() -> String:
	return String(_controller.player_confirmation_reason())


func try_present() -> void:
	if _popups_suppressed:
		if _confirmation_reason() == "annual_report_confirmation_required":
			_acknowledge_report_ids(_collect_pending_report_ids())
		return
	if _host == null or _ui == null or _open:
		return
	if _ui.has_method("can_open_annual_report") and not _ui.can_open_annual_report():
		return
	var reason := _confirmation_reason()
	if not reason.is_empty() and reason != "annual_report_confirmation_required":
		return
	if _reopen_pending:
		if not bool(_host.annual_report_status().get("ok", false)):
			return
		_show(_report_id, false)
	elif _queued > 0 and reason == "annual_report_confirmation_required":
		var id := _queued
		_queued = 0
		_show(id, true)


func request_history() -> void:
	if _host == null:
		return
	var reason := _confirmation_reason()
	if not reason.is_empty() and reason != "annual_report_confirmation_required":
		return
	var history: Dictionary = _host.annual_report_history(0, 64)
	var rows: Array = history.get("reports", [])
	var id: int = int(rows[0].get("id", 0)) if not rows.is_empty() else 0
	_show(id, false)


func _show(id: int, ceremonial: bool) -> void:
	_open = true
	_report_id = id
	_history_offset = 0
	_select_report(id, ceremonial)
	if _open:
		_load_history(0)


func _select_report(id: int, ceremonial: bool = false) -> void:
	_report_id = id
	var report: Dictionary = _host.annual_report_snapshot(id) if id > 0 else {}
	var previous: Dictionary = _host.annual_report_snapshot(id - 1) if id > 1 else {}
	# 目录里现在带「这一矿种认出来了没有」，而认矿会跨年发生 —— 缓存住就会在
	# 第一次开卷那一刻把资源栏永久钉死。这里不是热路径（开卷一次、换年一次），
	# 每次重取。
	_catalogs = _host.annual_report_catalogs()
	var model: Dictionary = ViewModel.build(report, previous, _catalogs)
	if not _confirmation_error.is_empty():
		model["confirmation_error"] = _confirmation_error
	# 纪事是末章，只加文字。没有缓存就不加，报告与今天完全一致。
	var chronicle := ""
	if _scribe != null:
		chronicle = _scribe.cached_text(id)
	if not chronicle.is_empty():
		ViewModel.append_chronicle_chapter(model, chronicle)
	_ui.show_annual_report(model, ceremonial)
	if _ui.has_method("is_annual_report_open") and not bool(_ui.is_annual_report_open()):
		push_error("[annual] report workspace failed to open for id=%d" % id)
		_open = false
		_reopen_pending = true
		return
	_reopen_pending = false
	if bool(report.get("ok", false)) and not _viewed.has(id):
		_viewed.append(id)


func _load_history(offset: int) -> void:
	_history_offset = maxi(0, offset)
	var history: Dictionary = _host.annual_report_history(_history_offset, 64)
	var rows: Array = history.get("reports", [])
	_ui.set_annual_history(rows, _history_offset, rows.size() == 64)

func _on_closed(_id: int) -> void:
	if not _open:
		return
	_open = false
	# Closing after browsing history also acknowledges the annual report the
	# player actually opened first, rather than reopening it immediately.
	var unconfirmed: Array[int] = []
	_confirmation_error = ""
	for viewed_id in _viewed:
		var receipt: Dictionary = _host.mark_annual_report_presented(viewed_id)
		if bool(receipt.get("admitted", false)):
			if viewed_id == _queued:
				_queued = 0
		else:
			unconfirmed.append(viewed_id)
			_confirmation_error = {
				"annual_report_reward_pending": "年报奖励尚未结算，暂时无法确认。",
				"annual_report_not_found": "这份年报尚未准备好。",
			}.get(receipt.get("code", ""), "年报暂时无法确认。")
	_viewed = unconfirmed
	if not unconfirmed.is_empty():
		_report_id = unconfirmed[0]
		_reopen_pending = true


func capture() -> Dictionary:
	return {"open": _open or _reopen_pending, "report_id": _report_id,
		"viewed": _viewed.duplicate()}


func restore(state: Dictionary) -> void:
	_confirmation_error = ""
	_report_id = int(state.get("report_id", 0))
	_viewed.clear()
	for id in state.get("viewed", []):
		_viewed.append(int(id))
	_reopen_pending = bool(state.get("open", false))
