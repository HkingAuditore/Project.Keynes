extends DCSystem
class_name OceanCurrentsSystem

## Phase C.3 — DCSystem 改写自 [`OceanCurrentsJob`](../sus/jobs/ocean_currents_job.gd)。
##
## 实现策略：当前版本是 **wrapper**——内部持一个 OceanCurrentsJob 实例，
## tick() 转发到 _inner.run_slice()。这让 declare_reads/writes 与
## DCSystemScheduler 调度立刻可用，而 181 行 ocean current 切片逻辑无需立刻
## 重写。
##
## ─── Phase 1.5 inline TODO（参照 ClimateDailySystem 已完成的模板）─────
##
## **状态**：当前仍 wrapper；ClimateDailySystem 已 inline 完毕（路径 1/3）。
##
## inline 化步骤（参照 climate_daily_system.gd 1:1 镜像）：
##   1. 把 OceanCurrentsJob 的全部成员变量复制到本类（baker / map / world /
##      cfg / hex_size / period_ticks / slice_count / _ocean_phase_locked /
##      _slice_cursor / _round_active / _round_t_* 等）；
##   2. 把 OceanCurrentsJob.run_slice() 的 ~100 行 sub-pass 推进逻辑 1:1
##      搬到本类 `func run_slice(ctx) -> Dictionary`；
##   3. 把 _on_world_bound() 中的 _comp_cell_* cache 删除——基类 DCSystem.setup()
##      已通过 declare_reads()/_cid 字典自动 cache；
##   4. 删除 _inner 字段 + 相关 forward 方法（tick / set_on_commit /
##      set_season_phase_getter / get_inner）；
##   5. map_generator.gd 调用 site：
##      a. _ocean_currents_job 改为指向本 system 自身（不再 .get_inner()）；
##      b. on_commit / season_phase_getter 直接赋值给本 system 的字段；
##   6. 验收：跑 SUS 30-tick log，avg / p95 与 wrapper 路径 ±3% 一致；
##      洋流贴图视觉无 diff（截图像素 < 0.1%）。
##
## 详见 [`docs/dots-wrapper-inline-followup.md`](../../../../docs/dots-wrapper-inline-followup.md)。
##
## reads / writes 声明：
##   - reads:  仅声明同 tick 拓扑依赖所需的稳定慢层字段。温度/雪冰/上一帧风场与洋流
##             是物理环流的时序反馈输入，按上一轮快照读取，不能声明为同 tick reads，
##             否则会与 ClimateDaily/SeaIce 构成拓扑环。
##   - writes: SLP、风向/风速、洋流、上升流。声明必须覆盖真实写集，确保
##             weather/climate 读到本轮物理环流产物。
##
## feature_flag：留空（洋流是世界推进必跑流程）。

const _OceanCurrentsJobScript = preload("res://scripts/simulation/sus/jobs/ocean_currents_job.gd")
const _MapBakerScript = preload("res://scripts/rendering/map_baker.gd")

var _inner: _OceanCurrentsJobScript = null


func _init(p_baker: _MapBakerScript, p_map: MapData, p_world: WorldData,
		p_cfg: MapConfig, p_hex_size: float,
		p_period_ticks: int, p_slice_count: int, p_ocean_period_ticks: int = -1) -> void:
	# 委托给现有 OceanCurrentsJob 完成所有内部状态初始化（policy / 切片游标 /
	# 锁定 phase 等）。本 wrapper 只暴露 DCSystem 接口。
	_inner = _OceanCurrentsJobScript.new(p_baker, p_map, p_world, p_cfg, p_hex_size,
		p_period_ticks, p_slice_count, p_ocean_period_ticks)
	# 把内部 SusJob 的运行时字段 mirror 到本 system，让 SUS 兼容路径能直接读
	id = _inner.id
	priority = _inner.priority
	slice_budget_ms = _inner.slice_budget_ms
	max_slices_per_tick = _inner.max_slices_per_tick
	must_run = _inner.must_run
	use_job_should_run = _inner.use_job_should_run
	starvation_threshold = _inner.starvation_threshold
	policy = _inner.policy
	depends_on = _inner.depends_on


func declare_reads() -> Array[StringName]:
	return [
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_IS_WATER,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_COVER,
		DCComponentIds.CELL_LAT_NORM,
		DCComponentIds.CELL_POS_X,
		DCComponentIds.CELL_POS_Y,
	]


func declare_writes() -> Array[StringName]:
	return [
		DCComponentIds.CELL_SLP,
		DCComponentIds.CELL_WIND_X,
		DCComponentIds.CELL_WIND_Y,
		DCComponentIds.CELL_WIND_SPEED,
		DCComponentIds.CELL_OCEAN_CURRENT_X,
		DCComponentIds.CELL_OCEAN_CURRENT_Y,
		DCComponentIds.CELL_UPWELLING_STRENGTH,
	]


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	return _inner.should_run(ctx)


func run_slice(ctx: SusTickContext) -> Dictionary:
	return _inner.run_slice(ctx)


func tick(ctx) -> Dictionary:
	return run_slice(ctx)


func reset_progress() -> void:
	super.reset_progress()
	_inner.reset_progress()


# 透传 OceanCurrentsJob 上的可选 callable 字段（main.gd 可能直接配置）
func set_on_commit(cb: Callable) -> void:
	_inner.on_commit = cb


func set_season_phase_getter(cb: Callable) -> void:
	_inner.season_phase_getter = cb


# 暴露内部 SusJob 给 map_generator 等仍需 OceanCurrentsJob 强类型 API 的 caller。
# Production 注册已恒走 DCSystemScheduler；这是 wrapper inline 前的临时桥。
func get_inner() -> _OceanCurrentsJobScript:
	return _inner
