extends DCSystem
class_name OceanCurrentsSystem

## Phase C.3 — DCSystem 改写自 [`OceanCurrentsJob`](../sus/jobs/ocean_currents_job.gd)。
##
## 实现策略：当前版本是 **wrapper**——内部持一个 OceanCurrentsJob 实例，
## tick() 转发到 _inner.run_slice()。这让 declare_reads/writes 与
## DCSystemScheduler 调度立刻可用，而 181 行 ocean current 切片逻辑无需立刻
## 重写。后续 PR 可逐步把 _inner 字段消费替换为本类直接持有相同字段。
##
## reads / writes 声明：
##   - reads:  cell.elevation / cell.is_water / cell.terrain（baker 烘焙洋流时
##             读这些慢层字段）
##   - writes: cell.ocean_current_x / .ocean_current_y（per-cell 洋流向量）
##
## feature_flag：留空（洋流是世界推进必跑流程）。

const _OceanCurrentsJobScript = preload("res://scripts/simulation/sus/jobs/ocean_currents_job.gd")
const _MapBakerScript = preload("res://scripts/rendering/map_baker.gd")

var _inner: _OceanCurrentsJobScript = null


func _init(p_baker: _MapBakerScript, p_map: MapData, p_world: WorldData,
		p_cfg: MapConfig, p_hex_size: float,
		p_period_ticks: int, p_slice_count: int) -> void:
	# 委托给现有 OceanCurrentsJob 完成所有内部状态初始化（policy / 切片游标 /
	# 锁定 phase 等）。本 wrapper 只暴露 DCSystem 接口。
	_inner = _OceanCurrentsJobScript.new(p_baker, p_map, p_world, p_cfg, p_hex_size,
		p_period_ticks, p_slice_count)
	# 把内部 SusJob 的运行时字段 mirror 到本 system，让 SUS 兼容路径能直接读
	id = _inner.id
	priority = _inner.priority
	slice_budget_ms = _inner.slice_budget_ms
	must_run = _inner.must_run
	starvation_threshold = _inner.starvation_threshold
	policy = _inner.policy
	depends_on = _inner.depends_on


func declare_reads() -> Array[StringName]:
	return [
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_IS_WATER,
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_LAT_NORM,
	]


func declare_writes() -> Array[StringName]:
	return [
		DCComponentIds.CELL_OCEAN_CURRENT_X,
		DCComponentIds.CELL_OCEAN_CURRENT_Y,
	]


func feature_flag() -> StringName:
	return &""


func should_run(ctx: SusTickContext) -> bool:
	return _inner.should_run(ctx)


func tick(ctx) -> Dictionary:
	return _inner.run_slice(ctx)


func reset_progress() -> void:
	super.reset_progress()
	_inner.reset_progress()


# 透传 OceanCurrentsJob 上的可选 callable 字段（main.gd 可能直接配置）
func set_on_commit(cb: Callable) -> void:
	_inner.on_commit = cb


func set_season_phase_getter(cb: Callable) -> void:
	_inner.season_phase_getter = cb


# 暴露内部 SusJob 给 map_generator 等需要直接调用 OceanCurrentsJob 强类型
# API 的 caller。0.4.1 use_dc_system_scheduler=true 路径用。
func get_inner() -> _OceanCurrentsJobScript:
	return _inner
