extends RefCounted
class_name DCSeaIceDailyPass

## Phase E.5 / dots-full-migration §Phase E.5：海冰逐日演替抽出。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`map_generator.gd`](../../geography/map_generator.gd) 待搬迁。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
##   - `_apply_sea_ice_daily_pass(map, season_phase)` — line 3573 (~130 行)
##     主要：
##       - 每日推进 cell.sea_ice_fraction（按温度 + 上升流冷源 + 邻居 EMA 平滑）
##       - terrain 翻转（cell.sea_ice_fraction 跨过 sea_ice_terrain_threshold
##         → cell.terrain 改 SEA_ICE；跌回 threshold - hysteresis_delta 翻回 base_terrain）
##
## ─── F.4 C++ 化路径（charter §7 目标 5.1ms → < 0.5ms）──────────────────
##
## C++ 实现：[`gdext/src/world_ext.cpp`](../../../../gdext/src/world_ext.cpp) 加
##   `run_sea_ice_daily_pass(...)`
##
## **terrain 翻转特殊处理**（charter §2.5 反模式 STRUCT-001）：
## terrain 是结构性变更（影响 baker 的 enum_atlas，需要 rebake）。F.4 C++ pass
## 不能在 hot loop 里直接 cell.terrain = SEA_ICE（会触发 PackedArray COW 等问题）。
## 正确路径：
##   - 在 hot loop 里用 ECB（DCWorld.command_buffer.set_archetype 或类似）记录
##     待翻转的 cell idx
##   - pass 末尾 flush ECB
##   - SUS 主循环末尾触发 baker.rebake_enum_atlas_axis("terrain")
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 调用入口由 ClimateDailySystem._inner._run_pass(_PASS_SEA_ICE) 接管；
## 2. 写 cell.sea_ice_frac（hot path）+ cell.terrain（罕触发，走 ECB）；
## 3. ClimateDailySystem.declare_writes 必须包含 CELL_SEA_ICE_FRAC + CELL_TERRAIN（已声明）；
## 4. hysteresis 阈值（sea_ice_terrain_threshold / hysteresis_delta）保留在
##    ClimateProfile，本类读不写。

var _generator

func _init(generator) -> void:
	_generator = generator

func run(map: MapData, season_phase: float) -> void:
	if _generator == null:
		return
	pass

func describe() -> String:
	return "DCSeaIceDailyPass(generator=%s)" % ("present" if _generator != null else "(null)")
