extends RefCounted
class_name DCTranspirationPass

## Phase E.5 / dots-full-migration §Phase E.5：植被→湿度反馈（蒸腾）抽出。
##
## **当前状态**：迁移规格 + facade 接口已定义；实际函数体仍在
## [`map_generator.gd`](../../geography/map_generator.gd) 待搬迁。
##
## ─── 逐函数搬迁清单 ───────────────────────────────────────────────
##
##   - `_apply_transpiration_pass(map)` — line 4890 (~50 行)
##     主要：
##       - 读 cell.vegetation 派生蒸腾系数（从 VegetationProfile.transpiration）
##       - 给邻居 cell.moisture +outflow_rate * 蒸腾系数
##       - 给自身 cell.moisture +self_rate * 蒸腾系数
##
## 配套配置（从 ClimateProfile 读，已存在）：
##   - transpiration_outflow_rate: float = 0.025
##   - transpiration_self_rate: float = 0.015
##   - veg_*_donor: float（每种植被的蒸腾贡献，9+ 个字段）
##
## ─── F.5 C++ 化路径（charter §7 目标 3.2ms → < 0.3ms）──────────────────
##
## C++ 实现：[`gdext/src/world_ext.cpp`](../../../../gdext/src/world_ext.cpp) 加
##   `run_transpiration_pass(donor_table, outflow_rate, self_rate)`
##
## donor_table 通过 PackedFloat32Array 传入（按 VegetationType.VEG enum 顺序，
## ~12 个 float），避免 hot loop 里反射 VegetationProfile。
##
## ─── 拆分原则 ────────────────────────────────────────────────────
##
## 1. 调用入口由 ClimateDailySystem._inner._run_pass(_PASS_TRANSP) 接管；
## 2. 写 cell.moisture（自身 + 6 邻居）；
## 3. 受 enable_local_climate_coupling flag 控制（与 climate Pass-B 同开关）；
## 4. donor_table 从 ClimateProfile 一次性派生（C++ pass 入参），不在 hot loop 查 Resource。

var _generator

func _init(generator) -> void:
	_generator = generator

func run(map: MapData) -> void:
	if _generator == null:
		return
	pass

func describe() -> String:
	return "DCTranspirationPass(generator=%s)" % ("present" if _generator != null else "(null)")
