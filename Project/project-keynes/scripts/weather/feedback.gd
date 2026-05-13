extends RefCounted
class_name DCWeatherFeedback

## Phase E.2 / dots-full-migration §Phase E.2：weather → cell 反馈抽出。
##
## **当前状态**：迁移规格已定义；函数体仍在
## [`weather_system.gd`](./weather_system.gd) 待搬迁。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
## - `_distribute_weather_field_to_cells(map)`
##     — line 1541 (~32 行)
##     主要分发：把 _weather_field 的 per-cell vapor/cloud/precip/intensity/type
##     写到 cell.weather_* 强类型字段（与 SoA 镜像）。
##
## - tick_one_day 中 "distribute weather to cells" 段（间接通过
##   `_distribute_weather_field_to_cells` 与 _build_field_summary_fronts 完成）
##
## - 短期 cover override 逻辑（搜 BLIZZARD/MONSOON/STORM cover 改写代码段）：
##     BLIZZARD → cell.cover = SNOW（临时覆盖物，隔几天恢复）
##     MONSOON/STORM → cell.cover = FLOODING（同样临时）
##     由 _cover_dirty 标志触发 baker rebake_cover_tex_only
##
## - 临时温度/湿度调整（搜 `cell.temperature += weather_temp_offset` 等代码）
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 接受 weather_system owner；
## 2. 不写回 base_*（与现有设计一致：天气是临时层，不污染长期生态记忆）；
## 3. cell.cover / cell.weather_* 写路径在 G.4 后改为 world.write_*；
## 4. _cover_dirty 标志保留在 weather_system（作为 baker pipeline 的输入）。

var _weather_system

func _init(weather_system) -> void:
	_weather_system = weather_system

## 主入口：把 weather_field 写回 cell。
func distribute(_map: MapData) -> void:
	pass

## 主入口：临时改写 cell.cover（BLIZZARD/MONSOON/STORM 触发）。
func apply_cover_overrides(_map: MapData) -> void:
	pass

func describe() -> String:
	return "DCWeatherFeedback(owner=%s)" % ("ws" if _weather_system != null else "(null)")
