extends RefCounted
class_name DCDiagnosticsBus

## Phase E.6 / dots-full-migration §E.6：MapGenerator 内 _last_*_breakdown 等
## 性能埋点字段集中存放。
##
## **当前状态**：完整 API + storage 已就位；调用方（map_generator / 各 sub-pass /
## main.gd fast tick WARN 详细打印）后续 PR 按下方"接入清单"逐处改为 `bus.*`。
##
## ─── 待迁移字段清单（从 map_generator.gd 搬过来）──────────────────────
##
## 各 sub-pass 耗时拆解（climate / weather / ocean / sea_ice / transp）：
##   - `_last_climate_breakdown: Dictionary`     ← climate 6 sub-pass 各段 ms
##   - `_last_weather_breakdown: Dictionary`     ← weather solve / spawn / dist 各段 ms
##   - `_last_climate_dirty_ratio: float`        ← sparse climate dirty 占比
##   - `_last_climate_visited_ratio: float`      ← sparse 实际遍历占比
##   - `_last_climate_pass_b_path: String`       ← full / sparse path 标记
##
## 累计计数：
##   - `_daily_climate_call_count: int`          ← climate 调用次数
##   - `_daily_weather_call_count: int`          ← weather 调用次数（如有）
##
## ─── 接入清单（后续 PR 按此清单替换调用）───────────────────────────
##
## 写入路径（map_generator / job 内部）：
##   - `generator._last_climate_breakdown = {...}` → `bus.record_climate_breakdown({...})`
##   - `generator._daily_climate_call_count += 1` → `bus.increment_climate_call_count()`
##   - 同理 weather / ocean
##
## 读取路径（main.gd fast tick WARN / SUS 日志）：
##   - `generator.sus_climate_breakdown()` → `bus.get_climate_breakdown()`
##   - `generator._last_climate_dirty_ratio` → `bus.get_climate_dirty_ratio()`
##   - 同理其他
##
## ─── 拆完后 generator 应有变化 ─────────────────────────────────────────
##
## - 字段：`_last_*_breakdown` / `_daily_*_call_count` / `_last_climate_*_ratio` 等
##   ~10 个 instrumentation 字段从 map_generator.gd 删除
## - 函数：`sus_climate_breakdown()` / `sus_weather_breakdown()` 改为
##   forward 到 bus（保留 generator.* 接口兼容；或一步到位删除让 caller 直接走 bus）
## - 行数：map_generator.gd 减少 ~150 行 instrumentation 代码

# ─── Climate breakdown ────────────────────────────────────────────────

var _last_climate_breakdown: Dictionary = {}
var _last_climate_dirty_ratio: float = 1.0
var _last_climate_visited_ratio: float = 1.0
var _last_climate_pass_b_path: String = "full"
var _daily_climate_call_count: int = 0


func record_climate_breakdown(d: Dictionary) -> void:
	_last_climate_breakdown = d


func merge_climate_breakdown(d: Dictionary) -> void:
	if d.is_empty():
		return
	_last_climate_breakdown.merge(d, true)


func get_climate_breakdown() -> Dictionary:
	return _last_climate_breakdown.duplicate()


func record_climate_dirty_ratio(ratio: float) -> void:
	_last_climate_dirty_ratio = ratio


func get_climate_dirty_ratio() -> float:
	return _last_climate_dirty_ratio


func record_climate_visited_ratio(ratio: float) -> void:
	_last_climate_visited_ratio = ratio


func get_climate_visited_ratio() -> float:
	return _last_climate_visited_ratio


func record_climate_pass_b_path(path: String) -> void:
	_last_climate_pass_b_path = path


func get_climate_pass_b_path() -> String:
	return _last_climate_pass_b_path


func increment_climate_call_count() -> int:
	_daily_climate_call_count += 1
	return _daily_climate_call_count


func get_climate_call_count() -> int:
	return _daily_climate_call_count


# ─── Weather breakdown ────────────────────────────────────────────────

var _last_weather_breakdown: Dictionary = {}
var _daily_weather_call_count: int = 0


func record_weather_breakdown(d: Dictionary) -> void:
	_last_weather_breakdown = d


func replace_weather_breakdown(d: Dictionary, tick_idx: int = -1) -> void:
	_last_weather_breakdown = d.duplicate(true)
	if tick_idx >= 0:
		_last_weather_breakdown["_tick_idx"] = tick_idx


func merge_weather_breakdown(d: Dictionary) -> void:
	if d.is_empty():
		return
	_last_weather_breakdown.merge(d, true)


func get_weather_breakdown() -> Dictionary:
	return _last_weather_breakdown.duplicate()


func increment_weather_call_count() -> int:
	_daily_weather_call_count += 1
	return _daily_weather_call_count


func get_weather_call_count() -> int:
	return _daily_weather_call_count


# ─── Generic / extensible breakdown ───────────────────────────────────

# Future-proof：supports arbitrary sub-pass names without code change.
# Caller: bus.record_breakdown("ocean_water", {...})
var _breakdowns: Dictionary = {}


func record_breakdown(pass_name: String, d: Dictionary) -> void:
	_breakdowns[pass_name] = d


func get_breakdown(pass_name: String) -> Dictionary:
	var d: Dictionary = _breakdowns.get(pass_name, {})
	return d.duplicate() if not d.is_empty() else {}


func clear_all() -> void:
	_last_climate_breakdown.clear()
	_last_weather_breakdown.clear()
	_breakdowns.clear()
	_daily_climate_call_count = 0
	_daily_weather_call_count = 0
	_last_climate_dirty_ratio = 1.0
	_last_climate_visited_ratio = 1.0
	_last_climate_pass_b_path = "full"


func describe() -> String:
	return "DCDiagnosticsBus(climate_calls=%d weather_calls=%d breakdowns=%d)" % [
		_daily_climate_call_count,
		_daily_weather_call_count,
		_breakdowns.size(),
	]
