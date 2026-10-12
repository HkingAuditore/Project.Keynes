class_name CountryAiCsvRecorder
extends RefCounted

## `country_ai_record` CSV family.  The native runtime appends one POD row per
## country think into a bounded ring at commit time; this recorder drains that
## ring on the main thread and streams it to disk.  It is debug-only state: it
## never feeds back into planning, hashes or saves.

const COLUMNS := [
	"day", "slot", "handle", "personality", "agenda", "cash", "cash_delta_ema",
	"reserve_days", "satisfaction_q16", "essentials_q16", "population", "territory",
	"frontier", "completed_milestones", "goal_milestone", "milestone_gap",
	"queued_techs", "research_budget", "tax_income_bp", "tax_consumption_bp",
	"tax_business_bp", "expeditions", "families", "colonize_started",
	"colonize_failures", "commands_emitted", "commands_rejected",
]

var _facade = null
var _file: FileAccess = null
var _path := ""
var _rows := 0
var _last_by_handle: Dictionary = {}


func start(facade, path: String) -> Dictionary:
	_facade = facade
	_rows = 0
	_last_by_handle.clear()
	if _facade == null or not _facade.is_configured():
		return {"ok": false, "reason": "country_ai_not_configured"}
	_path = ProjectSettings.globalize_path(path).simplify_path()
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file == null:
		return {"ok": false, "reason": "country_ai_csv_open_failed", "path": _path}
	# Drop rows produced before recording started so the file covers one window.
	_facade.drain_record_rows(65536)
	_file.store_line(",".join(COLUMNS))
	return {"ok": true, "path": _path}


func poll() -> int:
	if _file == null:
		return 0
	var drained := 0
	while true:
		var rows: Array = _facade.drain_record_rows(4096)
		for raw in rows:
			var row: Dictionary = raw
			var values := PackedStringArray()
			for column in COLUMNS:
				values.append(str(row.get(column, "")))
			_file.store_line(",".join(values))
			_last_by_handle[int(row.get("handle", 0))] = row
		drained += rows.size()
		if rows.size() < 4096:
			break
	_rows += drained
	return drained


## Flushes the remaining rows and returns {path, rows, last_by_handle}.
func finish() -> Dictionary:
	poll()
	if _file != null:
		_file.close()
		_file = null
	return {"path": _path, "rows": _rows, "last_by_handle": _last_by_handle.duplicate(true)}
