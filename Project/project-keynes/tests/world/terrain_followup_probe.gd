extends SceneTree

# ─────────────────────────────────────────────────────────────────────────────
# terrain_followup_probe.gd — 地形两计划跟进 §5「归因排查实验」诊断探针
#
# 规格：docs/plans/terrain-followup-verification-plan.md §5.1–§5.5
#      docs/plans/terrain-followup-verification-checklist.md §4（S4.1–S4.5）
# 定位：**只做诊断，不改任何生成默认值**。本文件是这一步唯一新增物：
#      不改 C++、不改 climate_profile.gd / native bridge、不改既有测试、不改 docs。
#
# 跑法（由 lead 统一编译 + 执行；本文件**不**自行启动 Godot / scons）：
#   $env:FOLLOWUP_EXP="m1prime"
#   godot --headless -s res://tests/world/terrain_followup_probe.gd
#   也接受用户参数：godot --headless -s res://tests/world/terrain_followup_probe.gd -- iters
#
# FOLLOWUP_EXP 取值（一次只跑一个，5 个实验互不依赖）：
#   m1prime  — 实验 A（§5.1）：M1' = 脊顶在分水岭上的比例 + 随机陆地格零假设
#   iters    — 实验 B（§5.2）：spl_iters = 14/28/40（抬升按 14/iters 等比缩小，总抬升量不变）
#   highland — 实验 C（§5.3）：river_headwater 阈值副作用 4 行表（「旧」列留 old=?）
#   k_scale  — 实验 D（§5.4）：像素层 A_hex 量级 + dem_spl_k 手算校验（需要 bake pass）
#   m5shape  — 实验 E（§5.5）：M5a 顶部曲率集中度 / M5b 平坦面积比
#
# 产出：每个实验结束写 res://tmp/followup/<exp>/result.json，并打印 `[followup/<exp>]` 行。
#      退出码：0 = 跑完（含 SKIP）；1 = 硬失败（无 DCWorldExt / 生成全挂 / 写盘失败）。
#
# ── 与既有测试的关系（不重复实现，也不假装一致）─────────────────────────────
#   · cfg / profile / 种子：与 tests/world/ridge_drainage_metrics_test.gd 的
#     `_cfg()` / `_profile()` / `_seeds()` **同源同值**（contracts §D-1 的代表性 profile），
#     保证与基线可比；profile 只按实验需要**覆盖**（B 的 spl_iters 与抬升等比缩放、
#     C 的 river_headwater_* 显式化、D 的额外 bake knobs）。
#   · **不复制**那个文件 1400 行的指标引擎：本探针只自带
#       ① 6 邻表（与 world_ext_generate_base.cpp 的 DQ/DR / index_for_qr 逐字一致）；
#       ② trace_outlet / 上游格数（沿 post_base 给出的 hydro_parent_arr）；
#       ③ 平均秩 Spearman（旧 M1 的**代理**口径，见实验 A）；
#       ④ Barnes Priority-Flood（只为实验 B 的 M2 洼地数，判据与基线测试同定义）。
#     真正权威的 M1/M2/M3/M4/M5 仍由 ridge_drainage_metrics_test.gd 定义，本文件不替代它。
#   · 旧 M1 = Spearman(ridge_add, log A) 里的 A 是「Priority-Flood 填洼面 + 最陡受体」的汇水面积。
#     本探针不重建那套排水网，改用 up_count（上游格数，见 world_ext_generate.cpp:1125-1133）
#     作 A 的代理，并明确标注 `M1_old_proxy`；**旧口径的绝对数值请以 ridge_drainage_metrics_test
#     的 M1 为准**，本探针只用于「同一 DLL 内 A/B 对照的方向与量级」。
#
# ── 数据来源（全部已存在，不需要新编译）─────────────────────────────────────
#   base pass（profile.ridge_debug_dump=1）：elevation_arr / ridge_add_arr（F32, n）
#                                           terrain_arr / landform_arr（U8, n）
#   post_base：hydro_parent_arr（I32, n，沿它追到 <0 即出口）、has_river_arr（U8, n）、
#              is_water_arr（U8, n）、river_flow_arr（F32, n）、elevation_arr、terrain_arr、
#              landform_arr、river_count、lake_count、highland_river_count、peak_count、
#              plateau_count、river_headwater_init_effective、river_channel_init_effective
#   bake pass（knobs.dem_erosion_area_dump=true）：area_hex_buffer（F32, 像素数，单位 hex²）、
#              height_buffer（侵蚀后）、procedural_height_buffer（侵蚀前）、biome_buffer、
#              flow_buffer（河心 flow >= dem_valley_river_outlet_flow 的像素 = 汇流出口）
#
# ── 两个容易混淆的 land_h 口径（本文件分别命名，不混用）────────────────────
#   · `land_h      = elevation − sea_level`：与 ridge_drainage_metrics_test 的 land_p50/p90
#     以及计划里「大图 p50 下降 16%」那组数字同口径 ⇒ 实验 A/B/E 的分布统计用它。
#   · `land_h_norm = (elevation − sea_level) / (1 − sea_level)`：与 C++ 侧
#     world_ext_generate.cpp:810 的 land_h() 逐字同式，`river_headwater_min_land_h`（0.30）
#     作用在**这个**口径上 ⇒ 实验 C 的阈值行必须用它，否则会算出错的数量级。
#
# ── 6 邻约定（与生成器逐字一致）──────────────────────────────────────────────
#   index = row * width + col（offset 坐标），DQ/DR 见常量；东西经度环绕（col 用 posmod
#   绕回），南北（row）越界返回 −1。与 world_ext_generate_base.cpp:490 与
#   ridge_drainage_metrics_test.gd::_neighbor_table() 完全一致。
# ─────────────────────────────────────────────────────────────────────────────

# ── 种子 / 尺寸（与 ridge_drainage_metrics_test 的 SEED_BASE 同源）─────────────
const SEED_BASE := 20260718
const W_SMALL := 60
const H_SMALL := 40
const W_LARGE := 200
const H_LARGE := 150
# 实验 A/C/E：2 个 60×40 + 1 个 200×150；B：1 个 60×40；D：1 个 60×40（desktop 像素档）。
const N_SMALL_MAPS := 2
const N_LARGE_MAPS := 1

const OUT_ROOT := "res://tmp/followup"

const SEA_FALLBACK := 0.64      # 与 _cfg() 的 sea_level / 基线测试 SEA_FALLBACK 同值
const PIT_EPS := 1.0e-6         # 契约 §C：填洼面 > 原面 + 1e-6 判为 pit（与基线测试同）
const MIN_SAMPLE := 8           # 样本 < 8 不下结论（与基线测试同）

# 水体地形码：镜像 world_ext_internal.h:306 pk_is_water_terrain {0,1,18,19,20,21}。
const WATER_TERRAIN := [0, 1, 18, 19, 20, 21]
# 高地地貌码：镜像 world_ext_generate.cpp:2735 highland_river_count 的 {6,7,8,13}
# （HILL / MOUNTAIN / PEAK / PLATEAU，见 scripts/geography/landform_type.gd）。
const HIGHLAND_LF := [6, 7, 8, 13]

# ── 实验 A / B 的 M1' 口径 ───────────────────────────────────────────────────
const RIDGE_P75 := 0.75         # 脊顶门槛：陆地 ridge_add 的 p75（numpy 线性插值口径）
const ZERO_HYP_SEED_MUL := 1000003   # 零假设抽样 RNG 的种子 = seed * 该常数 + n（可复现）

# ── 实验 B：spl_iters 扫描 ───────────────────────────────────────────────────
# 抬升等比缩小：让「总抬升量 ≈ 每轮抬升 × 轮数」近似不变。
#   spl_ridge_uplift(iters) = 0.03 × 14/iters
#   spl_uplift_rate(iters)  = 0.08 × 14/iters
# 0.03 / 0.08 取自 ridge_drainage_metrics_test.gd::_profile()（P5 标定值）。
const ITERS_LIST := [14, 28, 40]
const ITERS_REF := 14
const SPL_RIDGE_UPLIFT_BASE := 0.03
const SPL_UPLIFT_RATE_BASE := 0.08

# ── 实验 C：river_headwater 阈值（profile 键，C++ 缺省见 world_ext_generate.cpp:523-524）──
const RIVER_HEADWATER_MIN_LAND_H := 0.30
const RIVER_HEADWATER_INIT_CELLS := 10

# ── 实验 D：desktop 烘焙几何（镜像 MapBaker / TerrainBaker / TerrainIndexBaker）─────
# 世界几何 world_bounds：surface_baker.gd:848 compute_world_bounds()
#   px = √3·hex_size·(w + 0.5)，py = 1.5·hex_size·h + 0.5·hex_size，外扩 4·hex_size
# 像素分辨率：terrain_baker.gd:459 _resolve_hm_size()，desktop 档长边 1024（map_baker.gd:37）。
const HEX_SIZE_DEFAULT := 22.0        # main.gd `@export var hex_size: float = 22.0`
const HM_MAX_DIM_DESKTOP := 1024      # MapBaker.HM_MAX_DIM_DESKTOP（map_baker.gd:37）
# 融合 pass 的其余生产 knob（map_baker.gd:421-453 + terrain_baker.gd:547-586）。
const RIVER_STROKE_HEX_FACTOR := 0.048
const SDF_MAX_DIST_PX := 3.5
const RIVER_CR_STEP := 12
const SHORE_CARVE_AMP := 0.06
const SHORE_CARVE_BAND := 6
const COAST_SDF_MAX_DIST_PX := 8.0
const EROSION_DROPS := 6000
const EROSION_MAX_STEPS := 5
const EROSION_INERTIA := 0.10
const EROSION_CAPACITY_FACTOR := 1.5
const EROSION_MIN_CAPACITY := 0.01
const EROSION_DEPOSIT_SPEED := 0.30
const EROSION_ERODE_SPEED := 0.10
const EROSION_EVAPORATION := 0.025
const EROSION_GRAVITY := 4.0
const EROSION_RADIUS := 2
# 河心像素判定：与融合 pass 自己构造 wet 集合的条件同值（world_ext_bake.cpp:1505）。
const RIVER_OUTLET_FLOW := 0.6
# 侵蚀/地形 knobs：与 scripts/rendering/bakers/terrain_index_baker.gd:74-146 的 DEM_DEFAULTS 同值。
# 走 ProjectSettings `project_keynes/rendering/dem/<去 dem_ 前缀>` 读，缺省即生产缺省 —— 不直连
# DCTerrainIndexBaker（避免为读一张表 preload 整个 baker 栈），语义与其 dem_landform_knobs() 相同。
const DEM_KNOB_DEFAULTS := {
	"dem_relief_lo": 0.006,
	"dem_relief_hi": 0.120,
	"dem_relief_cap": 0.25,
	"dem_ridge_amp_per_relief": 0.55,
	"dem_ridge_wavelength_hex": 2.4,
	"dem_ridge_crest_exp": 2.2,
	"dem_mountain_relief_floor": 0.055,
	"dem_peak_relief_floor": 0.080,
	"dem_amp_per_relief": 0.1,
	"dem_base_wavelength_hex": 1.0,
	"dem_octaves": 4,
	"dem_gain_wet": 0.48,
	"dem_gain_dry": 0.62,
	"dem_ridge_gain": 0.40,
	"dem_valley_depth_per_relief": 1.4,
	"dem_valley_wall_per_relief": 5.0,
	"dem_valley_area_lo": 8.0,
	"dem_valley_area_hi": 4000.0,
	"dem_valley_depth_exp": 0.8,
	"dem_valley_mfd_exponent": 6.0,
	"dem_valley_river_outlet_flow": 0.6,
	"dem_erosion_mode": "spl",
	"dem_erosion_max_dim": 1024,
	"dem_spl_iters": 6,
	"dem_spl_k": 0.50,
	"dem_spl_m": 0.45,
	"dem_spl_min_area_hex": 0.03,
	"dem_slope_limit_per_relief": 5.0,
	"dem_slope_limit_relief_floor": 0.04,
	"dem_slope_limit_cap_per_relief": 1.4,
	"dem_crest_round": 0.0,
	"dem_dep_enabled": false,
	"dem_dep_kc": 0.02,
	"dem_dep_rate": 0.5,
	"dem_dep_min_area_hex": 0.5,
	"dem_floor_widen": false,
	"dem_floor_width_hex": 0.04,
	"dem_floor_slope": 0.002,
	"dem_floor_min_area_hex": 2.0,
	"dem_spl_carve_scale": 0.40,
	"dem_erosion_pit_audit": false,
}
const DEM_SETTING_PREFIX := "project_keynes/rendering/dem/"
# 计划 §4.2 的量级假设：干流 A_hex ≈ 100。实验 D 要验证真实分布离它多远。
const A_HEX_PLANNED := 100.0

# ── 实验 E：M5a / M5b ───────────────────────────────────────────────────────
const M5_HIGHLAND_PCT := 0.90   # 高地 = 陆地 land_h ≥ p90（计划 §5.5）
const M5_MIN_COMP := 5          # 连通块最小格数：小块（1–4 格）噪声大，不入统计但会打印计数
const M5_TOP_FRAC := 0.20       # 「块内 E 最高 20% 格」
# M5b 的 ε：**浮动阈值**，ε = M5B_EPS_FRAC × (该图陆地 land_h 的 p99)。
# 理由：Laplacian 与坡度都以归一化高度/格为单位，绝对阈值会随图幅高度整体漂移；用本图
# 陆地高度尺度（p99）的 2% 作 ε，等价于「高差小于约 1/50 个陆地高度跨度」才算平。
# 0.02 为主判据，另跑 0.01 / 0.04 作敏感性；三个值都落盘，避免「阈值凑结论」。
const M5B_EPS_FRAC := 0.02
const M5B_EPS_SWEEP := [0.01, 0.02, 0.04]
const PLATEAU_RELIEF := 0.02    # 旧 M5_p90 的局地起伏阈值（与基线测试 PLATEAU_RELIEF 同值）

# 堆 / 秩打包用的标度（只影响排序键，不参与任何指标数值）
const LEVEL_SCALE := 1073741824.0    # 2^30
const LEVEL_SHIFT := 1048576         # 2^20：下标占低 20 位（n <= 30000 < 2^20）
const INDEX_MASK := 1048575          # 2^20 − 1
const RANK_SCALE := 1099511627776.0  # 2^40

# D6 邻接方向：与 world_ext_generate_base.cpp:490 的 DQ/DR 逐字一致。
const DQ := [1, 1, 0, -1, -1, 0]
const DR := [0, -1, -1, 0, 1, 1]

# 未解析标记：outlet/dist 用 −2 表示「还没追过」，−1 表示「链异常/无出口」。
const UNRESOLVED := -2

var _ext: Object = null
var _exp := ""
var _out_dir := ""
var _hard_fail := 0
var _skips: Array = []
var _notes: Array = []
var _heap: PackedInt64Array = PackedInt64Array()
var _heap_n := 0


func _init() -> void:
	_exp = _resolve_exp()
	var exp_label := _exp if _exp != "" else "(none)"
	print("[followup] exp=%s godot=%s" % [exp_label,
			str(Engine.get_version_info().get("string", "?"))])
	if _exp == "":
		_usage()
		quit(2)
		return
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[followup] DCWorldExt 不可用（DLL 未编入 / 未加载？）")
		quit(1)
		return
	_ext = ClassDB.instantiate("DCWorldExt")
	if _ext == null:
		push_error("[followup] DCWorldExt 不可实例化")
		quit(1)
		return
	_out_dir = "%s/%s" % [OUT_ROOT, _exp]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	var res: Dictionary = {}
	match _exp:
		"m1prime":
			res = _exp_m1prime()
		"iters":
			res = _exp_iters()
		"highland":
			res = _exp_highland()
		"k_scale":
			res = _exp_k_scale()
		"m5shape":
			res = _exp_m5shape()
		_:
			_usage()
			quit(2)
			return
	res["exp"] = _exp
	res["skips"] = _skips
	res["notes"] = _notes
	res["generated_utc"] = Time.get_datetime_string_from_system(true)
	res["godot"] = str(Engine.get_version_info().get("string", "?"))
	res["hard_fail"] = _hard_fail
	_write_json("%s/result.json" % _out_dir, res)
	print("[followup/%s] done skips=%d hard_fail=%d result=%s/result.json"
			% [_exp, _skips.size(), _hard_fail, _out_dir])
	quit(0 if _hard_fail == 0 else 1)


func _resolve_exp() -> String:
	var e := OS.get_environment("FOLLOWUP_EXP").strip_edges().to_lower()
	if e != "":
		return e
	for arg in OS.get_cmdline_user_args():
		var a := str(arg).strip_edges().to_lower()
		if a == "m1prime" or a == "iters" or a == "highland" or a == "k_scale" or a == "m5shape":
			return a
	return ""


func _usage() -> void:
	print("[followup] 用法：$env:FOLLOWUP_EXP=\"<name>\"; godot --headless -s res://tests/world/terrain_followup_probe.gd")
	print("[followup] <name> ∈ {m1prime, iters, highland, k_scale, m5shape}（一次跑一个）")


# ═════════════════════════════════════════════════════════════════════════════
# 生成链路：base → post_base（→ 实验 D 再走 bake）。全部走真实原生生成，不造数据。
# ═════════════════════════════════════════════════════════════════════════════

# cfg / profile 与 tests/world/ridge_drainage_metrics_test.gd 的 _cfg()/_profile() 同源同值
# （contracts §D-1 的代表性 profile）；本函数只做 `extra` 覆盖，不新增未知键。
func _cfg(seed_v: int, w: int, h: int) -> Dictionary:
	return {
		"num_continents": 3,
		"continent_size": 0.9,
		"sea_level": SEA_FALLBACK,
		"river_count": 12,
		"width": w,
		"height": h,
		"seed": seed_v,
	}


func _profile(extra: Dictionary = {}) -> Dictionary:
	var p := {
		"native_generation_mode": 2,
		"ridge_boost_amp": 0.60,
		"spl_iters": 14,
		"spl_erodibility": 1.2,
		"spl_area_exp": 0.45,
		"spl_uplift_rate": SPL_UPLIFT_RATE_BASE,
		"spl_ridge_uplift": SPL_RIDGE_UPLIFT_BASE,
		"spl_hillslope_diffusion": 0.08,
		"ridge_residual_frac": 0.15,
		"ridge_debug_dump": 1,
	}
	for key in extra:
		p[key] = extra[key]
	return p


# 生成一张图：base → post_base。
# 返回 {"ok", "reason", "base", "post", "base_ms", "post_ms", "cfg", "profile", "w", "h", "seed"}
func _generate(seed_v: int, w: int, h: int, profile: Dictionary) -> Dictionary:
	var cfg := _cfg(seed_v, w, h)
	var t0 := Time.get_ticks_usec()
	var base_v = _ext.call("run_native_world_generate_base_pass", seed_v, cfg, profile)
	var base_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var out := {"ok": false, "reason": "", "base": {}, "post": {},
		"base_ms": base_ms, "post_ms": -1.0, "cfg": cfg, "profile": profile,
		"w": w, "h": h, "seed": seed_v}
	if typeof(base_v) != TYPE_DICTIONARY:
		# 方法未导出 / call 失败时 Object.call 返回 null：别让它把类型化赋值搞崩。
		out["reason"] = "run_native_world_generate_base_pass 未返回 Dictionary（方法未导出？）"
		return out
	var base: Dictionary = base_v
	out["base"] = base
	if int(base.get("rc", -1)) != 0 or bool(base.get("fallback", true)):
		out["reason"] = "base rc=%s fallback=%s reason=%s" % [
			str(base.get("rc", "?")), str(base.get("fallback", "?")),
			str(base.get("reason", "?"))]
		return out
	var t1 := Time.get_ticks_usec()
	var post_v = _ext.call("run_native_world_generate_post_base_pass",
			seed_v, cfg, profile, base)
	out["post_ms"] = float(Time.get_ticks_usec() - t1) / 1000.0
	if typeof(post_v) != TYPE_DICTIONARY:
		out["reason"] = "run_native_world_generate_post_base_pass 未返回 Dictionary（方法未导出？）"
		return out
	var post: Dictionary = post_v
	out["post"] = post
	if bool(post.get("fallback", true)):
		out["reason"] = "post_base fallback reason=%s" % str(post.get("reason", "?"))
		return out
	out["ok"] = true
	return out


func _land_mask(elev: PackedFloat32Array, sea: float, n: int) -> PackedByteArray:
	# 陆地 = elevation >= sea_level：与 ridge_drainage_metrics_test 的 land 掩码同口径。
	var land := PackedByteArray()
	land.resize(n)
	land.fill(0)
	for i in range(n):
		if float(elev[i]) >= sea:
			land[i] = 1
	return land


func _is_water_code(t: int) -> bool:
	for c in WATER_TERRAIN:
		if t == int(c):
			return true
	return false


func _is_highland_code(t: int) -> bool:
	for c in HIGHLAND_LF:
		if t == int(c):
			return true
	return false


# ═════════════════════════════════════════════════════════════════════════════
# 小工具：分位 / 平均秩 Spearman / 6 邻表
# ═════════════════════════════════════════════════════════════════════════════

# D6 邻接表：nbr[i*6+d] = 邻居下标（−1 = 无）。与 world_ext_generate_base.cpp:
# index_for_qr / DQ / DR 逐字一致（东西环绕、南北硬边界）。
func _neighbor_table(w: int, h: int) -> PackedInt32Array:
	var n := w * h
	var nbr := PackedInt32Array()
	nbr.resize(n * 6)
	nbr.fill(-1)
	for r in range(h):
		var half := (r - (r & 1)) / 2
		for col in range(w):
			var q := col - half
			var base := (r * w + col) * 6
			for d in range(6):
				var nr: int = r + int(DR[d])
				if nr < 0 or nr >= h:
					continue
				var ncol: int = q + int(DQ[d]) + ((nr - (nr & 1)) / 2)
				ncol = ((ncol % w) + w) % w
				nbr[base + d] = nr * w + ncol
	return nbr


# numpy 口径的线性插值分位（values 必须已升序）。
func _percentile(values: PackedFloat32Array, q: float) -> float:
	var m := values.size()
	if m == 0:
		return NAN
	if m == 1:
		return float(values[0])
	var pos := float(m - 1) * q
	var lo := int(floor(pos))
	if lo < 0:
		lo = 0
	if lo > m - 2:
		lo = m - 2
	var frac := pos - float(lo)
	return float(values[lo]) + (float(values[lo + 1]) - float(values[lo])) * frac


# 平均秩 Spearman（并列取平均位次）。写法与 ridge_drainage_metrics_test.gd::_spearman 同构：
# 把「值量化 × 2^40 × m + 下标」打包成 int64 → 一次原生 sort() → 线性走等值区段取平均位次。
# 为什么必须平均秩：log10(A) 在 A=1…3 上大量并列，序号秩会按数组顺序硬编号，跨实现不可比。
func _spearman(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var m := a.size()
	if m < MIN_SAMPLE or b.size() != m:
		return NAN
	var rx := _average_ranks(a)
	var ry := _average_ranks(b)
	var mean := float(m - 1) * 0.5
	var cov := 0.0
	var vx := 0.0
	var vy := 0.0
	for i in range(m):
		var dx := rx[i] - mean
		var dy := ry[i] - mean
		cov += dx * dy
		vx += dx * dx
		vy += dy * dy
	if vx <= 0.0 or vy <= 0.0:
		return NAN
	return cov / sqrt(vx * vy)


func _average_ranks(values: PackedFloat64Array) -> PackedFloat64Array:
	var m := values.size()
	var keys := PackedInt64Array()
	keys.resize(m)
	for i in range(m):
		var v := values[i]
		if v < 0.0:
			v = 0.0
		if v > 100.0:
			v = 100.0
		keys[i] = int(v * RANK_SCALE + 0.5) * m + i
	keys.sort()
	var ranks := PackedFloat64Array()
	ranks.resize(m)
	var pos := 0
	while pos < m:
		var bucket := keys[pos] / m
		var end := pos + 1
		while end < m and keys[end] / m == bucket:
			end += 1
		var avg := (float(pos) + float(end - 1)) * 0.5
		for k in range(pos, end):
			ranks[int(keys[k] % m)] = avg
		pos = end
	return ranks


# ═════════════════════════════════════════════════════════════════════════════
# 排水拓扑（只依赖 post_base 的 hydro_parent_arr，不重建 Priority-Flood 排水网）
# ═════════════════════════════════════════════════════════════════════════════

# 沿 hydro_parent 追到 <0（出口）→ 返回 [outlet, dist]：
#   outlet[i] = 出口格下标（−1 = 链异常/无出口；−2 在返回后不会出现）
#   dist[i]   = 到出口的步数（出口自己 = 0）
# 用路径压缩 + 回填：每个格只会被 append 进 path 一次，总代价 O(n)。
func _drainage_walk(parent: PackedInt32Array, n: int) -> Array:
	var outlet := PackedInt32Array()
	outlet.resize(n)
	outlet.fill(UNRESOLVED)
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(-1)
	var path := PackedInt32Array()
	var guard_bad := 0
	for start in range(n):
		if outlet[start] != UNRESOLVED:
			continue
		path.resize(0)
		var cur := start
		var o := -1
		var d := 0
		var guard := 0
		while true:
			if cur < 0 or cur >= n:
				o = -1
				d = 0
				break
			if outlet[cur] != UNRESOLVED:
				o = outlet[cur]
				d = dist[cur]
				break
			var p: int = int(parent[cur])
			if p < 0 or p == cur:
				# cur 自身是出口：先给自己定值，再沿 path 回填（cur 不入 path）。
				outlet[cur] = cur
				dist[cur] = 0
				o = cur
				d = 0
				break
			path.append(cur)
			guard += 1
			if guard > n:
				# 成环（正常 hydro_parent 不会有）：整链落 −1，别死循环。
				o = -1
				d = 0
				guard_bad += 1
				break
			cur = p
		for k in range(path.size() - 1, -1, -1):
			d += 1
			var idx := path[k]
			outlet[idx] = o
			dist[idx] = d
	if guard_bad > 0:
		_notes.append("drainage_walk: %d 条链成环，已按 outlet=-1 处理" % guard_bad)
	return [outlet, dist]


# 分水岭格 = 存在邻格 j，其出口与本格不同（计划 §5.1 字面口径）。返回两个掩码：
#   [0] ws_all  : 6 邻**全部**参与比较 —— 计划字面口径。
#   [1] ws_land : 只比较**陆地**邻格 —— 去掉「沿海格」伪分水岭。
# 为什么需要 ws_land：出口处水体格的 hydro_parent < 0（出口 = 自己），于是海岸陆地格的
# 出口是它排入的那一个水体格，而它旁边**别的**海水格出口是它们自己 —— 两者出口天然不同，
# 于是几乎每个海岸陆地格都会被字面口径判成「分水岭」。脊顶格多为内陆高点，受影响很小，
# 但零假设抽样的随机陆地格里海岸格不少 ⇒ 字面口径会把零假设抬高、把差值压低（保守偏差）。
# 故主判据用 ws_land，同时把 ws_all（计划字面）一并落盘，两者都可见。
func _watershed_flags(outlet: PackedInt32Array, nbr: PackedInt32Array, n: int,
		land: PackedByteArray) -> Array:
	var ws_all := PackedByteArray()
	ws_all.resize(n)
	ws_all.fill(0)
	var ws_land := PackedByteArray()
	ws_land.resize(n)
	ws_land.fill(0)
	for i in range(n):
		var base_i := i * 6
		var oi := outlet[i]
		for d in range(6):
			var j := nbr[base_i + d]
			if j < 0:
				continue
			if outlet[j] != oi:
				ws_all[i] = 1
				if land[j] != 0:
					ws_land[i] = 1
				break
	return [ws_all, ws_land]


# 拓扑自检：dist==0 的格 = 出口。若过半格都是自己的出口，说明 hydro_parent 基本全是 −1
# （拓扑没导出），此时「分水岭比例」恒 ≈1、up_count 恒 1 —— 指标无意义，要 SKIP 而不是当成结果。
func _drainage_ok(dist: PackedInt32Array, n: int) -> bool:
	var zero := 0
	for i in range(n):
		if dist[i] <= 0:
			zero += 1
	return zero * 2 <= n


# 升序 dist 的下标序（计数排序）。降序遍历它 = 合法「上游先」拓扑序。
func _order_by_dist(dist: PackedInt32Array, n: int) -> PackedInt32Array:
	var max_d := 0
	for i in range(n):
		var dv: int = dist[i]
		if dv > max_d:
			max_d = dv
	var cnt := PackedInt32Array()
	cnt.resize(max_d + 2)
	cnt.fill(0)
	for i in range(n):
		var dv: int = dist[i]
		if dv < 0:
			dv = 0
		cnt[dv] += 1
	var off := PackedInt32Array()
	off.resize(max_d + 2)
	off.fill(0)
	var acc := 0
	for d in range(max_d + 1):
		off[d] = acc
		acc += cnt[d]
	var order := PackedInt32Array()
	order.resize(n)
	for i in range(n):
		var dv: int = dist[i]
		if dv < 0:
			dv = 0
		order[off[dv]] = i
		off[dv] += 1
	return order


# 上游格数 up_count：**与 world_ext_generate.cpp:1125-1133 同定义** ——
# 陆地格初值 1、水体 0，沿 hydro_parent 向父累加。用 dist 降序（= 上游先）保证一遍收敛。
func _up_count(parent: PackedInt32Array, dist: PackedInt32Array, n: int,
		land: PackedByteArray) -> PackedInt32Array:
	var order := _order_by_dist(dist, n)
	var up := PackedInt32Array()
	up.resize(n)
	up.fill(0)
	for i in range(n):
		if land[i] != 0:
			up[i] = 1
	for k in range(n - 1, -1, -1):
		var i := order[k]
		if up[i] == 0:
			continue
		var p := int(parent[i])
		if p < 0 or p >= n or p == i:
			continue
		up[p] += up[i]
	return up


# ═════════════════════════════════════════════════════════════════════════════
# Barnes Priority-Flood（2014）：只为实验 B 的 M2 洼地数。
# 与 ridge_drainage_metrics_test.gd::_priority_flood 同判据（种子 = 南北两行、不加 ε、
# 平局按 idx 定序）；本文件不落盘填洼面，只数 pit 格，故省掉 proc 数组。
# ═════════════════════════════════════════════════════════════════════════════

func _pit_count_pf(elev: PackedFloat32Array, nbr: PackedInt32Array,
		w: int, h: int, sea: float) -> int:
	var n := w * h
	if elev.size() != n:
		return -1
	var filled := elev.duplicate()
	var seen := PackedByteArray()
	seen.resize(n)
	seen.fill(0)
	_heap = PackedInt64Array()
	_heap.resize(n + 1)
	_heap_n = 0
	var rows := [0]
	if h > 1:
		rows.append(h - 1)
	for row in rows:
		var r0: int = row
		for col in range(w):
			var i: int = r0 * w + col
			if seen[i] != 0:
				continue
			seen[i] = 1
			_heap_push(_pack(_level_scaled(float(filled[i])), i))
	while _heap_n > 0:
		var key := _heap_pop()
		var cur := key & INDEX_MASK
		var fc := float(filled[cur])
		var base_i := cur * 6
		for d in range(6):
			var ni := nbr[base_i + d]
			if ni < 0 or seen[ni] != 0:
				continue
			seen[ni] = 1
			if float(filled[ni]) < fc:
				filled[ni] = fc
			_heap_push(_pack(_level_scaled(float(filled[ni])), ni))
	var pits := 0
	for i in range(n):
		if float(elev[i]) >= sea and float(filled[i]) > float(elev[i]) + PIT_EPS:
			pits += 1
	return pits


func _level_scaled(v: float) -> float:
	return v * LEVEL_SCALE


func _pack(level_scaled: float, idx: int) -> int:
	return int(level_scaled) * LEVEL_SHIFT + idx


func _heap_push(key: int) -> void:
	var i := _heap_n
	_heap_n += 1
	while i > 0:
		var p := (i - 1) >> 1
		if _heap[p] <= key:
			break
		_heap[i] = _heap[p]
		i = p
	_heap[i] = key


func _heap_pop() -> int:
	var top := _heap[0]
	_heap_n -= 1
	var last := _heap[_heap_n]
	if _heap_n > 0:
		var i := 0
		while true:
			var l := (i << 1) + 1
			if l >= _heap_n:
				break
			var r := l + 1
			var c := l
			if r < _heap_n and _heap[r] < _heap[l]:
				c = r
			if last <= _heap[c]:
				break
			_heap[i] = _heap[c]
			i = c
		_heap[i] = last
	return top


# ═════════════════════════════════════════════════════════════════════════════
# 输出 / 格式化
# ═════════════════════════════════════════════════════════════════════════════

func _skip(tag: String, reason: String) -> void:
	_skips.append({"tag": tag, "reason": reason})
	print("[followup] %s: SKIP reason=%s" % [tag, reason])


func _num(v: float) -> Variant:
	# JSON 里 NaN/INF 不是合法值：统一落 null（与基线测试 _num 同义）。
	if is_nan(v) or not is_finite(v):
		return null
	return v


func _fmt(v) -> String:
	if v == null:
		return "n/a"
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return "%.4f" % float(v)
	return str(v)


func _write_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if f == null:
		push_error("[followup] 无法写入 %s" % path)
		_hard_fail += 1
		return
	f.store_string(JSON.stringify(data, "  ", false))
	f.close()


func _mean_of(rows: Array, field: String) -> float:
	var s := 0.0
	var c := 0
	for r in rows:
		var v = r.get(field, null)
		if v == null:
			continue
		s += float(v)
		c += 1
	if c == 0:
		return NAN
	return s / float(c)


func _signed(v: float) -> String:
	if is_nan(v) or not is_finite(v):
		return "n/a"
	var s := "%.4f" % v
	if v < 0.0:
		return s
	return "+" + s


# Variant 版（可能是 null）：给汇总行用。
func _signed_of(v) -> String:
	if v == null:
		return "n/a"
	return _signed(float(v))


# ═════════════════════════════════════════════════════════════════════════════
# 实验 A（计划 §5.1）：M1' = 脊顶在分水岭上的比例
#
#   脊顶格   = ridge_add[i] 是 6 邻中的最大值（严格大于至少 1 个邻居，避免全平顶点）
#              且 ridge_add[i] >= 陆地 ridge_add 的 p75
#   分水岭格 = 存在邻格 j，使 trace_outlet(i) != trace_outlet(j)
#              trace_outlet：沿 post_base 的 hydro_parent_arr 追到 <0（出口）
#   M1'      = |脊顶格 ∩ 分水岭格| / |脊顶格|
#   零假设   = 从陆地格里随机抽 |脊顶格| 个同法算比例（固定 RNG 种子，可复现）
#   差值     = M1' − 零假设（计划要求 >= 0.2）
#
# 返回 {"ok", "reason", "row", "elev", "land"}；elev/land 留给实验 B 复用（不重跑生成）。
# ═════════════════════════════════════════════════════════════════════════════

func _m1prime_metrics(seed_v: int, w: int, h: int, profile: Dictionary, tag: String) -> Dictionary:
	var n := w * h
	var gen := _generate(seed_v, w, h, profile)
	if not bool(gen["ok"]):
		_skip(tag, "生成失败 seed=%d %dx%d：%s" % [seed_v, w, h, str(gen["reason"])])
		return {"ok": false, "reason": str(gen["reason"])}
	var base: Dictionary = gen["base"]
	var post: Dictionary = gen["post"]
	var elev: PackedFloat32Array = base.get("elevation_arr", PackedFloat32Array())
	var ridge: PackedFloat32Array = base.get("ridge_add_arr", PackedFloat32Array())
	var parent: PackedInt32Array = post.get("hydro_parent_arr", PackedInt32Array())
	if elev.size() != n:
		_skip(tag, "elevation_arr 尺寸 %d != %d（base pass 输出异常）" % [elev.size(), n])
		return {"ok": false, "reason": "elev size"}
	if ridge.size() != n:
		_skip(tag, "ridge_add_arr 缺失（profile.ridge_debug_dump=1 未生效 / DLL 未含 P5-0.1 诊断）")
		return {"ok": false, "reason": "ridge missing"}
	if parent.size() != n:
		_skip(tag, "hydro_parent_arr 缺失（post_base 未导出水文拓扑）")
		return {"ok": false, "reason": "hydro_parent missing"}
	var cfg: Dictionary = gen["cfg"]
	var sea := float(cfg.get("sea_level", SEA_FALLBACK))
	var nbr := _neighbor_table(w, h)
	var land := _land_mask(elev, sea, n)
	var walk := _drainage_walk(parent, n)
	var outlet: PackedInt32Array = walk[0]
	var dist: PackedInt32Array = walk[1]
	var ws_pair := _watershed_flags(outlet, nbr, n, land)
	var ws_all: PackedByteArray = ws_pair[0]
	var ws: PackedByteArray = ws_pair[1]
	if not _drainage_ok(dist, n):
		_skip(tag, "hydro_parent 几乎每格都是自己的出口（dist==0 过半）⇒ 水文拓扑未导出，M1' 无意义")
		return {"ok": false, "reason": "degenerate hydro_parent"}
	# 陆地 ridge_add 的 p75（numpy 线性插值口径，与基线测试 M2b 同）
	var land_ridge := PackedFloat32Array()
	var land_h_vals := PackedFloat32Array()
	var land_cells := 0
	for i in range(n):
		if land[i] == 0:
			continue
		land_cells += 1
		land_ridge.append(float(ridge[i]))
		land_h_vals.append(float(elev[i]) - sea)
	if land_ridge.size() < MIN_SAMPLE:
		_skip(tag, "陆地格 %d < %d，p75 无意义" % [land_ridge.size(), MIN_SAMPLE])
		return {"ok": false, "reason": "too few land"}
	land_ridge.sort()
	land_h_vals.sort()
	var p75 := _percentile(land_ridge, RIDGE_P75)

	# 脊顶格
	var tops := PackedInt32Array()
	for i in range(n):
		if land[i] == 0:
			continue
		var ri := float(ridge[i])
		if ri <= 0.0 or ri < p75:
			continue
		var base_i := i * 6
		var is_max := true
		var strictly_greater := false
		var nb_valid := 0
		for d in range(6):
			var j := nbr[base_i + d]
			if j < 0:
				continue
			nb_valid += 1
			var rj := float(ridge[j])
			if rj > ri:
				is_max = false
				break
			if ri > rj:
				strictly_greater = true
		if not is_max:
			continue
		if nb_valid > 0 and not strictly_greater:
			continue
		tops.append(i)

	# M1'：脊顶里有多少落在分水岭上（主判据 = 只比陆地邻；副口径 = 计划字面全邻）
	var tops_ws := 0
	var tops_ws_all := 0
	for k in range(tops.size()):
		if ws[tops[k]] != 0:
			tops_ws += 1
		if ws_all[tops[k]] != 0:
			tops_ws_all += 1
	var m1prime := NAN
	var m1prime_all := NAN
	if tops.size() > 0:
		m1prime = float(tops_ws) / float(tops.size())
		m1prime_all = float(tops_ws_all) / float(tops.size())

	# 零假设：随机陆地格同数量（同一批抽样同时算两种口径）
	var null_rate := NAN
	var null_rate_all := NAN
	var land_idx := PackedInt32Array()
	for i in range(n):
		if land[i] != 0:
			land_idx.append(i)
	if tops.size() > 0 and land_idx.size() >= tops.size():
		var rng := RandomNumberGenerator.new()
		rng.seed = int(seed_v) * ZERO_HYP_SEED_MUL + n
		var pool := land_idx.duplicate()
		var k := tops.size()
		for t in range(k):
			var j := t + rng.randi_range(0, pool.size() - 1 - t)
			var tmp := pool[t]
			pool[t] = pool[j]
			pool[j] = tmp
		var null_ws := 0
		var null_ws_all := 0
		for t in range(k):
			if ws[pool[t]] != 0:
				null_ws += 1
			if ws_all[pool[t]] != 0:
				null_ws_all += 1
		null_rate = float(null_ws) / float(k)
		null_rate_all = float(null_ws_all) / float(k)
	elif tops.size() == 0:
		_skip(tag, "脊顶格为 0（ridge_add 全 0？p75=%.6f）" % p75)
	else:
		_skip(tag, "陆地格少于脊顶格，零假设无法同数量抽样")

	# 全陆地格的分水岭比例（第三个参照，不依赖抽样）
	var land_ws := 0
	var land_ws_all := 0
	for i in range(n):
		if land[i] == 0:
			continue
		if ws[i] != 0:
			land_ws += 1
		if ws_all[i] != 0:
			land_ws_all += 1
	var land_ws_rate := NAN
	var land_ws_rate_all := NAN
	if land_cells > 0:
		land_ws_rate = float(land_ws) / float(land_cells)
		land_ws_rate_all = float(land_ws_all) / float(land_cells)

	# 旧 M1 的**代理**：Spearman(ridge_add, log up_count)。见文件头「与既有测试的关系」。
	var up := _up_count(parent, dist, n, land)
	var rv := PackedFloat64Array()
	var av := PackedFloat64Array()
	for i in range(n):
		if land[i] == 0:
			continue
		if int(up[i]) < 1:
			continue
		rv.append(float(ridge[i]))
		av.append(log(float(up[i])))
	var m1_old := _spearman(rv, av)

	var delta := NAN
	var delta_all := NAN
	if is_finite(m1prime) and is_finite(null_rate):
		delta = m1prime - null_rate
	if is_finite(m1prime_all) and is_finite(null_rate_all):
		delta_all = m1prime_all - null_rate_all
	var row := {
		"seed": seed_v, "w": w, "h": h,
		"land_cells": land_cells,
		"ridge_p75": p75,
		"ridge_tops": tops.size(),
		"ridge_tops_watershed": tops_ws,
		"ridge_tops_watershed_all_nb": tops_ws_all,
		"watershed_land_cells": land_ws,
		"watershed_land_rate": _num(land_ws_rate),
		"watershed_land_rate_all_nb": _num(land_ws_rate_all),
		"m1prime": _num(m1prime),
		"m1_null": _num(null_rate),
		"m1_delta": _num(delta),
		"m1prime_all_nb": _num(m1prime_all),
		"m1_null_all_nb": _num(null_rate_all),
		"m1_delta_all_nb": _num(delta_all),
		"m1_old_proxy": _num(m1_old),
		"m1_old_points": rv.size(),
		"land_p50": _num(_percentile(land_h_vals, 0.50)),
		"land_p90": _num(_percentile(land_h_vals, 0.90)),
		"base_ms": gen["base_ms"],
		"post_ms": gen["post_ms"],
	}
	print("[followup/A] seed=%d %dx%d land=%d ridge_p75=%.4f ridge_tops=%d M1'=%s null=%s delta=%s | 字面全邻 M1'=%s null=%s delta=%s | ws_land=%s M1_old_proxy=%s base=%.1fms post=%.1fms"
			% [seed_v, w, h, land_cells, p75, tops.size(), _fmt(row["m1prime"]),
			_fmt(row["m1_null"]), _signed(delta), _fmt(row["m1prime_all_nb"]),
			_fmt(row["m1_null_all_nb"]), _signed(delta_all), _fmt(row["watershed_land_rate"]),
			_fmt(row["m1_old_proxy"]), float(gen["base_ms"]), float(gen["post_ms"])])
	return {"ok": true, "row": row, "elev": elev, "land": land, "sea": sea}


func _exp_m1prime() -> Dictionary:
	var rows: Array = []
	for i in range(N_SMALL_MAPS):
		rows.append(_m1prime_metrics(SEED_BASE + i, W_SMALL, H_SMALL, _profile(), "A"))
	for i in range(N_LARGE_MAPS):
		rows.append(_m1prime_metrics(SEED_BASE + i, W_LARGE, H_LARGE, _profile(), "A"))
	var ok_rows: Array = []
	for r in rows:
		if bool(r.get("ok", false)):
			ok_rows.append(r["row"])
	var summary := {
		"maps": rows.size(),
		"ok_maps": ok_rows.size(),
		"m1prime_mean": _num(_mean_of(ok_rows, "m1prime")),
		"m1_null_mean": _num(_mean_of(ok_rows, "m1_null")),
		"m1_delta_mean": _num(_mean_of(ok_rows, "m1_delta")),
		"m1prime_all_nb_mean": _num(_mean_of(ok_rows, "m1prime_all_nb")),
		"m1_null_all_nb_mean": _num(_mean_of(ok_rows, "m1_null_all_nb")),
		"m1_delta_all_nb_mean": _num(_mean_of(ok_rows, "m1_delta_all_nb")),
		"m1_old_proxy_mean": _num(_mean_of(ok_rows, "m1_old_proxy")),
		"target_delta": 0.2,
		"primary_variant": "land_neighbors_only（去掉海岸伪分水岭）；all_nb = 计划 §5.1 字面全邻口径",
	}
	var verdict := "n/a"
	if summary["m1_delta_mean"] != null:
		verdict = "达到（差 >= 0.2）" if float(summary["m1_delta_mean"]) >= 0.2 else "未达到（差 < 0.2）"
	print("[followup/A] 汇总 maps=%d ok=%d | 主口径 M1'=%s null=%s delta=%s | 字面全邻 M1'=%s null=%s delta=%s | 旧M1代理=%s | 目标差 >= 0.20 ⇒ %s"
			% [int(summary["maps"]), int(summary["ok_maps"]),
			_fmt(summary["m1prime_mean"]), _fmt(summary["m1_null_mean"]),
			_signed_of(summary["m1_delta_mean"]),
			_fmt(summary["m1prime_all_nb_mean"]), _fmt(summary["m1_null_all_nb_mean"]),
			_signed_of(summary["m1_delta_all_nb_mean"]),
			_fmt(summary["m1_old_proxy_mean"]), verdict])
	_notes.append("实验 A：M1' 的零假设用固定 RNG（seed = seed×%d + n）抽同数量陆地格；"
			% ZERO_HYP_SEED_MUL
			+ "旧 M1 用的是 up_count 代理，绝对数值以 ridge_drainage_metrics_test 的 M1 为准。")
	_notes.append("实验 A：主判据的分水岭只比较陆地邻格（ws_land），字面全邻口径（ws_all）同时落盘 —— "
			+ "出口处水体格 parent<0 会把「海岸陆地格 → 旁边别的海水格」全判成分水岭，抬高空假设、压低差值。")
	_notes.append("实验 A：陆地掩码用 base elevation_arr >= sea_level（与基线测试 M2b 口径一致），"
			+ "水文拓扑来自 post_base 的 hydro_parent_arr —— 两者在「post_base 才成湖」的格上不同源，"
			+ "这类格数量极少，不影响 p75/分水岭比例的量级。")
	_notes.append("实验 A：旧地形列 = n/a。旧版 base pass 没有 ridge_debug_dump（拿不到旧 ridge_add_arr），"
			+ "tmp/p5_calib/baseline 的冻结数组也没有 hydro_parent；且两版 ridge_add 不是同一个场"
			+ "（新版在 E0 上算、旧版在最终 E 上算，lead 实测幅值大 3–5 倍、p75 0.037→0.160、两场相关 0.40–0.52），"
			+ "所以「旧地形 M1'」既拿不到、也不该和本探针的 ridge_add 混比。主判据只做新地形 vs 零假设。")
	return {
		"definition": {
			"ridge_top": "ridge_add 为 6 邻最大（严格大于至少 1 个邻居）且 >= 陆地 ridge_add p75",
			"watershed": "存在邻格 j 使 trace_outlet(i) != trace_outlet(j)；trace_outlet 沿 hydro_parent_arr 追到 <0",
			"m1prime": "|脊顶 ∩ 分水岭| / |脊顶|（主口径只比陆地邻；*_all_nb 为计划字面全邻口径）",
			"null": "固定 RNG 随机抽同数量陆地格的分水岭比例（同一批抽样同时算两种口径）",
			"m1_old_proxy": "Spearman(ridge_add, log(up_count))，up_count 由 hydro_parent 累加（C++ 同定义）",
			"seeds": "2×60×40（seed 20260718/20260719）+ 1×200×150（seed 20260718）",
		},
		"old_terrain": {
			"status": "n/a",
			"reason": "旧地形（git HEAD 的 base pass）没有 ridge_debug_dump ⇒ 没有 ridge_add_arr；"
					+ "tmp/p5_calib/baseline 的冻结数组只有 elevation/ridge/terrain/landform，没有 hydro_parent。"
					+ "两样都缺，旧地形的 M1' 无法在本探针里算出。",
			"extra": "两版 ridge_add 不是同一个场（新版在 E0 上算、旧版在最终 E 上算）：lead 实测幅值大 3–5 倍、"
					+ "p75 0.037→0.160、两场相关 0.40–0.52、高脊格集合 Jaccard 0.31–0.43 ⇒ "
					+ "任何 ridge_add 相关量的跨版本比较都不可比，旧列留 n/a 而不是硬凑。",
			"primary_judgement": "新地形 M1' vs 零假设（计划 §5.1 的主判据：差 >= 0.2）",
		},
		"rows": rows,
		"summary": summary,
	}


# ═════════════════════════════════════════════════════════════════════════════
# 实验 B（计划 §5.2）：M1' 是「演化时间不够」还是「设计问题」
#
#   组 C14 / C28 / C40：spl_iters = 14 / 28 / 40，同时把抬升按 14/iters 等比缩小：
#       spl_ridge_uplift(iters) = 0.03 × 14/iters
#       spl_uplift_rate(iters)  = 0.08 × 14/iters
#   ⇒ 总抬升量 ≈ 每轮抬升 × 轮数 近似不变，只改「演化时间」这一个自由度。
#   每个组合算：M1'（实验 A 口径）、M2 洼地数（Priority-Flood）、land_p50/p90、base 耗时。
#   判读：M1' 随轮数单调改善 ⇒ 演化时间不够；基本不动 ⇒ 设计问题（进计划 §6.1）。
# ═════════════════════════════════════════════════════════════════════════════

func _exp_iters() -> Dictionary:
	var rows: Array = []
	var seed_v := SEED_BASE
	var nbr := _neighbor_table(W_SMALL, H_SMALL)
	for it in ITERS_LIST:
		var iters := int(it)
		var scale := float(ITERS_REF) / float(iters)
		var extra := {
			"spl_iters": iters,
			"spl_ridge_uplift": SPL_RIDGE_UPLIFT_BASE * scale,
			"spl_uplift_rate": SPL_UPLIFT_RATE_BASE * scale,
		}
		var profile := _profile(extra)
		var m := _m1prime_metrics(seed_v, W_SMALL, H_SMALL, profile, "B/iters=%d" % iters)
		if not bool(m.get("ok", false)):
			rows.append({
				"iters": iters, "uplift_scale": scale, "ok": false,
				"spl_ridge_uplift": _num(SPL_RIDGE_UPLIFT_BASE * scale),
				"spl_uplift_rate": _num(SPL_UPLIFT_RATE_BASE * scale),
			})
			continue
		var src_row: Dictionary = m["row"]
		var row := src_row.duplicate()
		row["ok"] = true
		row["iters"] = iters
		row["uplift_scale"] = _num(scale)
		row["spl_ridge_uplift"] = _num(SPL_RIDGE_UPLIFT_BASE * scale)
		row["spl_uplift_rate"] = _num(SPL_UPLIFT_RATE_BASE * scale)
		var elev: PackedFloat32Array = m["elev"]
		var pits := _pit_count_pf(elev, nbr, W_SMALL, H_SMALL, float(m["sea"]))
		row["M2_pits"] = pits
		rows.append(row)
		print("[followup/B] iters=%2d scale=%.4f ridge_uplift=%.5f uplift_rate=%.5f M1'=%s null=%s delta=%s M2_pits=%d land_p50=%s land_p90=%s base=%.1fms post=%.1fms"
				% [iters, scale, SPL_RIDGE_UPLIFT_BASE * scale, SPL_UPLIFT_RATE_BASE * scale,
				_fmt(row["m1prime"]), _fmt(row["m1_null"]), _signed(m1_delta_of(row)),
				pits, _fmt(row["land_p50"]), _fmt(row["land_p90"]),
				float(row["base_ms"]), float(row["post_ms"])])

	# 单调性判读（只对 ok 的行按 iters 升序比）
	var ok_rows: Array = []
	for r in rows:
		if bool(r.get("ok", false)) and r.get("m1prime", null) != null:
			ok_rows.append(r)
	var monotone := true
	var monotone_pair := 0
	for i in range(1, ok_rows.size()):
		monotone_pair += 1
		if float(ok_rows[i]["m1prime"]) <= float(ok_rows[i - 1]["m1prime"]):
			monotone = false
	var verdict := "n/a"
	if ok_rows.size() < 2:
		verdict = "样本不足，无法判读"
	elif monotone:
		verdict = "M1' 随轮数单调改善 ⇒ 演化时间不够（代价/收益另议）"
	else:
		verdict = "M1' 不随轮数单调改善 ⇒ 倾向设计问题（进计划 §6.1）"
	print("[followup/B] 判读：%s（可比 %d 组，单调对比 %d 对）" % [verdict, ok_rows.size(), monotone_pair])
	print("[followup/B] 表：iters | scale | ridge_uplift | uplift_rate | M1' | null | delta | M1'_all_nb | M2_pits | land_p50 | land_p90 | base_ms")
	for r in rows:
		print("  %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s"
				% [str(int(r.get("iters", -1))), _fmt(r.get("uplift_scale", null)),
				_fmt(r.get("spl_ridge_uplift", null)), _fmt(r.get("spl_uplift_rate", null)),
				_fmt(r.get("m1prime", null)), _fmt(r.get("m1_null", null)),
				_signed(m1_delta_of(r)), _fmt(r.get("m1prime_all_nb", null)),
				str(r.get("M2_pits", "n/a")),
				_fmt(r.get("land_p50", null)), _fmt(r.get("land_p90", null)),
				_fmt(r.get("base_ms", null))])
	_notes.append("实验 B：抬升等比缩小公式 spl_ridge_uplift=0.03×14/iters、spl_uplift_rate=0.08×14/iters，"
			+ "保持总抬升量近似不变；单种子 20260718 @60×40。")
	_notes.append("实验 B：u_eff = u_base × (14/iters)，u_base 取当前标定值（0.03 / 0.08）。"
			+ "注意 lead 实测「当前 0.03 对应的 ridge_add 场幅值已是旧版的 3–5 倍」，"
			+ "故本轮只比较 14/28/40 之间的相对变化，不与旧版数值做跨版本比较。")
	_notes.append("实验 B：M2（洼地数）只作背景值。lead 实测关掉 ridge_residual_frac（M2b 35.5）、"
			+ "spl_ridge_uplift（34.5）、spl_hillslope_diffusion（38.0）都不降（现状 33.5），"
			+ "说明 M2b 与脊抬升/残差/扩散无关 ⇒ 不要用 M2 判「演化时间不够 vs 设计问题」，判据只看 M1'。")
	return {
		"definition": {
			"iters": ITERS_LIST,
			"uplift_scale": "14 / iters",
			"spl_ridge_uplift": "0.03 × 14/iters",
			"spl_uplift_rate": "0.08 × 14/iters",
			"m1prime": "同实验 A 的主口径（分水岭只比陆地邻）；m1prime_all_nb = 计划字面全邻口径",
			"M2_pits": "Barnes Priority-Flood：陆地格 filled > elev + 1e-6（与基线测试 M2 同定义）",
			"seed": SEED_BASE,
		},
		"verdict": verdict,
		"monotone": monotone,
		"rows": rows,
	}


func m1_delta_of(row: Dictionary) -> float:
	var v = row.get("m1_delta", null)
	if v == null:
		return NAN
	return float(v)


# ═════════════════════════════════════════════════════════════════════════════
# 实验 C（计划 §5.3）：highland_river_count 下降是不是阈值副作用
#
#   源流判定要求 land_h ≥ river_headwater_min_land_h（缺省 0.30，world_ext_generate.cpp:1145）
#   且 up_count ≥ river_headwater_init_cells（缺省 10，同文件:1146）。大图 p50 下降时越过
#   阈值的格子本身就会变少。4 行表（「旧」列由 lead 用换 DLL 法另跑，本探针只填新地形）：
#     1) land_h_norm ≥ 0.30 的格数
#     2) 其中 up_count ≥ river_headwater_init_effective 的格数
#     3) highland_river_count（post_base 直接给）
#     4) 高地河流格位于局地谷底的比例（land_h_norm 低于 6 邻中位数）
#   判读：1、2 同比例下降 ⇒ 高度分布漂移；1、2 基本不变而 3 大降、4 上升 ⇒ 才是「入谷」。
#
#   口径说明：
#     · land_h_norm = (elev − sea)/(1 − sea) 与 C++ world_ext_generate.cpp:810 的 land_h() 同式，
#       阈值 0.30 作用在**这个**口径上（用 elev − sea 会算出完全不同的数量级）。
#     · 陆地 = terrain 非水体（pk_is_water_terrain 口径），与 C++ 的 land 列表同口径。
#     · up_count 是**代理**：沿 post_base 的 hydro_parent_arr 自行累加，初始值陆地 1 / 水体 0，
#       与 C++ world_ext_generate.cpp:1125-1133 的定义逐字相同（不是另写一套水文模型）。
#     · 高地河流格 = has_river 且 landform ∈ {6,7,8,13}（与 highland_river_count 同集合），
#       本探针会顺手数一遍与该计数逐格核对（r3_check）。
# ═════════════════════════════════════════════════════════════════════════════

func _exp_highland() -> Dictionary:
	var rows: Array = []
	rows.append(_highland_metrics(SEED_BASE + 0, W_SMALL, H_SMALL))
	rows.append(_highland_metrics(SEED_BASE + 1, W_SMALL, H_SMALL))
	rows.append(_highland_metrics(SEED_BASE + 0, W_LARGE, H_LARGE))
	var ok_rows: Array = []
	for r in rows:
		if bool(r.get("ok", false)):
			ok_rows.append(r)
	print("[followup/C] 4 行表（旧列 = lead 用换 DLL 法另跑，本探针不填）")
	print("  map        | 1) land_h_norm>=%.2f | 2) 其中 up>=init | 3) highland_river | 4) 谷底比例 | old"
			% RIVER_HEADWATER_MIN_LAND_H)
	for r in ok_rows:
		print("  seed=%d %dx%d | %d | %d | %d | %s | old=?"
				% [int(r["seed"]), int(r["w"]), int(r["h"]),
				int(r["r1_land_h_ge_min"]), int(r["r2_up_ge_init"]),
				int(r["r3_highland_river"]), _fmt(r.get("r4_valley_frac", null))])
	var summary := {
		"maps": rows.size(),
		"ok_maps": ok_rows.size(),
		"r1_mean": _num(_mean_of(ok_rows, "r1_land_h_ge_min")),
		"r2_mean": _num(_mean_of(ok_rows, "r2_up_ge_init")),
		"r3_mean": _num(_mean_of(ok_rows, "r3_highland_river")),
		"r4_mean": _num(_mean_of(ok_rows, "r4_valley_frac")),
		"r4_alt_mean": _num(_mean_of(ok_rows, "r4_alt_valley_frac")),
		"old_column": "由 lead 用换 DLL 法跑同一探针填入：1/2/3/4 各自的 old 值",
	}
	_notes.append("实验 C：land_h_norm 用 (elev-sea)/(1-sea)（与 C++ land_h() 同式）；"
			+ "up_count 由 hydro_parent 累加（C++ 同定义）；高地河流格 = has_river 且 landform∈{6,7,8,13}。")
	return {
		"definition": {
			"r1": "陆地格且 land_h_norm >= river_headwater_min_land_h",
			"r2": "r1 中 up_count >= river_headwater_init_effective（post_base 给出的大图缩放后值）",
			"r3": "post_base.highland_river_count（RIV 且 landform∈{6,7,8,13}）",
			"r4": "高地河流格中 land_h_norm 严格低于 6 邻中位数的比例",
			"r4_alt": "同上，但「高地河流格」改为 has_river 且 land_h_norm >= 0.30",
			"land_h_norm": "(elevation - sea_level) / (1 - sea_level)，与 C++ land_h() 同式",
			"up_count": "沿 hydro_parent_arr 累加，初始陆地 1 / 水体 0",
		},
		"rows": rows,
		"summary": summary,
	}


func _highland_metrics(seed_v: int, w: int, h: int) -> Dictionary:
	var n := w * h
	var profile := _profile({
		"river_headwater_min_land_h": RIVER_HEADWATER_MIN_LAND_H,
		"river_headwater_init_cells": RIVER_HEADWATER_INIT_CELLS,
	})
	var gen := _generate(seed_v, w, h, profile)
	if not bool(gen["ok"]):
		_skip("C", "生成失败 seed=%d %dx%d：%s" % [seed_v, w, h, str(gen["reason"])])
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": str(gen["reason"])}
	var post: Dictionary = gen["post"]
	var elev: PackedFloat32Array = post.get("elevation_arr", PackedFloat32Array())
	var terr: PackedByteArray = post.get("terrain_arr", PackedByteArray())
	var lf: PackedByteArray = post.get("landform_arr", PackedByteArray())
	var riv: PackedByteArray = post.get("has_river_arr", PackedByteArray())
	var parent: PackedInt32Array = post.get("hydro_parent_arr", PackedInt32Array())
	if elev.size() != n or terr.size() != n or lf.size() != n:
		_skip("C", "post_base 关键数组尺寸不符 seed=%d %dx%d" % [seed_v, w, h])
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": "array size"}
	if riv.size() != n:
		_skip("C", "has_river_arr 缺失（尺寸 %d != %d）" % [riv.size(), n])
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": "has_river missing"}
	if parent.size() != n:
		_skip("C", "hydro_parent_arr 缺失，up_count 代理无从计算")
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": "hydro_parent missing"}

	var cfg: Dictionary = gen["cfg"]
	var sea := float(cfg.get("sea_level", SEA_FALLBACK))
	var inv_above := 1.0 / maxf(1.0 - sea, 0.001)
	var nbr := _neighbor_table(w, h)
	# 陆地掩码 = terrain 非水体（C++ land 列表口径）
	var land := PackedByteArray()
	land.resize(n)
	land.fill(0)
	for i in range(n):
		if not _is_water_code(int(terr[i])):
			land[i] = 1
	# land_h_norm（C++ 口径）
	var lhn := PackedFloat32Array()
	lhn.resize(n)
	for i in range(n):
		lhn[i] = (float(elev[i]) - sea) * inv_above
	# 分布统计（land_h = elev - sea，与基线测试 land_p50/p90 同口径）
	var land_h_vals := PackedFloat32Array()
	for i in range(n):
		if land[i] != 0:
			land_h_vals.append(float(elev[i]) - sea)
	land_h_vals.sort()

	var r1 := 0
	for i in range(n):
		if land[i] != 0 and float(lhn[i]) >= RIVER_HEADWATER_MIN_LAND_H:
			r1 += 1

	# up_count 代理
	var walk := _drainage_walk(parent, n)
	var dist: PackedInt32Array = walk[1]
	if not _drainage_ok(dist, n):
		_skip("C", "hydro_parent 几乎每格都是自己的出口（dist==0 过半）⇒ up_count 恒 1，第 2 行无意义")
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": "degenerate hydro_parent"}
	var up := _up_count(parent, dist, n, land)
	var init_eff := int(post.get("river_headwater_init_effective", RIVER_HEADWATER_INIT_CELLS))
	var channel_eff := int(post.get("river_channel_init_effective", -1))
	var r2 := 0
	for i in range(n):
		if land[i] == 0:
			continue
		if float(lhn[i]) < RIVER_HEADWATER_MIN_LAND_H:
			continue
		if int(up[i]) >= init_eff:
			r2 += 1

	# 高地河流格（与 highland_river_count 同集合）+ 局地谷底比例
	var highland_river := PackedInt32Array()
	for i in range(n):
		if int(riv[i]) != 0 and _is_highland_code(int(lf[i])):
			highland_river.append(i)
	var r4_in_valley := 0
	for k in range(highland_river.size()):
		var i := highland_river[k]
		var med := _median_of_neighbors(lhn, nbr, i)
		if is_finite(med) and float(lhn[i]) < med:
			r4_in_valley += 1
	var r4 := NAN
	if highland_river.size() > 0:
		r4 = float(r4_in_valley) / float(highland_river.size())
	# 备选口径：has_river 且 land_h_norm >= 阈值
	var alt_cells := 0
	var alt_in_valley := 0
	for i in range(n):
		if int(riv[i]) == 0:
			continue
		if float(lhn[i]) < RIVER_HEADWATER_MIN_LAND_H:
			continue
		alt_cells += 1
		var med2 := _median_of_neighbors(lhn, nbr, i)
		if is_finite(med2) and float(lhn[i]) < med2:
			alt_in_valley += 1
	var r4_alt := NAN
	if alt_cells > 0:
		r4_alt = float(alt_in_valley) / float(alt_cells)

	var r3 := int(post.get("highland_river_count", -1))
	var row := {
		"ok": true,
		"seed": seed_v, "w": w, "h": h,
		"river_headwater_min_land_h": RIVER_HEADWATER_MIN_LAND_H,
		"river_headwater_init_effective": init_eff,
		"river_channel_init_effective": channel_eff,
		"r1_land_h_ge_min": r1,
		"r2_up_ge_init": r2,
		"r3_highland_river": r3,
		"r3_check_by_cells": highland_river.size(),
		"r4_valley_frac": _num(r4),
		"r4_valley_cells": r4_in_valley,
		"r4_alt_valley_frac": _num(r4_alt),
		"r4_alt_cells": alt_cells,
		"river_count": int(post.get("river_count", -1)),
		"lake_count": int(post.get("lake_count", -1)),
		"peak_count": int(post.get("peak_count", -1)),
		"plateau_count": int(post.get("plateau_count", -1)),
		"land_p50": _num(_percentile(land_h_vals, 0.50)),
		"land_p90": _num(_percentile(land_h_vals, 0.90)),
		"base_ms": gen["base_ms"],
		"post_ms": gen["post_ms"],
	}
	if r3 >= 0 and int(r3) != highland_river.size():
		_notes.append("实验 C seed=%d %dx%d：highland_river_count=%d 与逐格数 %d 不一致（口径差异，需说明）"
				% [seed_v, w, h, r3, highland_river.size()])
	print("[followup/C] seed=%d %dx%d init_eff=%d channel_eff=%d r1=%d r2=%d r3=%d(逐格 %d) r4=%.4f(%d/%d) r4_alt=%.4f(%d/%d) river=%d peak=%d plateau=%d land_p50=%s base=%.1fms"
			% [seed_v, w, h, init_eff, channel_eff, r1, r2, r3, highland_river.size(),
			float(r4) if is_finite(r4) else -1.0, r4_in_valley, highland_river.size(),
			float(r4_alt) if is_finite(r4_alt) else -1.0, alt_in_valley, alt_cells,
			int(row["river_count"]), int(row["peak_count"]), int(row["plateau_count"]),
			_fmt(row["land_p50"]), float(gen["base_ms"])])
	return row


# 6 邻中位数（缺行列时按有效邻居数取中位；无邻居 → NAN）。
func _median_of_neighbors(values: PackedFloat32Array, nbr: PackedInt32Array, i: int) -> float:
	var tmp := PackedFloat32Array()
	var base_i := i * 6
	for d in range(6):
		var j := nbr[base_i + d]
		if j < 0:
			continue
		tmp.append(float(values[j]))
	var m := tmp.size()
	if m == 0:
		return NAN
	tmp.sort()
	if (m & 1) == 1:
		return float(tmp[m >> 1])
	return (float(tmp[(m >> 1) - 1]) + float(tmp[m >> 1])) * 0.5


# ═════════════════════════════════════════════════════════════════════════════
# 实验 D（计划 §5.4）：dem_spl_k 为什么要 17 倍
#
#   实现单位（gdext/src/bake_erosion_spl.h:337/375/387）：
#     unit_area = 1/hex_px²            每像素初值（hex²）
#     K_iter    = dem_spl_k/iters      iters = dem_spl_iters（生产 6）
#     C[i]      = K_iter · A_hex^m / (DL/hex_px)，DL = 1（正交邻）或 √2（对角邻）
#   计划 §4.2 按「干流 A_hex ≈ 100」估 k=0.03；实际用 0.50（17 倍）。假设：河心像素被设为
#   汇流出口，像素汇水在流到河心时被截断 ⇒ 真实 A_hex 远小于 100，故 k 必须放大。
#
#   本实验在 desktop 真实地图（60×40 / 1024×606，hex_px ≈ 16.3）上量：
#     1) 陆地像素 A_hex 的 p50/p90/p99/max
#     2) 出口前一格（流入 wet 的像素，取该 wet 像素的 8 邻非 wet 里 A_hex 最大者）分布 p50/p90
#     3) 手算一个 A_hex ≈ p99 的典型陆地像素的 C，与观测 (h_pre − h_final)/h_pre 对照
#   判读：p99 A_hex 在 1–5 量级 ⇒ k=0.50 是口径问题（改侵蚀计划 §4.2 量级核算），不是单位 bug。
# ═════════════════════════════════════════════════════════════════════════════

func _exp_k_scale() -> Dictionary:
	var seed_v := SEED_BASE
	var map_w := W_SMALL
	var map_h := H_SMALL
	var hex_size := _env_float("FOLLOWUP_HEX_SIZE", HEX_SIZE_DEFAULT)
	var max_dim := int(_env_float("FOLLOWUP_HM_MAX_DIM", float(HM_MAX_DIM_DESKTOP)))
	var geo := _desktop_geometry(map_w, map_h, hex_size, max_dim)
	var hex_px := float(geo["hex_px"])
	# 融合 pass 内部同式（world_ext_bake.cpp:1521）：hex_px = hex_size·√3/step_x。
	var unit_area := 1.0 / maxf(hex_px * hex_px, 1.0e-12)
	var px_scale := hex_px * hex_px   # A_hex(hex²) × hex_px² = 该像素的汇水像素数（px）
	var profile := _profile()
	var gen := _generate(seed_v, map_w, map_h, profile)
	if not bool(gen["ok"]):
		_skip("D", "生成失败 seed=%d %dx%d：%s" % [seed_v, map_w, map_h, str(gen["reason"])])
		_hard_fail += 1
		return {"ok": false, "reason": str(gen["reason"])}
	var post: Dictionary = gen["post"]
	var cfg: Dictionary = gen["cfg"]
	var sea_level := float(cfg.get("sea_level", SEA_FALLBACK))
	var n_cells := map_w * map_h
	var elev: PackedFloat32Array = post.get("elevation_arr", PackedFloat32Array())
	var moist: PackedFloat32Array = post.get("moisture_arr",
			post.get("soil_moisture_arr", PackedFloat32Array()))
	var terr: PackedByteArray = post.get("terrain_arr", PackedByteArray())
	var lf: PackedByteArray = post.get("landform_arr", PackedByteArray())
	var veg: PackedByteArray = post.get("vegetation_arr", PackedByteArray())
	var cov: PackedByteArray = post.get("cover_arr", PackedByteArray())
	var wdep: PackedFloat32Array = post.get("water_depth_arr", PackedFloat32Array())
	if elev.size() != n_cells or terr.size() != n_cells or lf.size() != n_cells:
		_skip("D", "post_base cell 数组尺寸不符，bake 无法装配 knobs")
		_hard_fail += 1
		return {"ok": false, "reason": "cell array size"}
	# offset_to_index：生成器 index = row*width+col 且 cell.index == i（terrain_gen.gd:65-108
	# 按 i 顺序建 cell、map_data.gd:381 赋 index），故整幅地图的偏移表是恒等映射。
	var o2i := PackedInt32Array()
	o2i.resize(n_cells)
	for i in range(n_cells):
		o2i[i] = i
	var W: int = int(geo["W"])
	var H: int = int(geo["H"])
	var size_x := float(geo["size_x"])
	var size_y := float(geo["size_y"])
	var inv_world_x := float(W) / size_x
	var inv_world_y := float(H) / size_y
	var stroke_radius_px := maxf(hex_size * RIVER_STROKE_HEX_FACTOR * inv_world_x, 0.5)
	var knobs := {
		"width": W, "height": H,
		"origin_x": float(geo["origin_x"]), "origin_y": float(geo["origin_y"]),
		"hex_size": hex_size, "seed": seed_v,
		"map_width": map_w, "map_height": map_h,
		"n_cells": n_cells,
		"size_x": size_x, "size_y": size_y,
		"wrap_period_x": float(geo["wrap_period_x"]),
		"sea_level": sea_level,
		"cell_elevation": elev,
		"cell_moisture": moist,
		"cell_terrain": terr,
		"cell_landform": lf,
		"cell_vegetation": veg,
		"cell_cover": cov,
		"cell_water_depth": wdep,
		"offset_to_index": o2i,
		"num_drops": EROSION_DROPS,
		"max_steps": EROSION_MAX_STEPS,
		"inertia": EROSION_INERTIA,
		"capacity_factor": EROSION_CAPACITY_FACTOR,
		"min_capacity": EROSION_MIN_CAPACITY,
		"deposit_speed": EROSION_DEPOSIT_SPEED,
		"erode_speed": EROSION_ERODE_SPEED,
		"evaporation": EROSION_EVAPORATION,
		"gravity": EROSION_GRAVITY,
		"brush_radius": EROSION_RADIUS,
		"inv_world_x": inv_world_x, "inv_world_y": inv_world_y,
		"base_radius_px": stroke_radius_px,
		"sdf_max_dist_px": SDF_MAX_DIST_PX,
		"cr_step": RIVER_CR_STEP,
		"shore_carve_amp": SHORE_CARVE_AMP,
		"shore_carve_band": SHORE_CARVE_BAND,
		"coast_sdf_max_dist_px": COAST_SDF_MAX_DIST_PX,
	}
	var dem_knobs := _dem_knobs()
	for key in dem_knobs:
		knobs[key] = dem_knobs[key]
	# 本实验的必要条件：SPL 分支 + 像素 A_hex 诊断输出。
	knobs["dem_erosion_mode"] = "spl"
	knobs["dem_erosion_area_dump"] = true
	var t0 := Time.get_ticks_usec()
	var rep_v = _ext.call("run_bake_geometry_fields_pass", knobs)
	var bake_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if typeof(rep_v) != TYPE_DICTIONARY:
		_skip("D", "run_bake_geometry_fields_pass 未返回 Dictionary（方法未导出？）")
		_hard_fail += 1
		return {"ok": false, "reason": "bake method missing"}
	var rep: Dictionary = rep_v
	var rep_ok := not bool(rep.get("fallback", true))
	if not rep_ok:
		_skip("D", "bake 融合 pass fallback=%s reason=%s" % [
				str(rep.get("fallback", "?")), str(rep.get("reason", "?"))])
		_hard_fail += 1
		return {"ok": false, "reason": str(rep.get("reason", "?"))}
	var area: PackedFloat32Array = rep.get("area_hex_buffer", PackedFloat32Array())
	if area.size() != W * H:
		_skip("D", "area_hex_buffer 缺失/尺寸 %d != %d（dem_erosion_area_dump 未生效？DLL 未含 S2.1 诊断？）"
				% [area.size(), W * H])
		_hard_fail += 1
		return {"ok": false, "reason": "area_hex_buffer missing"}
	var hpre: PackedFloat32Array = rep.get("procedural_height_buffer", PackedFloat32Array())
	var hfin: PackedFloat32Array = rep.get("height_buffer", PackedFloat32Array())
	var biome: PackedByteArray = rep.get("biome_buffer", PackedByteArray())
	var flow: PackedFloat32Array = rep.get("flow_buffer", PackedFloat32Array())
	var npx := W * H
	if hpre.size() != npx or hfin.size() != npx or biome.size() != npx:
		_skip("D", "bake 输出高度/biome 尺寸不符（%d/%d/%d vs %d）"
				% [hpre.size(), hfin.size(), biome.size(), npx])
		_hard_fail += 1
		return {"ok": false, "reason": "bake buffer size"}
	var flow_ok := flow.size() == npx
	if not bool(rep.get("river_ok", false)):
		_note_river_missing(rep)

	# wet = 水体 ∪ 河心像素（与融合 pass 构造出口集合的条件同值）
	var wet := PackedByteArray()
	wet.resize(npx)
	wet.fill(0)
	for i in range(npx):
		if _is_water_code(int(biome[i])):
			wet[i] = 1
		elif flow_ok and float(flow[i]) >= RIVER_OUTLET_FLOW:
			wet[i] = 1

	# ① 陆地像素 A_hex（非 wet = 侵蚀栅格里真正累加面积的像素）
	var land_vals := PackedFloat32Array()
	var land_px := 0
	var a_max := 0.0
	var a_max_idx := -1
	for i in range(npx):
		if wet[i] != 0:
			continue
		var a := float(area[i])
		land_px += 1
		land_vals.append(a)
		if a > a_max:
			a_max = a
			a_max_idx = i
	if land_vals.size() < MIN_SAMPLE:
		_skip("D", "非 wet 像素只有 %d 个，A_hex 分布无意义" % land_vals.size())
		_hard_fail += 1
		return {"ok": false, "reason": "too few land px"}
	land_vals.sort()
	var a_p50 := _percentile(land_vals, 0.50)
	var a_p90 := _percentile(land_vals, 0.90)
	var a_p99 := _percentile(land_vals, 0.99)

	# ② 出口前一格：对每个 wet 像素，取它 8 邻里非 wet 且 A_hex 最大的那个
	var pre_all := PackedFloat32Array()
	var pre_river := PackedFloat32Array()
	for y in range(H):
		var row_base := y * W
		for x in range(W):
			var i := row_base + x
			if wet[i] == 0:
				continue
			var best := -1.0
			for ddy in range(3):
				var dy := ddy - 1
				var ny := y + dy
				if ny < 0 or ny >= H:
					continue
				for ddx in range(3):
					if ddx == 1 and ddy == 1:
						continue
					var nx := x + (ddx - 1)
					if nx < 0 or nx >= W:
						continue
					var j := ny * W + nx
					if wet[j] != 0:
						continue
					var aj := float(area[j])
					if aj > best:
						best = aj
			if best <= 0.0:
				continue
			pre_all.append(best)
			if flow_ok and float(flow[i]) >= RIVER_OUTLET_FLOW:
				pre_river.append(best)
	pre_all.sort()
	pre_river.sort()
	var pre_all_p50 := _percentile(pre_all, 0.50)
	var pre_all_p90 := _percentile(pre_all, 0.90)
	var pre_river_p50 := _percentile(pre_river, 0.50)
	var pre_river_p90 := _percentile(pre_river, 0.90)

	# ③ 手算校验：找 A_hex 最接近 p99 的陆地像素
	var target := a_p99
	var best_idx := -1
	var best_diff := INF
	for i in range(npx):
		if wet[i] != 0:
			continue
		var d := absf(float(area[i]) - target)
		if d < best_diff:
			best_diff = d
			best_idx = i
	var k_total := _dem_knob("dem_spl_k", 0.50)
	var m_exp := _dem_knob("dem_spl_m", 0.45)
	var iters := int(_dem_knob("dem_spl_iters", 6))
	var k_iter := k_total / float(maxi(iters, 1))
	var a_hex := 0.0
	var c_dl1 := 0.0
	var c_dlsqrt2 := 0.0
	var rel_drop := NAN
	var hpre_i := 0.0
	var hfin_i := 0.0
	var hand_ok := best_idx >= 0
	if hand_ok:
		a_hex = float(area[best_idx])
		var aw := pow(maxf(a_hex, 1.0e-12), m_exp)
		c_dl1 = k_iter * aw / (1.0 / hex_px)
		c_dlsqrt2 = k_iter * aw / (1.4142135623730951 / hex_px)
		hpre_i = float(hpre[best_idx])
		hfin_i = float(hfin[best_idx])
		if hpre_i > 1.0e-6:
			rel_drop = (hpre_i - hfin_i) / hpre_i
	# k=0.03（计划估算值）在同一 A_hex 上的 C，用于说明「17 倍是 k 而不是单位」
	var c_dl1_plan_k := (0.03 / float(maxi(iters, 1))) * pow(maxf(a_hex, 1.0e-12), m_exp) / (1.0 / hex_px)
	var c_at_planned_a := k_iter * pow(A_HEX_PLANNED, m_exp) / (1.0 / hex_px)
	# 计划自己的估算：k=0.03、A=100 hex² ⇒ 计划的 C 目标值。与实测 C 一比即可看出
	# 「k 的 17 倍」是补偿 A_hex 太小、还是补偿别的东西（例如 hex_px / 下采样）。
	var c_plan_est := (0.03 / float(maxi(iters, 1))) * pow(A_HEX_PLANNED, m_exp) / (1.0 / hex_px)
	var c_ratio := NAN
	if is_finite(c_plan_est) and c_plan_est > 1.0e-9:
		c_ratio = c_dl1 / c_plan_est
	var a_ratio := NAN
	if is_finite(a_p99) and a_p99 > 1.0e-9:
		a_ratio = A_HEX_PLANNED / a_p99
	var a_p99_px := a_p99 * px_scale
	var frac_per_iter := NAN
	if is_finite(c_dl1) and c_dl1 > 0.0:
		frac_per_iter = c_dl1 / (1.0 + c_dl1)
	var approach_total := NAN
	if is_finite(c_dl1) and c_dl1 > 0.0:
		approach_total = 1.0 - pow(1.0 / (1.0 + c_dl1), float(maxi(iters, 1)))

	var verdict := "n/a"
	if not is_finite(a_p99):
		verdict = "n/a（陆地像素 A_hex 分布没算出来）"
	elif a_p99 >= 1.0 and a_p99 <= 5.0:
		verdict = "计划 §5.4 的口径内（p99 ∈ [1,5] hex²）⇒ k=0.50 与实现单位自洽，修订侵蚀计划 §4.2 的量级核算即可"
	elif a_p99 < 1.0:
		verdict = "p99 A_hex < 1 hex²：像素汇水被 wet/河心出口截断到 1–2 px 量级，k 的 17 倍是把 C 拉回可用区间的经验补偿（不是单位 bug）"
	else:
		verdict = "p99 A_hex > 5 hex²：接近计划假设的 100，k 的 17 倍另有原因（查下采样 / hex_px / 单位）"
	print("[followup/D] 几何 map=%dx%d hex=%.2f hm=%dx%d step_x=%.4f hex_px=%.4f unit_area=%.6f wrap_period_x=%.2f"
			% [map_w, map_h, hex_size, W, H, float(geo["step_x"]), hex_px, unit_area,
			float(geo["wrap_period_x"])])
	print("[followup/D] bake mode=%s factor=%d grid=%dx%d spl_iters_eff=%d p99_drop=%.6f max_drop=%.6f bake=%.1fms"
			% [str(rep.get("erosion_mode", "?")), int(rep.get("erosion_grid_factor", -1)),
			int(rep.get("erosion_grid_w", -1)), int(rep.get("erosion_grid_h", -1)),
			int(rep.get("spl_iters_effective", -1)), float(rep.get("spl_p99_drop", -1.0)),
			float(rep.get("spl_max_drop", -1.0)), bake_ms])
	print("[followup/D] 陆地像素 A_hex  n=%d/%d p50=%.5f p90=%.5f p99=%.5f max=%.5f (hex², max@idx=%d)"
			% [land_px, npx, a_p50, a_p90, a_p99, a_max, a_max_idx])
	print("[followup/D] 同上换算成像素数（hex² × hex_px² = ×%.2f）：p50=%.2f px p90=%.2f px p99=%.2f px max=%.2f px | 1px = %.5f hex²"
			% [px_scale, a_p50 * px_scale, a_p90 * px_scale, a_p99 * px_scale,
			a_max * px_scale, unit_area])
	print("[followup/D] 出口前一格 A_hex  全部wet n=%d p50=%s p90=%s | 仅河心 n=%d p50=%s p90=%s"
			% [pre_all.size(), _fmt(_num(pre_all_p50)), _fmt(_num(pre_all_p90)),
			pre_river.size(), _fmt(_num(pre_river_p50)), _fmt(_num(pre_river_p90))])
	print("[followup/D] 手算 k_total=%.4f m=%.4f iters=%d K_iter=%.6f | 取 A_hex≈p99 的像素 idx=%d A_hex=%.5f(%.2f px) h_pre=%.6f h_final=%.6f rel_drop=%s"
			% [k_total, m_exp, iters, k_iter, best_idx, a_hex, a_hex * px_scale,
			hpre_i, hfin_i, _fmt(_num(rel_drop))])
	print("[followup/D] 手算 C(DL=1)=%.4f C(DL=√2)=%.4f 每轮削减比例 C/(1+C)=%s 6轮累计逼近=%s | 同 A 用 k=0.03 的 C=%.4f | A=%d 时 C(DL=1)=%.2f"
			% [c_dl1, c_dlsqrt2, _fmt(_num(frac_per_iter)), _fmt(_num(approach_total)),
			c_dl1_plan_k, int(A_HEX_PLANNED), c_at_planned_a])
	print("[followup/D] 计划对照 C_plan(k=0.03, A=100)=%.3f vs 实测 C(k=%.2f, A=p99)=%.3f ⇒ 比值=%s；A_hex 比计划假设小 %.0f 倍（计划 100 hex² = %.0f px）"
			% [c_plan_est, k_total, c_dl1, _fmt(_num(c_ratio)), a_ratio, A_HEX_PLANNED * px_scale])
	print("[followup/D] 判读：%s" % verdict)
	_notes.append("实验 D：rel_drop 用 (procedural_height − height_buffer)/procedural_height，"
			+ "height_buffer 含侵蚀 + 河刻 + 岸坡刻 + 限坡，故只作量级对照。")
	_notes.append("实验 D：hand C 的 DL 未知（受体方向随像素变），故同时给 DL=1 与 DL=√2 两值。")
	_notes.append("实验 D：lead 侧同一 DLL 实测锚点（用于交叉校验）——陆地 A_hex p50 = 0.00752 hex² = 2.0 px、"
			+ "河心（wet）A_hex p50 = 0.00376 hex² = 1.0 px（正好等于 unit_area = 1 px）、hex_px = 16.30。"
			+ "本次 p50 若与之差一个数量级以上，先怀疑 wet 判定或 hex_px 不一致，而不是 k。")
	return {
		"definition": {
			"hex_px": "hex_size × √3 / step_x，step_x = size_x / W（融合 pass 内部同式，world_ext_bake.cpp:1521）",
			"unit_area": "1 / hex_px²（bake_erosion_spl.h:337）",
			"K_iter": "dem_spl_k / dem_spl_iters（bake_erosion_spl.h:375）",
			"C": "K_iter · A_hex^m / (DL/hex_px)，DL=1 正交邻 / √2 对角邻（bake_erosion_spl.h:387）",
			"wet": "biome 水体 ∪ (flow_buffer >= dem_valley_river_outlet_flow)",
			"pre_outlet": "每个 wet 像素取 8 邻非 wet 中 A_hex 最大者（= 流入它的「出口前一格」）",
		},
		"geometry": geo,
		"bake": {
			"mode": str(rep.get("erosion_mode", "?")),
			"factor": int(rep.get("erosion_grid_factor", -1)),
			"grid_w": int(rep.get("erosion_grid_w", -1)),
			"grid_h": int(rep.get("erosion_grid_h", -1)),
			"spl_iters_effective": int(rep.get("spl_iters_effective", -1)),
			"spl_p99_drop": float(rep.get("spl_p99_drop", -1.0)),
			"spl_max_drop": float(rep.get("spl_max_drop", -1.0)),
			"erosion_ok": bool(rep.get("erosion_ok", false)),
			"river_ok": bool(rep.get("river_ok", false)),
			"pixels": npx,
			"land_pixels": land_px,
			"bake_ms": bake_ms,
		},
		"land_px": land_px,
		"hex_px": _num(hex_px),
		"unit_area_hex2": _num(unit_area),
		"px_scale": _num(px_scale),
		"a_p50": _num(a_p50), "a_p90": _num(a_p90), "a_p99": _num(a_p99), "a_max": _num(a_max),
		"a_p50_px": _num(a_p50 * px_scale), "a_p90_px": _num(a_p90 * px_scale),
		"a_p99_px": _num(a_p99 * px_scale), "a_max_px": _num(a_max * px_scale),
		"a_max_idx": a_max_idx,
		"plan_compare": {
			"a_hex_planned": A_HEX_PLANNED,
			"a_hex_planned_px": _num(A_HEX_PLANNED * px_scale),
			"a_ratio_planned_over_p99": _num(a_ratio),
			"c_plan_est_k_0_03_a_100": _num(c_plan_est),
			"c_actual_at_p99": _num(c_dl1),
			"c_ratio_actual_over_plan": _num(c_ratio),
		},
		"pre_outlet_all": {"n": pre_all.size(), "p50": _num(pre_all_p50), "p90": _num(pre_all_p90)},
		"pre_outlet_river": {"n": pre_river.size(), "p50": _num(pre_river_p50), "p90": _num(pre_river_p90)},
		"hand": {
			"idx": best_idx, "a_hex": _num(a_hex), "a_hex_px": _num(a_hex * px_scale),
			"h_pre": _num(hpre_i), "h_final": _num(hfin_i), "rel_drop": _num(rel_drop),
			"k_total": k_total, "m": m_exp, "iters": iters, "k_iter": k_iter,
			"c_dl1": _num(c_dl1), "c_dl_sqrt2": _num(c_dlsqrt2),
			"frac_per_iter": _num(frac_per_iter), "approach_total": _num(approach_total),
			"c_dl1_plan_k_0_03": _num(c_dl1_plan_k),
			"c_at_a_planned_100": _num(c_at_planned_a),
		},
		"verdict": verdict,
	}


func _env_float(name: String, fallback: float) -> float:
	var raw := OS.get_environment(name).strip_edges()
	if raw == "":
		return fallback
	if not raw.is_valid_float():
		return fallback
	return raw.to_float()


# 融合 pass 的 river SDF 子 pass 失败时的说明。不硬失败：A_hex 统计仍有效，
# 只是 wet 里少了「河心像素」这一部分、河心子集统计为空。
func _note_river_missing(rep: Dictionary) -> void:
	_notes.append("实验 D：融合 pass 的 river SDF 子 pass 失败（river_ok=false, reason=%s），"
			% str(rep.get("river_reason", "?"))
			+ "flow_buffer 为空 ⇒ wet 只含 biome 水体，河心子集与「出口前一格（仅河心）」不可用。")


# 镜像 MapBaker.compute_world_bounds()（bakers/surface_baker.gd:848）与
# TerrainBaker._resolve_hm_size()（bakers/terrain_baker.gd:459）。
func _desktop_geometry(map_w: int, map_h: int, hex_size: float, max_dim: int) -> Dictionary:
	var px := sqrt(3.0) * hex_size * (float(map_w) + 0.5)
	var py := 1.5 * hex_size * float(map_h) + 0.5 * hex_size
	var size_x := px + hex_size * 4.0
	var size_y := py + hex_size * 4.0
	var origin_x := -hex_size * 2.0
	var origin_y := -hex_size * 2.0
	var aspect := size_x / size_y
	var W := 0
	var H := 0
	if aspect >= 1.0:
		W = max_dim
		H = int(round(float(max_dim) / aspect))
	else:
		H = max_dim
		W = int(round(float(max_dim) * aspect))
	W = (W >> 1) << 1
	H = (H >> 1) << 1
	W = maxi(W, 256)
	H = maxi(H, 256)
	var step_x := size_x / float(W)
	var hex_px := 1.0
	if step_x > 1.0e-9:
		hex_px = hex_size * 1.7320508075688772 / step_x
	return {
		"map_w": map_w, "map_h": map_h, "hex_size": hex_size,
		"W": W, "H": H,
		"size_x": size_x, "size_y": size_y,
		"origin_x": origin_x, "origin_y": origin_y,
		"step_x": step_x, "hex_px": hex_px,
		"wrap_period_x": maxf(0.0, float(map_w) * sqrt(3.0) * hex_size),
	}


# 与 DCTerrainIndexBaker.dem_landform_knobs() 同语义：ProjectSettings 覆盖优先，缺省即生产值。
func _dem_knobs() -> Dictionary:
	var out := {}
	for key in DEM_KNOB_DEFAULTS:
		out[key] = ProjectSettings.get_setting(
				DEM_SETTING_PREFIX + String(key).trim_prefix("dem_"),
				DEM_KNOB_DEFAULTS[key])
	return out


func _dem_knob(key: String, fallback: float) -> float:
	var v = ProjectSettings.get_setting(DEM_SETTING_PREFIX + key.trim_prefix("dem_"),
			DEM_KNOB_DEFAULTS.get(key, fallback))
	return float(v)


# ═════════════════════════════════════════════════════════════════════════════
# 实验 E（计划 §5.5）：分清「圆顶」与「平顶」
#
#   高地 = 陆地 land_h ≥ 陆地 land_h 的 p90（land_h = elev − sea，与基线测试 M5_p90 同口径）。
#   连通块 = 高地块按 6 邻 BFS；块内格数 < M5_MIN_COMP（5）的小块不入统计（仍打印计数）。
#
#   M5a 顶部曲率集中度（**圆顶高、平顶低**）：
#     hex Laplacian L[i] = Σ_6邻 E − k·E[i]（k = 有效邻居数，南北边界处 < 6）
#     取所有 L[i] < 0（凸）的格，按 |L| 加权：M5a = Σ_top|L| / Σ_all|L|，
#     其中 top = 该块内 E 最高的 20% 格，**按数量取 K = round(0.2 × 块格数)**、同值按下标定序。
#     为什么按数量而不是按 p80 阈值：平顶块里大量格 E 并列最高，阈值口径会把并列全算进 top
#     → top 集 = 整块 → M5a 恒 1.0，恰好把「平顶」判成「圆顶」、指标自相矛盾。
#     为什么要单列「内部格」口径：高地 = land_h ≥ p90 的阈值会把山体拦腰截断，块边界环上的格
#     有「一邻居低、自己高」的巨大人造假凸性，会把真正山顶曲率的占比淹掉。故
#     M5a（主口径）只统计 6 邻全在块内的内部格；M5a_all 是含边界环的计划字面口径，两者都落盘。
#   M5b 平坦面积比（**平顶高**）：
#     高地块内 |L| < ε 且局地坡度 < ε 的格占比；坡度 = 6 邻 |E[j] − E[i]| 的最大值。
#     ε = M5B_EPS_FRAC × 该图陆地 land_h 的 p99（浮动阈值，见常量处说明），
#     主判据 0.02，另跑 0.01 / 0.04 作敏感性。两层都按种子打印 + 跨种子平均。
#   M5_old_p90 = 旧口径辅助量（局地起伏 max−min < 0.02 的占比），与基线测试 M5_p90 可比。
# ═════════════════════════════════════════════════════════════════════════════

func _exp_m5shape() -> Dictionary:
	var rows: Array = []
	rows.append(_m5_metrics(SEED_BASE + 0, W_SMALL, H_SMALL))
	rows.append(_m5_metrics(SEED_BASE + 1, W_SMALL, H_SMALL))
	rows.append(_m5_metrics(SEED_BASE + 0, W_LARGE, H_LARGE))
	var ok_rows: Array = []
	for r in rows:
		if bool(r.get("ok", false)):
			ok_rows.append(r)
	var summary := {
		"maps": rows.size(),
		"ok_maps": ok_rows.size(),
		"m5a_mean": _num(_mean_of(ok_rows, "m5a")),
		"m5a_all_mean": _num(_mean_of(ok_rows, "m5a_all")),
		"m5b_eps001_mean": _num(_mean_of(ok_rows, "m5b_eps001")),
		"m5b_eps002_mean": _num(_mean_of(ok_rows, "m5b_eps002")),
		"m5b_eps004_mean": _num(_mean_of(ok_rows, "m5b_eps004")),
		"m5b_interior_eps002_mean": _num(_mean_of(ok_rows, "m5b_interior_eps002")),
		"m5_old_p90_mean": _num(_mean_of(ok_rows, "m5_old_p90")),
		"shape_verdict": "M5a 高 = 圆顶；M5b 高 = 平顶（需与旧地形同口径数值对照后判定）",
	}
	print("[followup/E] 平均：M5a=%s M5a_all=%s M5b_eps1=%s M5b_eps2=%s M5b_eps4=%s M5b_int=%s M5_old_p90=%s maps=%d"
			% [_fmt(summary["m5a_mean"]), _fmt(summary["m5a_all_mean"]),
			_fmt(summary["m5b_eps001_mean"]), _fmt(summary["m5b_eps002_mean"]),
			_fmt(summary["m5b_eps004_mean"]), _fmt(summary["m5b_interior_eps002_mean"]),
			_fmt(summary["m5_old_p90_mean"]), int(summary["ok_maps"])])
	_notes.append("实验 E：M5a/M5b 都是本探针新写的轻量实现（不复用 ridge_drainage_metrics_test 的 M5）；"
			+ "M5_old_p90 才是与旧 M5_p90 同口径的数字。")
	_notes.append("实验 E：M5a 主口径只算「内部格」（6 邻全在同一高地块内），因为 p90 阈值会在块边界造出"
			+ "「一邻居低、自己高」的假凸性环、淹没山顶信号；m5a_all 是含边界环的计划字面口径。")
	return {
		"definition": {
			"highland": "陆地且 land_h >= 陆地 land_h p90（land_h = elev - sea）",
			"component": "高地块按 6 邻连通块；块内格数 >= %d 才入统计" % M5_MIN_COMP,
			"laplacian": "L[i] = Σ_6邻 E − k·E[i]，k = 有效邻居数（南北边界 < 6）",
			"m5a": "Σ(|L| where L<0 且格属于块内 E 最高的 K 个) / Σ(|L| where L<0)，K = round(0.2×块格数)；只算内部格",
			"m5a_all": "同上，但含块边界环（计划 §5.5 字面口径）",
			"m5a_topk": "按数量取 top-K，同值用「量化高度×n+下标」确定性定序（避免平顶块 top 集膨胀到整块）",
			"m5b": "块内 |L| < ε 且 max_6邻|ΔE| < ε 的格占比；ε = frac × 陆地 land_h p99",
			"m5b_interior_eps002": "同上但分母只算内部格、ε 取主判据 0.02",
			"eps_sweep": M5B_EPS_SWEEP,
			"eps_primary": M5B_EPS_FRAC,
			"m5_old_p90": "块内 (max−min of self+6邻) < %s 的占比（旧口径对照）" % str(PLATEAU_RELIEF),
		},
		"rows": rows,
		"summary": summary,
	}


func _m5_metrics(seed_v: int, w: int, h: int) -> Dictionary:
	var n := w * h
	var gen := _generate(seed_v, w, h, _profile())
	if not bool(gen["ok"]):
		_skip("E", "生成失败 seed=%d %dx%d：%s" % [seed_v, w, h, str(gen["reason"])])
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": str(gen["reason"])}
	var base: Dictionary = gen["base"]
	var elev: PackedFloat32Array = base.get("elevation_arr", PackedFloat32Array())
	if elev.size() != n:
		_skip("E", "elevation_arr 尺寸 %d != %d" % [elev.size(), n])
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": "elev size"}
	var cfg: Dictionary = gen["cfg"]
	var sea := float(cfg.get("sea_level", SEA_FALLBACK))
	var nbr := _neighbor_table(w, h)
	var land := _land_mask(elev, sea, n)
	var land_vals := PackedFloat32Array()
	for i in range(n):
		if land[i] != 0:
			land_vals.append(float(elev[i]) - sea)
	if land_vals.size() < MIN_SAMPLE:
		_skip("E", "陆地格 %d < %d" % [land_vals.size(), MIN_SAMPLE])
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": "too few land"}
	land_vals.sort()
	var p90 := _percentile(land_vals, M5_HIGHLAND_PCT)
	var p99 := _percentile(land_vals, 0.99)
	var highland := PackedByteArray()
	highland.resize(n)
	highland.fill(0)
	var highland_cells := 0
	for i in range(n):
		if land[i] != 0 and (float(elev[i]) - sea) >= p90:
			highland[i] = 1
			highland_cells += 1
	if highland_cells < MIN_SAMPLE:
		_skip("E", "高地块只有 %d 个（p90 = %.6f），无法算形状" % [highland_cells, p90])
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": "too few highland"}

	# 注意：`comps` 是 Array（元素是 PackedInt32Array，但 Array 的元素类型是 Variant），
	# 所以循环变量必须**显式标注类型**再取 .size() / 下标，否则 Godot 解析器会报
	# 「Cannot infer the type of "sz" variable because the value doesn't have a set type」
	# （Variant 上调用 .size() 的返回类型不可推断）。下同。
	var comps: Array = _components_6(highland, nbr, n)
	var kept_cells := 0
	var kept_comps := 0
	var dropped_comps := 0
	var largest := 0
	for comp_v in comps:
		var comp: PackedInt32Array = comp_v
		var sz: int = comp.size()
		if sz > largest:
			largest = sz
		if sz >= M5_MIN_COMP:
			kept_comps += 1
			kept_cells += sz
		else:
			dropped_comps += 1
	if kept_cells == 0:
		_skip("E", "没有格数 >= %d 的高地连通块（共 %d 块）" % [M5_MIN_COMP, comps.size()])
		return {"ok": false, "seed": seed_v, "w": w, "h": h, "reason": "no big component"}

	var sum_neg := 0.0           # 主口径：只算「内部格」（6 邻全在同一高地块内）
	var sum_neg_top := 0.0
	var sum_neg_all := 0.0       # 字面口径：块内所有格（含边界环）
	var sum_neg_top_all := 0.0
	var flat_by_frac := {}
	for frac in M5B_EPS_SWEEP:
		flat_by_frac["%.2f" % float(frac)] = 0
	var flat_interior := 0
	var interior_cells := 0
	var old_flat := 0
	var eps_primary := M5B_EPS_FRAC * p99
	for comp_v in comps:
		var comp: PackedInt32Array = comp_v
		if comp.size() < M5_MIN_COMP:
			continue
		# 「块内 E 最高 20% 格」= **按数量取 top-K**（K = round(0.2 × 块格数)），不是按阈值取。
		# 为什么必须按数量：平顶块里大量格 E 并列最高，阈值口径会把「并列全算入 top」→ top 集=整块
		# → M5a 恒 1.0，恰好把「平顶」判成「圆顶」，指标自相矛盾。按数量取 K 个，
		# 并列时用「量化高度 × n + 下标」做确定性定序（同值按块内下标），结果可复现。
		var q := PackedInt64Array()
		for idx in comp:
			q.append(int(round(float(elev[idx]) * 1048576.0)) * n + idx)
		q.sort()
		var k_top := maxi(1, int(round(float(comp.size()) * M5_TOP_FRAC)))
		var top_set := {}
		for t in range(q.size() - 1, q.size() - 1 - k_top, -1):
			top_set[int(q[t] % n)] = true
		for idx in comp:
			var e := float(elev[idx])
			var base_i := idx * 6
			var lap := 0.0
			var k := 0
			var nb_high := 0
			var slope := 0.0
			var mn := e
			var mx := e
			for d in range(6):
				var j := nbr[base_i + d]
				if j < 0:
					continue
				var ej := float(elev[j])
				lap += ej
				k += 1
				if highland[j] != 0:
					nb_high += 1
				var s := absf(ej - e)
				if s > slope:
					slope = s
				if ej < mn:
					mn = ej
				if ej > mx:
					mx = ej
			if k > 0:
				lap -= float(k) * e
			else:
				lap = 0.0
			# 内部格：6 邻都存在且都在高地块里。块边界环上的格会拿到「一邻居低、自己高」的
			# 巨大人造假凸性（阈值 p90 把山体截断造成），会把真正山顶的信号淹掉，故单列口径。
			var interior := (k == 6 and nb_high == 6)
			if interior:
				interior_cells += 1
			if lap < 0.0:
				var mag := -lap
				sum_neg_all += mag
				if top_set.has(idx):
					sum_neg_top_all += mag
				if interior:
					sum_neg += mag
					if top_set.has(idx):
						sum_neg_top += mag
			var abs_lap := absf(lap)
			for frac in M5B_EPS_SWEEP:
				var eps_i := float(frac) * p99
				if abs_lap < eps_i and slope < eps_i:
					var key := "%.2f" % float(frac)
					flat_by_frac[key] = int(flat_by_frac[key]) + 1
					if interior and absf(float(frac) - M5B_EPS_FRAC) < 1.0e-9:
						flat_interior += 1
			if (mx - mn) < PLATEAU_RELIEF:
				old_flat += 1
	var m5a := NAN
	if sum_neg > 0.0:
		m5a = sum_neg_top / sum_neg
	var m5a_all := NAN
	if sum_neg_all > 0.0:
		m5a_all = sum_neg_top_all / sum_neg_all
	var m5b := {}
	for key in flat_by_frac:
		m5b[key] = _num(float(int(flat_by_frac[key])) / float(kept_cells))
	var m5b_interior := NAN
	if interior_cells > 0:
		m5b_interior = float(flat_interior) / float(interior_cells)
	var old_rate := float(old_flat) / float(kept_cells)
	var row := {
		"ok": true,
		"seed": seed_v, "w": w, "h": h,
		"land_h_p90": _num(p90),
		"land_h_p99": _num(p99),
		"land_cells": land_vals.size(),
		"highland_cells": highland_cells,
		"components": comps.size(),
		"components_kept": kept_comps,
		"components_dropped": dropped_comps,
		"largest_component": largest,
		"cells_kept": kept_cells,
		"interior_cells": interior_cells,
		"eps_primary": _num(eps_primary),
		"m5a": _num(m5a),
		"m5a_all": _num(m5a_all),
		"m5b_eps001": m5b["0.01"],
		"m5b_eps002": m5b["0.02"],
		"m5b_eps004": m5b["0.04"],
		"m5b_interior_eps002": _num(m5b_interior),
		"m5_old_p90": _num(old_rate),
		"base_ms": gen["base_ms"],
	}
	print("[followup/E] seed=%d %dx%d land_h_p90=%.4f p99=%.4f highland=%d comps=%d kept=%d drop=%d largest=%d interior=%d eps=%.5f M5a=%s M5a_all=%s M5b_1=%s M5b_2=%s M5b_4=%s M5b_int=%s M5_old_p90=%s base=%.1fms"
			% [seed_v, w, h, p90, p99, highland_cells, comps.size(), kept_comps,
			dropped_comps, largest, interior_cells, eps_primary, _fmt(row["m5a"]),
			_fmt(row["m5a_all"]), _fmt(row["m5b_eps001"]), _fmt(row["m5b_eps002"]),
			_fmt(row["m5b_eps004"]), _fmt(row["m5b_interior_eps002"]),
			_fmt(row["m5_old_p90"]), float(gen["base_ms"])])
	return row


# 6 邻连通块（BFS）：返回 Array[PackedInt32Array]，每块是该块格下标（升序入队序）。
func _components_6(flag: PackedByteArray, nbr: PackedInt32Array, n: int) -> Array:
	var visited := PackedByteArray()
	visited.resize(n)
	visited.fill(0)
	var queue := PackedInt32Array()
	var comps: Array = []
	for start in range(n):
		if flag[start] == 0 or visited[start] != 0:
			continue
		queue.resize(0)
		queue.append(start)
		visited[start] = 1
		var comp := PackedInt32Array()
		var head := 0
		while head < queue.size():
			var cur := queue[head]
			head += 1
			comp.append(cur)
			var base_i := cur * 6
			for d in range(6):
				var ni := nbr[base_i + d]
				if ni < 0 or flag[ni] == 0 or visited[ni] != 0:
					continue
				visited[ni] = 1
				queue.append(ni)
		comps.append(comp)
	return comps
