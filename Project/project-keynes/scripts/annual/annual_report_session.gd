extends RefCounted
class_name AnnualReportSession

## Read-only session bridge. All totals, reports and rewards live in C++.
signal report_ready(report_id: int)

const ProfileScript = preload("res://scripts/annual/annual_report_profile.gd")
var _ext: Object
var _clock: WorldClock
var _last_announced: int = 0
var _configured: bool = false

func configure(generator, clock: WorldClock, handle: int) -> Dictionary:
	_configured = false
	_clock = clock
	_ext = generator.get_data_core_world_ext() if generator != null else null
	if _ext == null or handle == 0:
		return {"ok": false, "reason": "annual_api_unavailable"}
	# Economy/Country setup can fail before the simulation module is prepared.  In
	# that case the facades are intentionally left null; report configuration must
	# preserve the original setup error instead of turning it into a Nil call.
	var country_facade = generator.get_country_facade() if generator.has_method("get_country_facade") else null
	if country_facade == null or not country_facade.has_method("native_catalog"):
		return {"ok": false, "reason": "annual_country_catalog_unavailable"}
	var ideology_facade = generator.get_ideology_facade() if generator.has_method("get_ideology_facade") else null
	if ideology_facade == null or not ideology_facade.has_method("native_catalog"):
		return {"ok": false, "reason": "annual_ideology_catalog_unavailable"}
	var profile = load("res://data/annual/default_annual_report.tres")
	var country: Dictionary = country_facade.native_catalog()
	var ideology: Dictionary = ideology_facade.native_catalog()
	var compiled: Dictionary = profile.compile_native(country, ideology)
	var result: Dictionary = _ext.configure_annual_reports(handle, clock.days_per_year(),
		clock.day_index(), compiled)
	_configured = bool(result.get("ok", false))
	return result

func poll() -> void:
	if not _configured:
		return
	var state: Dictionary = _ext.get_annual_report_status()
	if not bool(state.get("ok", false)):
		return
	var report_id: int = int(state.get("ready_report_id", 0))
	if report_id > 0 and report_id != _last_announced:
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

func mark_presented(report_id: int) -> Dictionary:
	if not _configured:
		return {"ok": false, "admitted": false, "code": "annual_unconfigured", "report_id": report_id}
	return _ext.mark_annual_report_presented(report_id)
