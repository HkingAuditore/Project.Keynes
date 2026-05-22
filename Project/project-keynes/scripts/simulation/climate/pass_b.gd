extends RefCounted
class_name DCClimatePassB

## Phase E.4 / dots-full-migration §Phase E.4：climate Pass-B 抽出（本类同时
## 是 F.3 C++ 化的承载点）。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`map_generator.gd`](../../geography/map_generator.gd) 待按下方"逐函数搬迁清单"
## 移过来。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
## 主入口：
##   - `_climate_pass_b(map, season_phase)`        — line 3303 (~20 行入口)
##   - `_climate_pass_b_soa(map, season_phase, cp)` — line 4197 (~250 行 SoA)
##   - `_apply_local_climate_coupling_pass(map, season_phase, winter_boost)`
##                                                  — line 3323 (~600 行 hot loop)
##
## 配套 helper（搬过来后从 generator 删除）：
##   - 邻居采样、风温耦合（搜 `_apply_air_mass_temp_anomaly` / 类似 helper）
##   - sparse 路径（use_sparse_climate=true 时的 dirty mask 处理）
##
## ─── F.3 C++ 化路径（charter §7 目标 5.2ms → < 0.5ms）──────────────────
##
## C++ 实现：[`gdext/src/world_ext.cpp`](../../../../gdext/src/world_ext.cpp) 加
##   `run_climate_pass_b(cp_struct, phase, season_phase)`
## 与已有 `run_climate_pass_a` 同形（charter §12.3.1 模板）。
##
## flag：`ClimateProfile.use_gdext_climate_pass_b` 已于 dots-flag-prune-pr1 (2026-05-22)
## 删除。切换路径现走 ext.has_method("run_climate_pass_b") 探测，按默认 enable。
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 与 Pass-A 一样，调用入口由 ClimateDailySystem 接管；
## 2. 写 cell.moisture / cell.air_mass_temp_anomaly 必须在
##    ClimateDailySystem.declare_writes 内（已在 C.3 声明）；
## 3. 受 `enable_local_climate_coupling` flag 控制；为 false 时跳过本 pass；
## 4. F.3 之后在 dots_gdscript fallback 路径仍由本类承载；dots_cpp 路径走
##    DCWorldExt::run_climate_pass_b。

var _generator

func _init(generator) -> void:
	_generator = generator

## 主入口：跑 Pass-B。
func run(map: MapData, season_phase: float) -> void:
	if _generator == null:
		return
	# Future: switch by ext.has_method("run_climate_pass_b") / cp.use_soa_pipeline (use_gdext_climate_pass_b removed in dots-flag-prune-pr1)
	pass

func describe() -> String:
	return "DCClimatePassB(generator=%s)" % ("present" if _generator != null else "(null)")
