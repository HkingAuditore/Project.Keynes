extends DCSystem
class_name WeatherDCSystem

## Phase C.3 — DCSystem 改写自 [`WeatherRefreshJob`](../sus/jobs/weather_refresh_job.gd)。
##
## **类名**：`WeatherDCSystem`（不叫 WeatherSystem 是因为
## [`weather/weather_system.gd::WeatherSystem`](../../weather/weather_system.gd)
## 已用此名表示 weather 子系统的"业务实例"，二者职责完全不同）。本类是
## 调度入口；WeatherSystem 是被本类驱动的业务对象。
##
## 实现策略：当前版本是 **wrapper**——内部持一个 WeatherRefreshJob 实例，
## tick() 转发到 _inner.run_slice()。585 行的 field solver 三段式 + front pool
## ECB sync + dirty short-circuit 等内部状态无需立刻重写。
##
## reads / writes 声明：
##   - reads:  weather hot loop 读 25+ component（climate / 慢层 / weather 自身）
##   - writes: cell.weather_intensity / .weather_cloud / .weather_precip /
##             .weather_vapor / .weather_convergence / .weather_instability /
##             .weather_field_init / .weather_type / .weather_dirty_mask
##
## feature_flag：留空（weather 是世界推进必跑流程；DataCore 镜像由
## `use_data_core_weather` 控制，但本 system 在 legacy 路径也跑）。

const _WeatherRefreshJobScript = preload("res://scripts/simulation/sus/jobs/weather_refresh_job.gd")

var _inner: _WeatherRefreshJobScript = null


func _init(p_generator, p_map: MapData, p_world: WorldData,
		p_season_index_getter: Callable,
		p_season_phase_getter: Callable,
		p_climate_anomaly_getter: Callable,
		p_stride: int) -> void:
	# 委托给现有 WeatherRefreshJob 完成所有内部状态初始化（policy / 字段 cache /
	# field solver 切片状态等）。本 wrapper 只暴露 DCSystem 接口。
	_inner = _WeatherRefreshJobScript.new(p_generator, p_map, p_world,
		p_season_index_getter, p_season_phase_getter, p_climate_anomaly_getter, p_stride)
	# 把内部 SusJob 的运行时字段 mirror 到本 system，让 SUS 兼容路径能直接读
	id = _inner.id
	priority = _inner.priority
	slice_budget_ms = _inner.slice_budget_ms
	must_run = _inner.must_run
	starvation_threshold = _inner.starvation_threshold
	policy = _inner.policy
	depends_on = _inner.depends_on


func declare_reads() -> Array[StringName]:
	# 与 WeatherRefreshJob._on_world_bound 内手写 13 个 climate/慢层 + 6 个
	# weather 自身 component 一致
	return [
		DCComponentIds.CELL_WEATHER_INTENSITY,
		DCComponentIds.CELL_WEATHER_CLOUD,
		DCComponentIds.CELL_WEATHER_PRECIP,
		DCComponentIds.CELL_WEATHER_TYPE,
		DCComponentIds.CELL_WEATHER_VAPOR,
		DCComponentIds.CELL_WEATHER_CONVERGENCE,
		DCComponentIds.CELL_WEATHER_INSTABILITY,
		DCComponentIds.CELL_WEATHER_FIELD_INIT,
		DCComponentIds.CELL_AIR_MASS_TEMP_ANOMALY,
		DCComponentIds.CELL_HAS_RIVER,
		DCComponentIds.CELL_TEMP,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_WIND_X,
		DCComponentIds.CELL_WIND_Y,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_SNOW_COVER,
	]


func declare_writes() -> Array[StringName]:
	return [
		DCComponentIds.CELL_WEATHER_INTENSITY,
		DCComponentIds.CELL_WEATHER_CLOUD,
		DCComponentIds.CELL_WEATHER_PRECIP,
		DCComponentIds.CELL_WEATHER_TYPE,
		DCComponentIds.CELL_WEATHER_VAPOR,
		DCComponentIds.CELL_WEATHER_CONVERGENCE,
		DCComponentIds.CELL_WEATHER_INSTABILITY,
		DCComponentIds.CELL_WEATHER_FIELD_INIT,
		DCComponentIds.CELL_WEATHER_DIRTY,
	]


func declare_pools() -> Array[StringName]:
	return [DCComponentIds.POOL_CELLS, DCComponentIds.POOL_WEATHER_FRONTS]


func declare_archetypes() -> Array[StringName]:
	return [DCComponentIds.ARCH_WEATHER_FRONT]


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	return _inner.should_run(ctx)


func tick(ctx) -> Dictionary:
	return _inner.run_slice(ctx)


func reset_progress() -> void:
	super.reset_progress()
	_inner.reset_progress()


# 透传 WeatherRefreshJob 上的关键字段访问器，让 main.gd / generator 不用感知 wrapper 存在
func get_inner() -> _WeatherRefreshJobScript:
	return _inner
