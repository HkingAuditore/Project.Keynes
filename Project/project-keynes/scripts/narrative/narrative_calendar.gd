extends RefCounted

## 事件弹窗与史册的日期文本。日历换算的唯一实现在 WorldClock，这里只负责
## 从时钟取年长；没有时钟的测试/诊断路径按默认年长换算，不再退回「第 N 日」。
static func _format_calendar_date(_world_clock, day: int) -> String:
	if _world_clock != null and _world_clock.has_method("days_per_year"):
		return WorldClock.date_text_for_day(day, int(_world_clock.days_per_year()))
	return WorldClock.date_text_for_day(day)
