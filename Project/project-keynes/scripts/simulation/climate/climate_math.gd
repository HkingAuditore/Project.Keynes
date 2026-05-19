extends RefCounted
class_name DCClimateMath

## Phase 3.3（master 手册 §6.4）：日照数学纯函数集合。
##
## **当前状态**：stub —— 函数定义待从 map_generator.gd 整体搬迁。
##
## 拆出原因：map_generator.gd 当前的 `_compute_insolation` / `_compute_seasonal_insolation` /
## `_compute_albedo` 等函数是纯数学（无 cell / map / world 状态依赖），
## 搬到独立类后：
##   1. pass_a / pass_b 搬迁不再跨文件依赖 map_generator 的私有函数
##   2. 单测可独立写（不需要 mock MapGenerator）
##   3. 与 wind_belt.gd 同源（都是纯静态数学）
##
## ─── 待搬迁函数清单（master 手册 §6.4 PR-3.3.1 候选）─────────────
##
## - `_compute_insolation(cell, season_phase) -> float`         (~30 行)
## - `_compute_seasonal_insolation(...) -> float`               (~30 行)
## - `_compute_solar_declination(season_phase) -> float`        (~10 行)
## - `_compute_subsolar_lat_norm(season_phase) -> float`        (~10 行)
## - `_compute_diurnal_factor(...) -> float`                    (~20 行)
## - `_compute_albedo(cover, terrain) -> float`                 (~20 行)
## - `_compute_specific_heat_capacity(landform) -> float`       (~10 行)
##
## ─── 拆分原则 ──────────────────────────────────────────────────
## 1. 全部为 static func，不持有内部状态。
## 2. 输入参数显式（不读 _last_cfg / _c() 等隐式上下文）。
## 3. caller 在 map_generator.gd 改为 `DCClimateMath.compute_insolation(...)` 一行替换。
## 4. 单测 tests/climate_math_test.gd 覆盖：
##    - solar_declination 边界值（春分 / 夏至 / 秋分 / 冬至）
##    - albedo 各 cover 类型查表
##    - insolation 高纬冬季 ≈ 0 / 赤道恒高
##
## 当前文件保留为占位；具体 static func 在 PR-3.3.1 引入。

## PR-3.3.1（M4 拆分）：从 map_generator.gd 迁出的纯数学 helper。
## 调用方在 map_generator.gd 改为 `DCClimateMath.compute_*(...)` 一行替换。

## subsolar_lat_rad —— 当前太阳直射点纬度（弧度）。
## Plan B 日历对齐：phase=0(1月) → +tilt（北半球冬至），phase=2(7月) → -tilt（北半球夏至）。
##
## 入参：
##   season_phase ∈ [0, 4)：年内相位
##   axial_tilt_deg：黄赤交角（默认地球 23.5°）
static func subsolar_lat_rad(season_phase: float, axial_tilt_deg: float = 23.5) -> float:
	var year_progress: float = fposmod(season_phase, 4.0) / 4.0
	return deg_to_rad(axial_tilt_deg) * cos(TAU * year_progress)

## compute_insolation —— 当前 cell 的瞬时日照量（归一化 [0, 1]）。
## 与 map_generator.gd::_compute_insolation 1:1 等价；输入显式化为 ny / season_phase /
## axial_tilt_deg / insolation_daylen_amp，不再隐式读 _c() 配置。
##
## 入参：
##   ny ∈ [0, 1]：归一化纬度（0=北极, 1=南极）
##   season_phase ∈ [0, 4)：年内相位
##   axial_tilt_deg：黄赤交角
##   insolation_daylen_amp：昼长调制振幅（typically 0.35）
static func compute_insolation(ny: float, season_phase: float,
		axial_tilt_deg: float = 23.5,
		insolation_daylen_amp: float = 0.35) -> float:
	var lat_rad: float = (ny - 0.5) * PI
	var subsolar: float = subsolar_lat_rad(season_phase, axial_tilt_deg)
	var cos_zenith: float = maxf(cos(lat_rad - subsolar), 0.0)
	var year_progress: float = fposmod(season_phase, 4.0) / 4.0
	var lat_sign: float = signf(lat_rad)
	# 2026-05-19 BUGFIX：原符号写反，导致南北半球季节响应反转
	# （北半球夏天结冰、南半球冬天结冰）。手算验证：
	#   7月 北纬45° (lat_rad=-π/4, lat_sign=-1)：cos(2π·year_progress)=cos(π)=-1
	#   正确（夏季昼长 > 1）：1 + 0.35·(-1)·(-1) = 1.35  ✓
	#   错误（旧式）：1 - 0.35·(-1)·(-1) = 0.65  ✗ 把夏天压成短日
	# 这条 daylen_factor 乘到 cos_zenith 上后，使得 dev = (now-mean)/mean 在中
	# 纬度区被压平甚至反相，最终 _insolation_season_offset 给出的温度偏移符号
	# 反过来。修正：sign 翻转 →  '1 + amp·cos·lat_sign'。
	# 极区端 cos_zenith 在极夜被 max(.,0) 截断为 0，所以旧 bug 主要影响中纬度。
	var daylen_factor: float = 1.0 + insolation_daylen_amp * cos(TAU * year_progress) * lat_sign
	return clampf(cos_zenith * daylen_factor, 0.0, 1.0)

