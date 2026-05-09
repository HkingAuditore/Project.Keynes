extends "res://scripts/simulation/sus/sus_job.gd"
class_name SeaIceAtlasUploadJob

## SeaIceAtlasUploadJob — 把 MapBaker.bake_sea_ice_fraction_only 从每日热路径
## (refresh_climate_daily) 中摘出，放到 SUS 调度。每 stride 日上传一次海冰
## R8 纹理；玩家不可察觉延迟（典型 stride=2 → 每 2 日刷新）。
##
## Daily Sim SoA Refactor 阶段 1。之前每日 ice_bake ~105ms 占 fast tick 1/4，
## 拆出后：
##   - 频率折半（stride=2）→ 摊薄 50%
##   - GPU 上传从 RGBA8 → R8 → 字节量 -75%
##   - 不再阻塞 refresh_climate_daily 的 cell-only 计算
##
## Driven by:    SUS daily tick (sourced from main.gd._on_day_changed).
## Strategy:     StridePolicy(stride). 与其它日级 Job 同一调度器协作；
##               GPU 上传必须执行（否则海冰永远不可视化）→ must_run = true。
##
## Note: 这个 Job 与 RefreshClimateDailyJob 不存在数据依赖——cell.sea_ice_fraction
## 是由 _apply_sea_ice_daily_pass（climate Job 内部）写入的，本 Job 只是上传
## 当前 cell 字段值的快照。即使本 tick climate Job 被 stride 跳日，本 Job 上传的
## 也是上一日的 sea_ice_fraction（视觉上完全合理：海冰每日变化≪5%）。

const SusJobScript = preload("res://scripts/simulation/sus/sus_job.gd")
const SusPolicyScript = preload("res://scripts/simulation/sus/sus_policy.gd")
const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")

# External references — wired up by MapGenerator at registration time.
var baker: MapBakerScript = null
var map: MapData = null
var world: WorldData = null

# Mirrored stride for fast reconfigure() without rebuilding the whole Job.
var stride: int = 2


func _init(p_baker: MapBakerScript, p_map: MapData, p_world: WorldData,
		p_stride: int) -> void:
	id = &"sea_ice_atlas_upload"
	# priority=250：晚于 ocean_currents(200)，最后跑。它纯渲染上传，被任何其它
	# Job 阻塞都不影响游戏世界状态推进；唯一作用是给玩家看见正确海冰可视化。
	priority = 250
	# 切片预算：单次完整一遍 lookup + 增量水格扫，~10-20ms。不强切片化。
	slice_budget_ms = 25.0
	# 海冰可视化允许滞后；不要让 atlas 上传绕过 frame_budget 造成主线程长尾。
	must_run = false
	baker = p_baker
	map = p_map
	world = p_world
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)


func should_run(ctx: SusTickContext) -> bool:
	if baker == null or map == null or world == null:
		return false
	return super.should_run(ctx)


func run_slice(ctx: SusTickContext) -> Dictionary:
	var t_start_us: int = Time.get_ticks_usec()
	if baker == null or map == null or world == null:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0 }
	baker.bake_sea_ice_fraction_only(map, world)
	var elapsed_ms: float = (Time.get_ticks_usec() - t_start_us) / 1000.0
	return {
		"done": true,
		"work_done": map.cell_count() if map != null else 0,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": 1.0,
	}


## Allow MapGenerator to retune the stride on the fly (climate profile reload).
func reconfigure(p_stride: int) -> void:
	stride = max(1, p_stride)
	policy = SusPolicyScript.StridePolicy.new(stride, 0)
