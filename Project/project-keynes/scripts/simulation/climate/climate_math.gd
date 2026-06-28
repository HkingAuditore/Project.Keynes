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

## ─── 纬度温度钟形曲线（全工程单一来源 / SAME_SOURCE 锚点）─────────────────
## "纬度 → 温度" 只有这一条公式：bell = cos(lat_signed·π/2)^LAT_TEMP_CURVE_EXP，
## 赤道(ny=0.5)=1、两极=0；指数越大高纬越冷。所有 GDScript 调用方
## （map_generator._compute_temperature / _ensure_row_tables、
##  map_data.bake_lat_temp_year_lut、map_baker 上升流光栅、
##  physical_circulation_solver._lat_temp_for）一律调用本函数，禁止再就地重写
## `pow(cos(...), ...)`。
##
## 跨语言镜像（无法共享同一份代码，改本常量值须人工同步并重编/重载）：
##   · C++    gdext/src/world_ext.cpp :: pk_lat_temp_bell / PK_LAT_TEMP_CURVE_EXP
##   · Shader shaders/include/climate_season.gdshaderinc :: lat_temp_bell / LAT_TEMP_CURVE_EXP
## 2026-06-16：1.2 → 1.6（调低极地温度、拓宽海冰带）。
## terrain-overhaul（2026-06-18）：1.6 → 1.3（拓宽温带带，恢复温带森林/草原纬度占比）。
const LAT_TEMP_CURVE_EXP: float = 1.3

## 纬度温度钟形（不含海拔惩罚）。lat_signed ∈ [-1, 1]；cos 为偶函数，传 |lat_signed| 等价。返回 [0, 1]。
static func lat_temp_bell(lat_signed: float) -> float:
	return pow(maxf(cos(lat_signed * PI * 0.5), 0.0), LAT_TEMP_CURVE_EXP)

## 由归一化纬度 ny ∈ [0, 1]（0=北极, 1=南极）算钟形。等价 lat_temp_bell((ny-0.5)*2)。
static func lat_temp_bell_from_ny(ny: float) -> float:
	return lat_temp_bell((ny - 0.5) * 2.0)


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


static func sunset_hour_angle(lat_rad: float, decl_rad: float) -> float:
	if absf(decl_rad) <= 0.000001:
		return PI * 0.5
	var polar_test: float = -tan(lat_rad) * tan(decl_rad)
	if polar_test <= -1.0:
		return PI
	if polar_test >= 1.0:
		return 0.0
	return acos(polar_test)


static func compute_day_length_norm(ny: float, season_phase: float,
		axial_tilt_deg: float = 23.5) -> float:
	var lat_rad: float = (clampf(ny, 0.0, 1.0) - 0.5) * PI
	var decl_rad: float = subsolar_lat_rad(season_phase, axial_tilt_deg)
	return clampf(sunset_hour_angle(lat_rad, decl_rad) / PI, 0.0, 1.0)


static func compute_daily_insolation(ny: float, season_phase: float,
		axial_tilt_deg: float = 23.5,
		_insolation_daylen_amp: float = 0.35) -> float:
	var lat_rad: float = (clampf(ny, 0.0, 1.0) - 0.5) * PI
	var subsolar: float = subsolar_lat_rad(season_phase, axial_tilt_deg)
	var h0: float = sunset_hour_angle(lat_rad, subsolar)
	if h0 <= 0.000001:
		return 0.0
	var daily: float = h0 * sin(lat_rad) * sin(subsolar) \
			+ cos(lat_rad) * cos(subsolar) * sin(h0)
	return clampf(daily, 0.0, 1.0)


static func compute_annual_insolation_mean(ny: float,
		axial_tilt_deg: float = 23.5,
		insolation_daylen_amp: float = 0.35,
		samples: int = 16) -> float:
	var count: int = maxi(1, samples)
	var acc: float = 0.0
	for s in range(count):
		var phase: float = (float(s) + 0.5) * (4.0 / float(count))
		acc += compute_daily_insolation(ny, phase, axial_tilt_deg, insolation_daylen_amp)
	return acc / float(count)


## 日射季节偏差：纯物理偏差 dev_abs = insol_now - insol_mean。
## 2026-06-16 物理化：删除旧的"极地放大/衰减"（先放大极区相对偏差、后又改成
## POLAR_SEASON_DAMP 衰减）——两者都是直接对 dev 动手脚的 band-aid。极地夏季过热
## 改由更物理的"吸收短波因子"在 season_offset 处处理（见 surface_absorbed_factor）：
## 冰雪高反照率反射极昼强日射 → 极夏自然变冷，并形成冰反照率正反馈。
## ny 不再参与（保留入参以稳定 SAME_SOURCE 签名与调用点）。
static func compute_insolation_dev_from_values(_ny: float, insol_now: float,
		insol_mean: float) -> float:
	return insol_now - insol_mean


## ─── 表面吸收短波因子（海陆/极地物理化 2026-06-16）────────────────────────
## 取代旧"极地放大/衰减"。物理依据：到达地表的日射只有 (1−反照率) 被吸收增温。
## 冰雪反照率高 → 极昼强日射大部分被反射 → 极地夏季自然变冷；并形成
## "冷→结冰→反照率升高→更冷"的自洽冰反照率正反馈。海洋反照率低于陆地→吸收更多
## （季节强迫更大），但其高热容（低 thermal_inertia_water）阻尼实际摆幅→大陆性对比。
##
## 该因子只缩放 season_offset（季节项），不动 cos^1.6 年均基线 → 反馈有下界、不失控。
## 归一化基准取无冰陆地 absorb_ref=(1−ALBEDO_LAND)，使无冰陆地 factor=1.0
## （中纬季节性完全不变、无需重调 insolation_season_gain）。
##
## 跨语言镜像（改这些常量须人工同步并重编/重载）：
##   · C++    gdext/src/world_ext.cpp :: pk_surface_absorbed_factor / PK_ALBEDO_*
##   · Shader shaders/include/climate_season.gdshaderinc :: insolation_season_offset_shader（纬度近似）
const ALBEDO_OCEAN: float = 0.08   # 开阔水面（低反照率，吸收多）
const ALBEDO_LAND: float = 0.20    # 一般陆地（归一化基准面）
const ALBEDO_ICE: float = 0.62     # 冰雪覆盖（高反照率，强反射）
const T_ICE_LO: float = 0.12       # 温度 ≤ 此值视为完全冰封（贴合海冰 form=0.14）
const T_ICE_HI: float = 0.30       # 温度 ≥ 此值视为无冰（贴合海冰 melt=0.22 之上）

## 归一化后的吸收短波因子：无冰陆地=1.0，海洋无冰≈1.15，冻结(海/陆)≈0.475。
## temp_annual 必须传【年均温度 temp_365d】（慢 EMA），不能传瞬时温度——否则
## "暖→脱冰→吸收增→更暖"会形成夏季融化正反馈，使极地夏季失控变热（实测峰值 0.43）。
## 用年均温度作"是否处于持久冰封气候"的代理：深极地年均温≈0.05 常年判定冰封 →
## 因子常年≈0.475 → 极地夏季被自然压低且稳定（夏峰 0.30→0.22，无失控）；
## 中纬年均温高 → 因子=1.0 → 季节性完全不变。
static func surface_absorbed_factor(is_water: bool, temp_annual: float) -> float:
	var a_base: float = ALBEDO_OCEAN if is_water else ALBEDO_LAND
	# ice_w：年均温度落入冻结带时升到 1（smoothstep 端点反序 → 冷=1, 暖=0）。
	var ice_w: float = smoothstep(T_ICE_HI, T_ICE_LO, temp_annual)
	var a_eff: float = a_base + (ALBEDO_ICE - a_base) * ice_w
	return (1.0 - a_eff) / (1.0 - ALBEDO_LAND)


## ─── 季节项冷侧软压缩（冬季过冷托底 物理化 v2 2026-06-16）──────────────────
## 物理依据：地球中/高纬冬季远比"纯局地辐射平衡"暖，因为大气与海洋的极向热量
## 输送（冬季最强）＋海洋/地表热库在持续向冬季半球释放储热。原"season_offset =
## 增益×dev"是纯局地线性强迫，缺这层托底 → 中纬冬季无限过冷（实测温带平原被压到
## 0=极寒，比极地还冷，不物理）。本函数对【降温侧】做 tanh 软饱和模拟该托底：
##   · 暖侧 s≥0（夏季/极昼）原样返回 → 完全保留季节性与极地夏季吸收因子效果；
##   · 冷侧 s<0 → −KNEE·tanh(|s|/KNEE)：|s| 小（春秋/低纬）几乎不变，
##     |s| 大（中高纬深冬）软饱和到约 −KNEE，不再无限变冷。
## KNEE=0.13：数值实验（tmp/verify_physical_temp_20260616.py §5）取得
##   温带平原冬季 min 0.087→0.21（叠加 pass_b 后≈0.13 严寒、脱离极寒），
##   夏季峰值不变，深极地海陆冬季仍冻结（海冰核与冰带不塌）。
## 跨语言镜像（改这些常量须人工同步并重编/重载）：
##   · C++    gdext/src/world_ext.cpp :: pk_compress_season_cooling / PK_WINTER_COOL_KNEE
##   · Shader shaders/include/climate_season.gdshaderinc :: insolation_season_offset_shader
const WINTER_COOL_KNEE: float = 0.13

static func compress_season_cooling(season_offset: float) -> float:
	if season_offset >= 0.0:
		return season_offset
	return -WINTER_COOL_KNEE * tanh(absf(season_offset) / WINTER_COOL_KNEE)


static func compute_insolation_dev(ny: float, season_phase: float,
		axial_tilt_deg: float = 23.5,
		insolation_daylen_amp: float = 0.35,
		samples: int = 16) -> float:
	var now_val: float = compute_daily_insolation(ny, season_phase, axial_tilt_deg, insolation_daylen_amp)
	var mean_val: float = compute_annual_insolation_mean(ny, axial_tilt_deg, insolation_daylen_amp, samples)
	return compute_insolation_dev_from_values(ny, now_val, mean_val)

