extends RefCounted
class_name DCClimatePassA

## Phase E.4 / dots-full-migration §Phase E.4：climate Pass-A 抽出。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`map_generator.gd`](../../geography/map_generator.gd) 待按下方"逐函数搬迁清单"
## 移过来。本 facade 让 [`ClimateDailySystem`](../systems/climate_daily_system.gd)
## 在 G.3 后可以直接 call DCClimatePassA.run(...) 而不是 forward 到 generator。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
## 主入口（GDScript legacy + SoA pipeline 两路径）：
##   - `_climate_pass_a(map, season_phase)`        — line 3129 (~170 行) — legacy AoS
##   - `_climate_pass_a_soa(map, season_phase, cp)` — line 3941 (~250 行) — SoA pipeline
##
## 共享 helper（搬过来后从 generator 删除）：
##   - `_apply_pass_a_to_cell(cell, ...)` (如果存在；否则在主入口内联) — search line 3129+
##
## ─── DOTS 化路径选择（F.3 时再扩展）─────────────────────────────────
##
## - dots_gdscript_legacy: 调 _climate_pass_a (use_soa_pipeline=false 时)
## - dots_gdscript_soa:    调 _climate_pass_a_soa (use_soa_pipeline=true 时)
## - dots_cpp:             调 DCWorldExt::run_climate_pass_a（charter §3a Step 3b-1
##                         已落地；ClimateDailySystem 通过 use_data_core_climate
##                         切换）
##
## 注：F.3 在本规划中是 climate Pass-B 而非 Pass-A，因为 Pass-A 已 C++ 化。
## 本 pass_a.gd 主要承载 GDScript fallback 路径。
##
## ─── 拆完后预期 ─────────────────────────────────────────────────────
##
## - pass_a.gd ~600 行（含 SoA 路径 + legacy 路径 + 配套 helper）
## - map_generator.gd 中 line 3129-3300 + 3941-4196 共 ~440 行被搬走
## - ClimateDailySystem._inner._run_pass(_PASS_A) → DCClimatePassA.run(...)

var _generator  # MapGenerator owner（持有 _last_cfg / _c() 等配置）

func _init(generator) -> void:
	_generator = generator

## 主入口：跑 Pass-A（自动按 use_soa_pipeline 路径切换）。
## 当前为 stub；E.4 后由 ClimateDailySystem 切换为调用本方法。
func run(map: MapData, season_phase: float) -> void:
	if _generator == null:
		return
	# Future: switch by cp.use_soa_pipeline (use_data_core_climate has been removed in dots-flag-prune-pr1)
	# Currently: still goes through generator._climate_pass_a / _soa
	pass

func describe() -> String:
	return "DCClimatePassA(generator=%s)" % ("present" if _generator != null else "(null)")
