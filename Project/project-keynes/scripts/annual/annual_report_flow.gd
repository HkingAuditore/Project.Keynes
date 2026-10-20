extends RefCounted
class_name AnnualReportFlow

const ViewModel = preload("res://scripts/ui/annual_report_view_model.gd")
var _controller
var _host
var _clock
var _ui
var _queued: int = 0
var _report_id: int = 0
var _open: bool = false
var _was_paused: bool = true
var _speed: float = 1.0
var _restore_pending: bool = false
var _history_offset: int = 0
var _catalogs: Dictionary = {}
var _reopen_pending: bool = false
var _viewed: Array[int] = []

func configure(controller, host, clock, ui) -> void:
	_controller = controller
	_host = host
	_clock = clock
	_ui = ui
	if _host != null and _host.has_signal("annual_report_ready"):
		_host.annual_report_ready.connect(queue_report)
	if _ui != null and _ui.has_signal("annual_history_requested"):
		_ui.annual_history_requested.connect(request_history)
		_ui.annual_report_closed.connect(_on_closed)
		_ui.annual_report_selected.connect(_select_report)
		_ui.annual_history_page_requested.connect(_load_history)

func is_open() -> bool:
	return _open

func queue_report(id: int) -> void:
	_queued = id
	try_present()

func _busy() -> bool:
	return _controller.era_reward_locked() or _controller.family_founding_locked() \
		or not String(_controller.ideology_draw_phase()).is_empty() \
		or (_ui != null and _ui.has_method("annual_other_modal_open") and _ui.annual_other_modal_open())

## 暂停时钟，并且**把暂停推出去**。
##
## `WorldClock.paused` 只关掉主线程那一台日历。worker 权威下日历跑在原生线程里，
## 它只听 `set_runtime_clock_threaded`，而那条线的唯一上游是
## `PlayerController.sync_ui()` → `WorldRuntimeHost.on_clock_running_changed`。
## 别的暂停入口（暂停键、暂停菜单、调速）都顺路调了 sync_ui，只有这里原本
## 只改了标志位 —— 于是年鉴摊开了、画面静止了，年份还在背后往前走。
func _pause_clock() -> void:
	_clock.pause(true)
	if _controller != null and _controller.has_method("sync_ui"):
		# 重入是安全的：此时 _open 已经是 true，sync_ui 里那次 try_present 会立刻返回。
		_controller.sync_ui()

func try_present() -> void:
	if _host == null or not _host.has_method("annual_report_status") or _clock == null or _ui == null:
		return
	if _open or _busy():
		return
	if _reopen_pending:
		if not bool(_host.annual_report_status().get("ok", false)):
			return
		_reopen_pending = false
		_open = true
		_pause_clock()
		_select_report(_report_id)
		_load_history(0)
		return
	if _restore_pending:
		_restore_clock()
	if _queued > 0:
		var id: int = _queued
		_queued = 0
		_show(id, true)

func request_history() -> void:
	if _host == null or not _host.has_method("annual_report_history") or _busy():
		return
	var history: Dictionary = _host.annual_report_history(0, 64)
	var rows: Array = history.get("reports", [])
	var id: int = int(rows[0].get("id", 0)) if not rows.is_empty() else 0
	_show(id, false)

func _show(id: int, ceremonial: bool) -> void:
	if not _open:
		_was_paused = _clock.paused
		_speed = _clock.speed_multiplier
		_open = true
	_pause_clock()
	_report_id = id
	_history_offset = 0
	_select_report(id, ceremonial)
	_load_history(0)

func _select_report(id: int, ceremonial: bool = false) -> void:
	_report_id = id
	var report: Dictionary = _host.annual_report_snapshot(id) if id > 0 else {}
	var previous: Dictionary = _host.annual_report_snapshot(id - 1) if id > 1 else {}
	if bool(report.get("ok", false)) and not _viewed.has(id):
		_viewed.append(id)
	# 目录里现在带「这一矿种认出来了没有」，而认矿会跨年发生 —— 缓存住就会在
	# 第一次开卷那一刻把资源栏永久钉死。这里不是热路径（开卷一次、换年一次），
	# 每次重取。
	_catalogs = _host.annual_report_catalogs()
	_ui.show_annual_report(ViewModel.build(report, previous, _catalogs), ceremonial)

func _load_history(offset: int) -> void:
	_history_offset = maxi(0, offset)
	var history: Dictionary = _host.annual_report_history(_history_offset, 64)
	var rows: Array = history.get("reports", [])
	_ui.set_annual_history(rows, _history_offset, rows.size() == 64)

func _on_closed(id: int) -> void:
	if not _open:
		return
	_open = false
	# Closing after browsing history also acknowledges the annual report the
	# player actually opened first, rather than reopening it immediately.
	if _viewed.has(_queued):
		_queued = 0
	for viewed_id in _viewed:
		_host.mark_annual_report_presented(viewed_id)
	_viewed.clear()
	_restore_pending = true
	if not _busy():
		_restore_clock()

func _restore_clock() -> void:
	_restore_pending = false
	if _host.has_method("is_runtime_fault_paused") and _host.is_runtime_fault_paused():
		return
	_clock.set_speed(_speed)
	_clock.pause(_was_paused)
	_controller.sync_ui()

func capture() -> Dictionary:
	return {"open": _open or _reopen_pending, "report_id": _report_id, "queued": _queued,
		"was_paused": _was_paused, "speed": _speed, "restore_pending": _restore_pending,
		"viewed": _viewed.duplicate()}

func restore(state: Dictionary) -> void:
	_queued = int(state.get("queued", 0))
	_report_id = int(state.get("report_id", 0))
	_was_paused = bool(state.get("was_paused", true))
	_speed = float(state.get("speed", 1.0))
	_restore_pending = bool(state.get("restore_pending", false))
	_viewed.clear()
	for id in state.get("viewed", []):
		_viewed.append(int(id))
	if bool(state.get("open", false)):
		# Native providers restore before the session configures its read facade.
		# Reopen only when that facade and the other modal locks are ready.
		_reopen_pending = true
		_clock.pause(true)
