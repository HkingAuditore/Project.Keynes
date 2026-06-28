extends RefCounted
class_name DCSusSystemsBootstrap

## Phase D.3 / D.4 — runtime system 注册逻辑的目的地。
##
## 现状（Phase 1.4 接口骨架阶段，2026-05）：
##   注册逻辑实际仍在 `[map_generator.gd::_setup_sus`](../geography/map_generator.gd) line ~839 内
##   （那里有 DCSystemScheduler register_system 调用 + policy + retained boundary 配置）。
##   本类目前作为**诊断 / 查询接口骨架**，主要职责：
##     1. 在 `_setup_sus` 末尾被调用 `attach_post_setup(generator, scheduler)`，
##        持有 scheduler 引用作为运行期可读句柄；
##     2. 提供 `status_report()` 给 main.gd / Telemetry overlay / dev console 用，
##        无需 reach into generator 内部字段；
##     3. 提供 `get_scheduler()` 让 main.gd 在 Phase 3.4 拆分时能直接拿到 scheduler
##        引用（去掉 generator 这层间接的入口准备）。
##
## 拆分目标（Phase 3.4 执行）：
##   把 `_setup_sus` 内的 production register_system 段（SeasonRefreshSystem /
##   OceanCurrentsSystem / NativeDailySimJob 或 legacy daily boundary systems /
##   visual upload systems）搬到本类的 `bootstrap(generator, scheduler)`
##   方法里，让 main.gd 直接 `DCSusSystemsBootstrap.bootstrap(generator, scheduler)`
##   而不必走 generator._setup_sus 这条间接路径。
##
## 典型 ACTIVE 注册顺序：
##   1. SeasonRefreshSystem
##   2. OceanCurrentsSystem
##   3. NativeDailySimJob
##   4. EnumAtlasUploadSystem / DynamicVisualAtlasUploadSystem retained visual boundary
## legacy daily fallback 路径才会注册 ClimateDailySystem / WeatherDCSystem / SeaIceDailySystem。
##
## DCSystemScheduler 路径会按拓扑序重写 priority；上面的 priority 仅 SUS 兼容路径用。

var _generator: Object = null
var _scheduler: RefCounted = null
var _bootstrap_done: bool = false
var _bootstrap_ts_msec: int = -1

func _init(_main_node = null) -> void:
	# Phase 1.4 接口骨架：构造期不强制 generator/scheduler；
	# `attach_post_setup` 在 `_setup_sus` 末尾被调用以注入引用。
	pass

## 由 `map_generator.gd::_setup_sus` 在所有 system 注册完之后调用，
## 让 bootstrap 拿到 generator + scheduler 句柄。
##
## 调用方语义：本方法不重做注册——只是缓存引用。多次调用以最后一次为准。
func attach_post_setup(generator: Object, scheduler: RefCounted) -> void:
	_generator = generator
	_scheduler = scheduler
	_bootstrap_done = true
	_bootstrap_ts_msec = Time.get_ticks_msec()

## 返回当前 scheduler 引用（DCSystemScheduler 或 SusScheduler），
## 让 main.gd / debug 工具直接调 `tick(ctx)` 入口而无需 reach into generator。
##
## Phase 3.4 main.gd 拆分时会真正用上；当前 main.gd 仍走 `_generator.sus_tick_daily()`。
func get_scheduler() -> RefCounted:
	return _scheduler

## 是否已完成注册（attach_post_setup 是否被调过至少一次）。
func is_bootstrap_done() -> bool:
	return _bootstrap_done

## 诊断报告：返回当前 scheduler 的状态快照。供 Telemetry / dev console 用。
##
## 结构：
##   {
##     "bootstrap_done": bool,
##     "bootstrap_ts_msec": int,                  -- attach_post_setup 调用时刻
##     "scheduler_class": String,                  -- DCSystemScheduler / SusScheduler / null
##     "scheduler_is_dc": bool,                    -- true 时走 DCSystemScheduler 新路径
##     "system_count": int,                        -- 注册的 system / job 总数（-1 = 未知）
##     "registered_systems": Array[String],        -- system_id 字符串列表（best-effort）
##   }
func status_report() -> Dictionary:
	var out: Dictionary = {
		"bootstrap_done": _bootstrap_done,
		"bootstrap_ts_msec": _bootstrap_ts_msec,
		"scheduler_class": _scheduler_class_name(),
		"scheduler_is_dc": _is_dc_scheduler(),
		"system_count": _query_system_count(),
		"registered_systems": _query_registered_system_ids(),
	}
	return out

## 一行字符串日志（debug overlay 用）。
func status_one_liner() -> String:
	if not _bootstrap_done:
		return "[SusBootstrap] not bootstrapped"
	var s: Dictionary = status_report()
	return "[SusBootstrap] %s | %d systems | %s" % [
		String(s.get("scheduler_class", "?")),
		int(s.get("system_count", -1)),
		String(",").join(s.get("registered_systems", [])),
	]

# ─── private helpers ─────────────────────────────────────────────────

func _scheduler_class_name() -> String:
	if _scheduler == null:
		return "null"
	# DCSystemScheduler / SusScheduler 都有 class_name；用 get_class() 兜底。
	var script: Script = _scheduler.get_script() as Script
	if script != null and script.resource_path != "":
		return script.resource_path.get_file().get_basename()
	return _scheduler.get_class()

func _is_dc_scheduler() -> bool:
	if _scheduler == null:
		return false
	# DCSystemScheduler 独有 register_system 方法（SusScheduler 是 register_job）。
	# 这是运行期识别"新路径 vs 兼容路径"的最稳指标。
	return _scheduler.has_method("register_system") and not _scheduler.has_method("register_job")

func _query_system_count() -> int:
	if _scheduler == null:
		return -1
	# DCSystemScheduler 期望有 system_count() 或类似查询；fallback 到 _systems.size()
	# 反射访问。任一不可达返回 -1（"未知"）。
	if _scheduler.has_method("system_count"):
		return int(_scheduler.call("system_count"))
	if _scheduler.has_method("get_system_count"):
		return int(_scheduler.call("get_system_count"))
	# SusScheduler 路径：尝试读 _jobs 字段。
	var maybe = _scheduler.get("_systems") if "_systems" in _scheduler else null
	if maybe == null:
		maybe = _scheduler.get("_jobs") if "_jobs" in _scheduler else null
	if maybe is Array:
		return (maybe as Array).size()
	return -1

func _query_registered_system_ids() -> Array:
	var out: Array = []
	if _scheduler == null:
		return out
	# Best-effort：遍历 _systems / _jobs 反射读取 .system_id / .id 字段。
	var arr: Array = []
	var systems_val = _scheduler.get("_systems") if "_systems" in _scheduler else null
	if systems_val is Array:
		arr = systems_val
	else:
		var jobs_val = _scheduler.get("_jobs") if "_jobs" in _scheduler else null
		if jobs_val is Array:
			arr = jobs_val
	for s in arr:
		if s == null:
			continue
		# DCSystem.system_id / SusJob.id 命名约定。
		if "system_id" in s:
			out.append(String(s.system_id))
		elif "id" in s:
			out.append(String(s.id))
		else:
			out.append("<anonymous>")
	return out
