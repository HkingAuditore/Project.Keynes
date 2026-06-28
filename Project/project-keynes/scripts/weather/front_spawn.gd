extends RefCounted
class_name DCWeatherFrontSpawn

## Phase E.2 / dots-full-migration §Phase E.2：weather front spawn 抽出。
##
## **当前状态**：迁移规格已定义；实际函数体仍在
## [`weather_system.gd`](./weather_system.gd) 待按"逐函数搬迁清单"移过来。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
## - `_spawn_random_front(world, season_idx, climate_anomaly) -> WeatherFront`
##     — line 308 (~80 行)
##     spawn 概率评分主函数：由本地气象场和 ocean_spawn_bias 决定，不再读取季节概率表
##     调整 + 选 cell 候选评分。
##
## - `_build_front_at(spawn_pos, wt, world) -> WeatherFront`
##     — line 2366 (~50 行)
##     在指定 cell 构造 WeatherFront 实例（位置 + 速度 + radius + 寿命）。
##
## - tick_one_day 中 "spawn fronts" 段（约 line 280-340，循环 SPAWN_TRIES_PER_DAY）
##
## - 配置常量：
##     legacy 四季概率表已移除
##     `SPAWN_TRIES_PER_DAY = 2`
##     `MAX_FRONTS = 16`
##
## - 字段：
##     `_ocean_spawn_bias`（由 configure_ocean_spawn_bias 写入）
##     `_use_wind_vector_for_advect`（v11 wind_vector 优先开关）
##     `_emergent_*` 系列耦合参数（5 个字段）
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 接受 weather_system owner；
## 2. 读 cell.terrain / cell.is_water / cell.ocean_current_y 走 ViewAdapter；
## 3. spawn 评分常量保留在本类（业务参数）；
## 4. _active_fronts 仍由 weather_system 持有（front pool 暂未 DOTS 化）。

var _weather_system

func _init(weather_system) -> void:
	_weather_system = weather_system

## 主入口：尝试 spawn 一个 front。
## 当前为 stub；E.2 后由 weather_system.tick_one_day 切换为调用本方法。
func try_spawn(_world: WorldData, _season_idx: int, _climate_anomaly: float) -> WeatherFront:
	return null

func describe() -> String:
	return "DCWeatherFrontSpawn(owner=%s)" % ("ws" if _weather_system != null else "(null)")
