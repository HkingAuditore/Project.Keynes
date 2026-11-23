extends RefCounted

const MAIN_STEP_HISTORY_DAYS := 64

var _main_steps_by_day: Dictionary = {}
var _latest_main_step_day := -1
var _main_steps_map_id := 0

func record(map: MapData, day: int, step: StringName) -> void:
	_sync_world(map)
	if day < 0 or day <= _latest_main_step_day - MAIN_STEP_HISTORY_DAYS:
		return
	if day > _latest_main_step_day:
		var first_expired := maxi(0, _latest_main_step_day - MAIN_STEP_HISTORY_DAYS + 1)
		var last_expired := day - MAIN_STEP_HISTORY_DAYS
		if last_expired - first_expired >= MAIN_STEP_HISTORY_DAYS:
			_main_steps_by_day.clear()
		else:
			for expired_day in range(first_expired, last_expired + 1):
				_main_steps_by_day.erase(expired_day)
		_latest_main_step_day = day
	var counts: Dictionary = _main_steps_by_day.get_or_add(day, {})
	counts[step] = int(counts.get(step, 0)) + 1


func _sync_world(map: MapData) -> void:
	var map_id := map.get_instance_id() if map != null else 0
	if map_id != _main_steps_map_id:
		_main_steps_map_id = map_id
		_main_steps_by_day.clear()
		_latest_main_step_day = -1


func snapshot(map: MapData) -> Dictionary:
	_sync_world(map)
	return _main_steps_by_day.duplicate(true)
