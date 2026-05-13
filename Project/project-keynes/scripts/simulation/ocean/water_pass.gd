extends RefCounted
class_name DCOceanWaterPass

## Phase E.5 / dots-full-migration §Phase E.5：洋流热输运·水段抽出。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`map_generator.gd`](../../geography/map_generator.gd) 待按下方"逐函数
## 搬迁清单"移过来。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
## 主入口（GDScript legacy + SoA 两路径）：
##   - `_ocean_water_pass(map, season_phase)`        — line 3735 (~100 行) — legacy AoS
##   - `_ocean_water_pass_soa(map, season_phase, cp)` — line 4429 (~80 行) — SoA pipeline
##
## 父级 dispatch：
##   - `_apply_ocean_heat_transport_pass(map, season_phase)` — line 3706 (~25 行)
##     根据 use_soa_pipeline 切换到 _soa 版本
##
## ─── F.2 C++ 化路径（charter §7 目标 6.8ms → < 0.5ms × 2）──────────────
##
## C++ 实现：[`gdext/src/world_ext.cpp`](../../../../gdext/src/world_ext.cpp) 加
##   `run_ocean_water_pass(...)` + `run_ocean_land_pass(...)` 两个独立 pass
## flag：`use_gdext_ocean_water` / `use_gdext_ocean_land`（独立切换便于 A/B 比对）
##
## 邻居访问：6 邻 hex 索引（已有 cell.ocean_current_x/y 拓扑），按 charter §12.6
## 多输入 + 邻居模板。
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 调用入口由 ClimateDailySystem._inner._run_pass(_PASS_OCEAN_WATER) 接管；
## 2. 写 cell.temperature_transport_anomaly（仅水域 cell）；
## 3. 必须严格在 land_pass 之前跑（land_pass 读邻居水 cell 的 anomaly）；
## 4. 受 enable_ocean_heat_transport flag 控制。

var _generator

func _init(generator) -> void:
	_generator = generator

func run(map: MapData, season_phase: float) -> void:
	if _generator == null:
		return
	# Future: cp.use_gdext_ocean_water 切 dots_cpp / cp.use_soa_pipeline 切 soa
	pass

func describe() -> String:
	return "DCOceanWaterPass(generator=%s)" % ("present" if _generator != null else "(null)")
