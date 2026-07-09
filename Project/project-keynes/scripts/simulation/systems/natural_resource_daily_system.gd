extends DCSystem
class_name NaturalResourceDailySystem

## `natural_resource_daily` — 自然资源每日生成/衰减 DCSystem。
##
## 独立于气候计算的资源演化任务。每 tick 对每个地块、每种资源按「固定公式模板 +
## 每资源系数」（见 resource_profile.gd）结合 cell_temp / cell_moisture 计算生成量与
## 衰减量，更新 reserve。计算权威在 C++ run_natural_resource_pass（slot 权威，flush 回
## MapData）；native 不可用时 generator 走 GDScript fallback 同模板。
##
## 调度：reads cell_temp / cell_moisture（由 refresh_climate_daily 写），故 build_topology
## 自动把本 system 排在气候之后；不加硬 depends_on（避免 weather 那类长期 dep_pending）。
##
## reads / writes：
##   reads:  cell.temp / cell.moisture / cell.is_water（公式输入 + land_only gate）
##   writes: 各资源 reserve component（economy.resources）
##
## feature_flag：留空（常驻；若资源表为空则 pass 自身 no-op）。

const _SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var stride: int = 1
var _last_path: String = "none"
var _slow_dump_last_tick: int = -100000

const _SLOW_DUMP_MS: float = 1.5
const _SLOW_DUMP_MIN_INTERVAL_TICKS: int = 60


func _init(p_generator, p_map: MapData, p_stride: int = 1) -> void:
	id = &"natural_resource_daily"
	priority = 120  # 注册时占位；build_topology 按 reads/writes 重写（climate 之后）
	slice_budget_ms = 0.55
	max_slices_per_tick = 1
	# must_run=true：本 pass 排在气候之后，而 native_daily_sim（must_run）单 Job 即可
	# 超 frame budget；若本 Job must_run=false 会被 sus_scheduler 的 frame_budget_exhausted
	# 守卫每日跳过 → reserve 永不演化（玩家观察不到资源变化）。整图 2 资源的 C++ pass
	# 成本 < 1ms，作为核心每日 sim 机制与 climate 一致设为 must_run。
	must_run = true
	generator = p_generator
	map = p_map
	stride = max(1, p_stride)
	policy = _SusPolicyScript.StridePolicy.new(stride, 0)


func declare_reads() -> Array[StringName]:
	return [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_IS_WATER,
	]


func declare_writes() -> Array[StringName]:
	# economy.resources：每种资源的 reserve 字段（顺序与 ResourceProfileRegistry 对齐）。
	# 新增资源时同步更新此表，让调度器拓扑与写权限校验正确。
	return [
		DCComponentIds.CELL_RES_BIOMASS_RESERVE,
		DCComponentIds.CELL_RES_IRON_ORE_RESERVE,
		# 性能压测用 10 种测试资源
		DCComponentIds.CELL_RES_FRESHWATER_RESERVE,
		DCComponentIds.CELL_RES_TIMBER_RESERVE,
		DCComponentIds.CELL_RES_COAL_RESERVE,
		DCComponentIds.CELL_RES_OIL_RESERVE,
		DCComponentIds.CELL_RES_CLAY_RESERVE,
		DCComponentIds.CELL_RES_WILD_GAME_RESERVE,
		DCComponentIds.CELL_RES_PEAT_RESERVE,
		DCComponentIds.CELL_RES_STONE_RESERVE,
		DCComponentIds.CELL_RES_WILD_HERBS_RESERVE,
		DCComponentIds.CELL_RES_GEOTHERMAL_RESERVE,
	]


func declare_pools() -> Array[StringName]:
	return [DCComponentIds.POOL_CELLS]


func feature_flag() -> StringName:
	return &""


func tick(ctx) -> Dictionary:
	var t0: int = Time.get_ticks_usec()
	if generator == null or map == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}

	var res: Dictionary = {}
	if generator.has_method("run_natural_resource_pass_native"):
		res = generator.run_natural_resource_pass_native(map, stride)
	_last_path = str(res.get("path", "gdscript"))

	var elapsed_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	_maybe_dump_slow(ctx, res, elapsed_ms)
	return {
		"done": true,
		"work_done": map.cell_count(),
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
		"stage_name": "natural_resource_daily",
		"path": _last_path,
		"kernel_ms": float(res.get("native_ms", 0.0)),
		"kernel_compute_ms": float(res.get("compute_ms", 0.0)),
		"kernel_loop_ms": float(res.get("loop_ms", 0.0)),
		"kernel_flush_ms": float(res.get("flush_ms", 0.0)),
		"kernel_loop_layout": str(res.get("loop_layout", "")),
		"kernel_loop_dispatches": int(res.get("loop_dispatches", 0)),
		"skipped_static_resources": int(res.get("skipped_static_resources", 0)),
		"published_resource_count": int(res.get("published_resource_count", res.get("resource_count", 0))),
		"input_resource_count": int(res.get("input_resource_count", res.get("resource_count", 0))),
		"published_to_slot": bool(res.get("published_to_slot", false)),
		"dt_days": int(res.get("dt_days", stride)),
		"total_delta": float(res.get("total_delta", 0.0)),
	}


func _maybe_dump_slow(ctx, res: Dictionary, elapsed_ms: float) -> void:
	if elapsed_ms < _SLOW_DUMP_MS:
		return
	var tick_idx: int = -1
	var day_idx: int = -1
	if ctx != null:
		tick_idx = int(ctx.tick_index)
		day_idx = int(ctx.day_index)
	if tick_idx >= 0 and tick_idx - _slow_dump_last_tick < _SLOW_DUMP_MIN_INTERVAL_TICKS:
		return
	_slow_dump_last_tick = tick_idx
	var kernel_ms: float = float(res.get("native_ms", 0.0))
	var wrapper_ms: float = float(res.get("wrapper_overhead_ms", max(0.0, elapsed_ms - kernel_ms)))
	print("[natural_resource/slow-dump] tick=%d day=%d wall=%.2f cpp=%.3f compute=%.3f loop=%.3f flush=%.3f wrapper=%.3f layout=%s dispatches=%d resources=%d/%d skipped_static=%d published=%s total_delta=%.5f" % [
		tick_idx,
		day_idx,
		elapsed_ms,
		kernel_ms,
		float(res.get("compute_ms", 0.0)),
		float(res.get("loop_ms", 0.0)),
		float(res.get("flush_ms", 0.0)),
		wrapper_ms,
		str(res.get("loop_layout", "")),
		int(res.get("loop_dispatches", 0)),
		int(res.get("published_resource_count", res.get("resource_count", 0))),
		int(res.get("input_resource_count", res.get("resource_count", 0))),
		int(res.get("skipped_static_resources", 0)),
		str(bool(res.get("published_to_slot", false))),
		float(res.get("total_delta", 0.0)),
	])
