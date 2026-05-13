extends DCSystem
class_name ClimateDailySystem

## Phase C.3 — DCSystem 改写自 [`RefreshClimateDailyJob`](../sus/jobs/refresh_climate_daily_job.gd)。
##
## 实现策略：当前版本是 **wrapper**——内部持一个 RefreshClimateDailyJob 实例，
## tick() 转发到 _inner.run_slice()。这让 declare_reads/writes 与
## DCSystemScheduler 调度立刻可用，而 419 行的 6-stage round 切片 + 25 个
## comp_id 缓存 + Dirty Mask 钩子等内部状态无需立刻重写。后续 PR（C.3 续）可
## 把 _inner 内部 25 行 `_comp_cell_* = _world.component_id(...)` 全部删除——
## 它们已经被 DCSystem 基类自动 cache 到 _cid 字典，与 setup() 形成重复。
##
## reads / writes 声明：
##   - reads: 25 个 cell-level component（climate Pass-A/B 与 ocean / sea_ice /
##            transp 计算的全部输入）
##   - writes: 主要写 cell.temp / cell.moisture / cell.snow_cover /
##             cell.sea_ice_frac / cell.temp_30d / cell.temp_365d /
##             cell.temp_anomaly / cell.temp_baseline / cell.temp_season_offset /
##             cell.air_mass_temp_anomaly / cell.climate_dirty_mask /
##             cell.ema_initialized
##
## feature_flag：留空（climate daily 是世界推进必跑流程）。

const _RefreshClimateDailyJobScript = preload("res://scripts/simulation/sus/jobs/refresh_climate_daily_job.gd")

var _inner: _RefreshClimateDailyJobScript = null


func _init(p_generator, p_map: MapData, p_phase_getter: Callable, p_stride: int) -> void:
	_inner = _RefreshClimateDailyJobScript.new(p_generator, p_map, p_phase_getter, p_stride)
	id = _inner.id
	priority = _inner.priority
	slice_budget_ms = _inner.slice_budget_ms
	must_run = _inner.must_run
	starvation_threshold = _inner.starvation_threshold
	policy = _inner.policy
	depends_on = _inner.depends_on


func declare_reads() -> Array[StringName]:
	# 与 RefreshClimateDailyJob._on_world_bound 内手写 25 个 _comp_cell_* 缓存
	# 1:1 对齐
	return [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_TEMP_BASELINE,
		DCComponentIds.CELL_TEMP_30D,
		DCComponentIds.CELL_TEMP_365D,
		DCComponentIds.CELL_TEMP_ANOMALY,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_SNOW_COVER,
		DCComponentIds.CELL_SEA_ICE_FRAC,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_BASE_MOISTURE,
		DCComponentIds.CELL_OCEAN_CURRENT_X,
		DCComponentIds.CELL_OCEAN_CURRENT_Y,
		DCComponentIds.CELL_WIND_X,
		DCComponentIds.CELL_WIND_Y,
		DCComponentIds.CELL_POS_X,
		DCComponentIds.CELL_POS_Y,
		DCComponentIds.CELL_LAT_NORM,
		DCComponentIds.CELL_TEMP_BASELINE_YEAR,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_COVER,
		DCComponentIds.CELL_IS_WATER,
		DCComponentIds.CELL_EMA_INITIALIZED,
		DCComponentIds.CELL_TEMP_SEASON_OFFSET,
	]


func declare_writes() -> Array[StringName]:
	return [
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_TEMP_30D,
		DCComponentIds.CELL_TEMP_365D,
		DCComponentIds.CELL_TEMP_ANOMALY,
		DCComponentIds.CELL_TEMP_BASELINE,
		DCComponentIds.CELL_TEMP_SEASON_OFFSET,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_SNOW_COVER,
		DCComponentIds.CELL_SEA_ICE_FRAC,
		DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY,
		DCComponentIds.CELL_CLIMATE_DIRTY,
		DCComponentIds.CELL_EMA_INITIALIZED,
	]


func declare_pools() -> Array[StringName]:
	return [DCComponentIds.POOL_CELLS]


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	return _inner.should_run(ctx)


func tick(ctx) -> Dictionary:
	return _inner.run_slice(ctx)


func reset_progress() -> void:
	super.reset_progress()
	_inner.reset_progress()


func reconfigure(p_stride: int) -> void:
	_inner.reconfigure(p_stride)
	policy = _inner.policy


# 透传查询接口（generator / main.gd 可能调用）
func data_core_ready() -> bool:
	return _inner.data_core_ready()


func did_run_last_tick() -> bool:
	return _inner.did_run_last_tick()


func last_slice_elapsed_ms() -> float:
	return _inner.last_slice_elapsed_ms()


func reset_run_flag() -> void:
	_inner.reset_run_flag()
