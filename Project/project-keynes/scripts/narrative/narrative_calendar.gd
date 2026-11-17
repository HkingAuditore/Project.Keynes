extends RefCounted

static func _format_calendar_date(_world_clock, day: int) -> String:
	if _world_clock != null and _world_clock.has_method("calendar_date_for_day"):
		var cal: Dictionary = _world_clock.calendar_date_for_day(day)
		var year_no := 1
		if _world_clock.has_method("year_index_for_day"):
			year_no = int(_world_clock.year_index_for_day(day)) + 1
		return "第%d年 · %d月%d日" % [
			year_no, int(cal.get("month", 1)), int(cal.get("day_of_month", 1))]
	if _world_clock != null and _world_clock.has_method("calendar_date"):
		var cal_now: Dictionary = _world_clock.calendar_date()
		var year_now := int(_world_clock.year_index()) + 1 \
			if _world_clock.has_method("year_index") else 1
		return "第%d年 · %d月%d日" % [
			year_now, int(cal_now.get("month", 1)), int(cal_now.get("day_of_month", 1))]
	return "第 %d 日" % day
