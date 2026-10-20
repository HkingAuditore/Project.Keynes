extends RefCounted
class_name AnnualReportSession

## Read-only session bridge. All totals, reports and rewards live in C++.
signal report_ready(report_id: int)

const ProfileScript = preload("res://scripts/annual/annual_report_profile.gd")
var _ext: Object
var _clock: WorldClock
var _sync_day: int = -1
var _last_announced: int = 0
var _boundary_day: int = -1
var _configured: bool = false
var _generator
var _boundary_input_sent: bool = false

func configure(generator, clock: WorldClock, handle: int) -> Dictionary:
	_generator = generator
	_clock = clock
	_ext = generator.get_data_core_world_ext() if generator != null else null
	if _ext == null or not _ext.has_method("configure_annual_reports") or handle == 0:
		return {"ok": false, "reason": "annual_api_unavailable"}
	var profile = load("res://data/annual/default_annual_report.tres")
	var country: Dictionary = generator.get_country_facade().native_catalog()
	var ideology: Dictionary = generator.get_ideology_facade().native_catalog()
	var compiled: Dictionary = profile.compile_native(country, ideology)
	var result: Dictionary = _ext.configure_annual_reports(handle, clock.days_per_year(),
		clock.day_index(), compiled)
	_configured = bool(result.get("ok", false))
	return result

func before_day(day: int) -> void:
	if not _configured:
		return
	_sync_day = day
	if not bool(status().get("worker_managed", false)):
		_clock.request_simulation_backpressure(&"annual_report_commit_barrier", true)
	if day > 0 and day % _clock.days_per_year() == 0:
		_boundary_day = day
		_boundary_input_sent = false
		_clock.request_simulation_backpressure(&"annual_report_day_barrier", true)

func poll() -> void:
	if not _configured:
		return
	if _sync_day >= 0:
		_ext.commit_annual_reports(_sync_day)
	var state: Dictionary = _ext.get_annual_report_status()
	if not bool(state.get("ok", false)):
		return
	if int(state.get("last_day", -1)) >= _sync_day:
		_clock.request_simulation_backpressure(&"annual_report_commit_barrier", false)
	# The ordinary driver freezes day - 1. At the year fence, explicitly
	# supply the first new-year input after the old year is sealed so its
	# already-fixed reward can commit without advancing the visible calendar.
	if _boundary_day >= 0 and bool(state.get("worker_managed", false)) \
			and int(state.get("last_day", -1)) >= _boundary_day - 1 \
			and int(state.get("last_day", -1)) < _boundary_day and not _boundary_input_sent:
		var captured: Dictionary = _generator.capture_runtime_inputs_for_worker(
			_boundary_day, _clock.season_phase_for_day(_boundary_day))
		_boundary_input_sent = bool(captured.get("ok", false))
	if _boundary_day >= 0 and int(state.get("last_day", -1)) >= _boundary_day \
			and not bool(state.get("reward_pending", false)):
		_clock.request_simulation_backpressure(&"annual_report_day_barrier", false)
		_boundary_day = -1
	var report_id: int = int(state.get("ready_report_id", 0))
	if _boundary_day < 0 and report_id > 0 and report_id != _last_announced \
			and _clock.day_index() >= report_id * _clock.days_per_year():
		_last_announced = report_id
		report_ready.emit(report_id)

func waiting_for_year(year: int) -> bool:
	if not _configured:
		return false
	var state: Dictionary = _ext.get_annual_report_status()
	return int(state.get("last_day", -1)) < year * _clock.days_per_year() \
		or bool(state.get("reward_pending", false))

func status() -> Dictionary:
	return _ext.get_annual_report_status() if _configured else {"ok": false}

func snapshot(report_id: int) -> Dictionary:
	return _ext.get_annual_report_snapshot(report_id) if _configured else {"ok": false}

func history(offset: int = 0, limit: int = 64) -> Dictionary:
	return _ext.get_annual_report_history(offset, limit) if _configured else {"ok": false, "reports": []}

func mark_presented(report_id: int) -> void:
	if _configured:
		_ext.mark_annual_report_presented(report_id)
		_last_announced = 0
