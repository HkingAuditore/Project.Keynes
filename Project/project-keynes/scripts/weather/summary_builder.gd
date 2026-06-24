extends RefCounted
class_name DCWeatherSummaryBuilder

## Phase E.2 / dots-full-migration §Phase E.2：weather summary fronts 聚类抽出。
##
## **当前状态**：迁移规格已定义；函数体仍在
## [`weather_system.gd`](./weather_system.gd) 待搬迁。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
## - `_build_field_summary_fronts(map, world) -> Array[WeatherFront]`
##     — line 1573 (~480 行，本类核心)
##     从 _weather_field 的 per-cell vapor/cloud/precip 通过 flood-fill 聚类成
##     最多 _field_summary_limit (=12) 个"视觉天气前沿"WeatherFront 实例，
##     用于 shader uniform 上传 + 渲染层云团。
##
## - 跨 tick 身份继承字段（搬迁后从 weather_system 删除）：
##     `_prev_summary_membership: Dictionary` (HexCell → cluster_idx)
##     `_prev_summary_seeds: Array` ({type, center, age, area}, 上 tick 聚合中心)
##     `_field_summary_limit: int = 12`
##     `DRIFT_DEBUG_LOG: bool` (调试钩子)
##
## - hysteresis 阈值（避免 cluster 在边界来回跳）：
##     0.06（在簇内 cell 留簇阈值）
##     0.10（新加入 cell 进簇阈值）
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 接受 weather_system owner；
## 2. 读 weather field 走 ViewAdapter.get_weather_*；
## 3. 跨 tick 身份继承字段（_prev_summary_*）保留在本类（_init 时清零，
##    _build_field_summary_fronts 末尾刷新）；
## 4. 输出 fronts 数组返回给 weather_system 做 shader uniform 上传。
##
## ─── 验收标准 ────────────────────────────────────────────────────
##
## 拆分前后视觉云团位置必须像素级一致——这是 weather_layer 的关键回归点。

var _weather_system
var _prev_summary_membership: Dictionary = {}
var _prev_summary_seeds: Array = []

const FIELD_SUMMARY_LIMIT: int = 12
const HYSTERESIS_STAY_IN_CLUSTER: float = 0.06
const HYSTERESIS_JOIN_NEW_CLUSTER: float = 0.10

func _init(weather_system) -> void:
	_weather_system = weather_system
	# Clear cross-tick state on init / regenerate
	_prev_summary_membership.clear()
	_prev_summary_seeds.clear()

## 主入口：从 _weather_field 聚类构造 summary fronts。
##
## 本阶段先把调用权从 WeatherSystem facade 切到子模块；为保持视觉云团
## 像素级一致，聚类主体暂时复用 owner 中改名后的 legacy 实现。后续迁移
## `_pick_inheritance_seed` / `_flood_fill_field_component` / `_merge_nearby_components`
## 时，本类已具备独立保存跨 tick summary 状态的字段。
func build(map: MapData, world: WorldData) -> Array[WeatherFront]:
	if _weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	return _weather_system._build_field_summary_fronts_legacy(map, world)


## 重置跨 tick 身份继承（regenerate 路径调用）。
func reset() -> void:
	_prev_summary_membership.clear()
	_prev_summary_seeds.clear()

func describe() -> String:
	return "DCWeatherSummaryBuilder(owner=%s seeds=%d)" % [
		"ws" if _weather_system != null else "(null)",
		_prev_summary_seeds.size(),
	]
