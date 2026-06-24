extends RefCounted
class_name DCOceanLandPass

## Phase E.5 / dots-full-migration §Phase E.5：洋流热输运·陆段抽出。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`map_generator.gd`](../../geography/map_generator.gd) 待搬迁。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
##   - `_ocean_land_pass(map, season_phase)`        — line 3838 (~100 行) — legacy AoS
##   - `_ocean_land_pass_soa(map, season_phase, cp)` — line 4512 (~80 行) — SoA pipeline
##
## ─── 顺序约束（**关键**）─────────────────────────────────────────────
##
## 必须在 water_pass 之后跑：water_pass 写水域 cell 的
## temperature_transport_anomaly；land_pass 读邻居水 cell 的 anomaly 注入到
## 陆地 cell。顺序反了陆地 cell 读到旧值（一日延迟，长期偏移可见）。
##
## ─── F.2 C++ 化路径（charter §7 目标 6.8ms → < 0.5ms × 2）──────────────
##
## 见 water_pass.gd 顶部说明。两个 pass 独立 C++ 化。
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 调用入口由 ClimateDailySystem._inner._run_pass(_PASS_OCEAN_LAND) 接管；
## 2. 写陆地 cell.temperature（注入 anomaly），不写水域；
## 3. 受 enable_ocean_heat_transport flag 控制（与 water 同一个开关）。

var _generator

func _init(generator) -> void:
	_generator = generator

func run(map: MapData, season_phase: float) -> void:
	if _generator == null or map == null:
		return
	# 本阶段先接管调用入口，保持原 MapGenerator legacy 实现作为行为权威。
	_generator._ocean_land_pass_legacy(map, season_phase)


func describe() -> String:
	return "DCOceanLandPass(generator=%s)" % ("present" if _generator != null else "(null)")
