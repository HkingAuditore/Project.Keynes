extends DCSystem
class_name SeasonRefreshSystem

## Phase C.3 — DCSystem 改写自 [`SeasonRefreshJob`](../sus/jobs/season_refresh_job.gd)。
##
## 行为完全等价（11-stage round 切片在 generator 内部，本 system 仅协调 stage 推进）。
##
## reads / writes 声明：
##   - reads:  季节切换时整张地图都要参与，但内部计算的中间字段未对外暴露
##             component；这里仅声明对调度器有意义的 high-level 输入
##   - writes: cell.terrain / cell.landform / cell.vegetation / cell.cover /
##             cell.moisture / cell.base_moisture / cell.weather_dirty_mask /
##             cell.snow_cover（季节 redecide 阶段会动这些字段）
##
## feature_flag：留空（季节切换是世界推进必跑流程，无 toggle）。

const _SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")

var generator = null
var map: MapData = null
var world_data: WorldData = null
var _stage: int = 0
var _season_idx: int = 0
var _round_active: bool = false


func _init(p_generator, p_map: MapData, p_world: WorldData) -> void:
	id = &"season_refresh"
	priority = 50
	slice_budget_ms = 0.0
	must_run = false
	generator = p_generator
	map = p_map
	world_data = p_world
	policy = _SusPolicyScript.AlwaysPolicy.new()


func declare_reads() -> Array[StringName]:
	# 季节计算大量读 base_*  / lat_norm / elevation 等慢层字段
	return [
		DCComponentIds.CELL_BASE_MOISTURE,
		DCComponentIds.CELL_LAT_NORM,
		DCComponentIds.CELL_ELEVATION,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_VEGETATION,
	]


func declare_writes() -> Array[StringName]:
	# 季节 redecide 改写的字段
	return [
		DCComponentIds.CELL_TERRAIN,
		DCComponentIds.CELL_LANDFORM,
		DCComponentIds.CELL_VEGETATION,
		DCComponentIds.CELL_COVER,
		DCComponentIds.CELL_MOISTURE,
		DCComponentIds.CELL_BASE_MOISTURE,
		DCComponentIds.CELL_WEATHER_DIRTY,
		DCComponentIds.CELL_SNOW_COVER,
	]


func feature_flag() -> StringName:
	return &""


func should_run(_ctx: SusTickContext) -> bool:
	if generator == null or map == null or world_data == null:
		return false
	if _round_active:
		return true
	if not generator.has_method("has_pending_season_refresh"):
		return false
	return bool(generator.has_pending_season_refresh())


func tick(_ctx) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if generator == null or map == null or world_data == null:
		return {"done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0}

	if not _round_active:
		if generator.has_method("begin_pending_season_refresh"):
			_season_idx = int(generator.begin_pending_season_refresh())
		_stage = 0
		_round_active = true

	if generator.has_method("run_season_refresh_stage"):
		generator.run_season_refresh_stage(map, world_data, _season_idx, _stage)
	_stage += 1

	# 与 SeasonRefreshJob 一致：12 stages
	var done: bool = _stage >= 12
	if done:
		_round_active = false
		if generator.has_method("finish_season_refresh"):
			generator.finish_season_refresh(map, world_data, _season_idx)
		_stage = 0

	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	return {
		"done": done,
		"work_done": 1,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0 if done else float(_stage) / 12.0,
	}


func reset_progress() -> void:
	super.reset_progress()
	_stage = 0
	_round_active = false
