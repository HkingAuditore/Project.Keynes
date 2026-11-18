extends RefCounted

# ─────────────────────────────────────────────────────────────────────────────
# world_fingerprint.gd — 「世界指纹」实现（跟进计划 §2.1 / §2.2，S1）
#
# 规格：docs/plans/terrain-followup-verification-plan.md §2.1（基线）、§2.2（挂到 golden）
# 纯 static 工具，被两处复用：
#   · tests/world/world_fingerprint_test.gd —— 6 个种子（4×60×40 + 2×200×150）的正式门禁
#   · tests/runtime/golden_day_hash_test.gd / golden_external_advancers_test.gd /
#     native_generation_equivalence_test.gd —— §2.2 的轻量前置校验（1×60×40）
#
# 指纹 = 三份东西：
#   1) hashes：5 条 **cell 数组**的 FNV-1a 64（逐字节）。**逐位相同**才算一致：
#      elevation_arr（F32）、terrain_arr（U8）、landform_arr（U8）、
#      has_river_arr（U8）、hydro_parent_arr（I32）
#   2) stats：land_h 分位 + terrain / landform 直方图 + 5 个计数，按**相对容差**比对
#   3) bake：hashes.bake_height（烘焙期像素高度场 height_buffer 的 FNV-1a 64）
#      + stats.bake_h_p50/p90/p99（陆地像素高度分位）。见下方「bake height_buffer」小节。
#
# cfg / profile 缺省与 tests/world/ridge_drainage_metrics_test.gd::_cfg() / _profile()
# 逐键同源（2026-11-18 P5 标定值），这样指纹测的世界与 ridge 指标测的世界是同一个世界。
# 有意改世界的 PR 必须同时改这里的缺省与 tests/world/baselines/world_fingerprint.json
# （计划 §2.1「规则」）。
#
# ── hash 口径 ────────────────────────────────────────────────────────────────
# · FNV-1a 64：offset basis = 0xcbf29ce484222325，prime = 0x100000001b3。
#   GDScript 的 int 是 64 位**有符号**：offset basis 超出 2^63 写不成字面量，也不存在
#   `& 0xFFFFFFFFFFFFFFFF` 这种「无符号截断」。但 GDScript 的整型乘加按 64 位回绕
#   （Godot 不做溢出检查），其 bit pattern 与无符号 FNV-1a 64 **完全一致**，所以这里
#   直接用有符号 int 累积（offset 用「高位 32 位 << 32 | 低位」拼出同一 bit pattern），
#   输出时再用 hex64() 把两个 32 位半区拼成 16 位十六进制串 ⇒ JSON 里全是字符串，
#   没有符号/精度歧义。
# · 只对 `to_byte_array()` 的原始字节做 hash ⇒ 结果**依赖平台字节序与 float32 表示**。
#   与计划 §10 K1 一致：精确 hash 只在同平台 / 同编译配置下比较；
#   其他配置用 `FINGERPRINT_HASH=0` 只比分布统计。
# · `hydro_parent_arr` 是 PackedInt32Array，同样直接 to_byte_array()。
#
# ── 容差口径（stats）────────────────────────────────────────────────────────
# · 高度分位（land_h_p10/p50/p90/p99）：相对容差，缺省 5%。
# · 直方图（terrain_hist / landform_hist，值 → 占比）与计数（river_count 等）：
#   先按期望的 n_cells 折回 cell 数，容差 = max(1 格, 5%) ⇒ 单格抖动不会把门禁打红，
#   成规模的漂移才会红。
# · 缺省容差可用 FINGERPRINT_STAT_TOL 覆盖；hash 比对可用 FINGERPRINT_HASH=0 关掉。
#
# ── status 语义（不假装通过）─────────────────────────────────────────────────
# · skip  ：基线文件缺失 / 解析失败 / 没有该种子的行；拿不到 DCWorldExt。
#           调用方打印 `SKIP reason=...`，**不计失败**。
# · error ：生成失败（rc != 0 或 fallback != false）。合法输入不该失败 ⇒ 调用方计 FAIL。
# · drift ：hash 或 stats 不一致 ⇒ 调用方计 FAIL 并打印 format_report()。
# · ok    ：一致。
#
# ── bake height_buffer（计划 §5.3 / T2，2026-11-18 补）────────────────────────
# 为什么需要它：上面 5 条 hashes 都是 **cell 级**结果，而烘焙期侵蚀/限坡参数
# （dem_spl_*、dem_slope_limit_*、dem_dep_*/dem_floor_*）只在
# run_bake_geometry_fields_pass 里**逐像素**生效，cell 数组完全看不见 ⇒
# 「dem_slope_limit_per_relief 5.0 → 5.1」这类改动这把锁抓不到。这里补一条：
# 对真实链路 base → post_base（填 ext 内部 _gen_river_* 拓扑）→ 融合几何 pass 的
# height_buffer 取 FNV-1a 64（逐字节，同 to_byte_array() 口径），另记陆地像素高度分位。
# knobs 与 tests/world/erosion_spl_bake_test.gd 的 A12 同源 —— A12 已验证跑通这条链路
# （A12 用 dem_erosion_area_dump=1 取 area_hex；本文件不需要，故不开，省一次面积导出）。
#   · 只对 60×40 里的**一个**种子做（BAKE_SEEDS）：像素数只由平台档决定（620,544 px），
#     200×150 的 bake 更慢且不多覆盖；4 个种子按下面的算术会破 1.5 s 预算，取计划 §9 K6
#     的回退档（详见 BAKE_SEEDS 注释的实测参照）。
#   · width/height 固定 **desktop 档**：由常量 BAKE_HM_MAX_DIM=1024 + bounds 长宽比推出，
#     **不读** map_baker.gd::_hm_max_dim() 的平台判断 —— headless / 其他平台下这条指纹
#     必须仍是 desktop 口径，否则基线会随平台漂。
#   · 拿不到（方法未导出 / pass fallback / 键缺失 / 尺寸不符）⇒ 该种子记
#     missing=[bake_height]、ok=false（调用方按既有规则计 ERROR/FAIL，写基线时直接中止）
#     —— **不静默跳过**，否则这把锁会在没人注意时悄悄失去覆盖。
# ─────────────────────────────────────────────────────────────────────────────

const SCHEMA := "world_fingerprint"
const SCHEMA_VERSION := 2   # v2 = 补 hashes.bake_height / stats.bake_h_p* / meta.bake（v1 的键一个没动）
const BASELINE_PATH := "res://tests/world/baselines/world_fingerprint.json"

# 种子集（计划 §2.1；复用 p5_calib 的种子）
const SEED_BASE := 20260718
const W_SMALL := 60
const H_SMALL := 40
const W_LARGE := 200
const H_LARGE := 150
const SEEDS_SMALL := [20260718, 20260719, 20260720, 20260721]
const SEEDS_LARGE := [20260718, 20260719]

const SEA_FALLBACK := 0.64      # 与 ridge_drainage_metrics_test.gd::SEA_FALLBACK 同值
const STAT_TOL_DEFAULT := 0.05  # 计划 §2.1「分布统计（容差比对）」

const HASH_KEYS := ["elevation", "terrain", "landform", "has_river", "hydro_parent"]
const COUNT_STAT_KEYS := ["river_count", "lake_count", "highland_river_count",
		"peak_count", "plateau_count"]
const HEIGHT_STAT_KEYS := ["land_h_p10", "land_h_p50", "land_h_p90", "land_h_p99"]
const HIST_STAT_KEYS := ["terrain_hist", "landform_hist"]

# FNV-1a 64 常量（见文件头「hash 口径」）。
# offset basis 的无符号值是 0xCBF29CE484222325，超过 int64 上限（0x7FFF...），字面量写不出来，
# 也不能靠 `<< 32` 拼装（会依赖移位溢出的实现细节）⇒ 直接写它在有符号 64 位下的值，
# bit pattern 与无符号口径完全一致。prime 0x100000001B3 = 1099511628211 本身在范围内。
const FNV64_OFFSET := -3750763034362895579   # 0xCBF29CE484222325 as int64
const FNV64_PRIME := 0x100000001B3           # 1099511628211


# ═════════════════════════════════════════════════════════════════════════════
# bake height_buffer 的常量（计划 §5.3 / T2）
# ═════════════════════════════════════════════════════════════════════════════

const BAKE_HASH_KEY := "bake_height"
const BAKE_H_STAT_KEYS := ["bake_h_p50", "bake_h_p90", "bake_h_p99"]

# **只烘一个种子 = 计划 §9 K6 的回退档**。算术（都是仓库里的实测值）：
#   · 现有 6 种子 base+post 全测 = 302 ms（本轮实测）；
#   · 1 次 1024×606 的 spl geometry（terrain-index 72 + spl 264.9 + river 12.6 + coast 4.1）
#     = 231.6–312 ms（docs/plans/terrain-erosion-spl-plan.md §1.2 / §5.2，template_debug，
#     同机波动 ±15%）；
#   · 再加 1 次 height_buffer 的 FNV（620,544×4 B = 2.48 MB 的 GDScript 字节循环）。
#   4 种子 ≈ 302 + 4×265 + 4×FNV ⇒ 已破 1.5 s；1 种子 ≈ 302 + 265 + FNV ≈ 0.9 s，留足余量。
#   要扩到更多种子：把本行改成 SEEDS_SMALL（4 个）或直接写种子字面量列表，并**同一提交**
#   用 FINGERPRINT_WRITE=1 重写基线即可，schema 不变（没覆盖的种子只是少一个 bake_height，
#   compare() 对「两边都没有」的项直接跳过，不报 missing）。
const BAKE_SEEDS := [SEED_BASE]

# desktop 档分辨率的唯一来源：**常量**，不是 map_baker.gd::_hm_max_dim()（那个按平台/画质
# 返回 512/1024/2048）。headless 下也必须烘 desktop 档，否则基线与实机烘焙口径不一致。
const BAKE_HM_MAX_DIM := 1024          # map_baker.gd::HM_MAX_DIM_DESKTOP
const BAKE_HEX_SIZE := 22.0            # main.gd / world_runtime_host.gd 的缺省 hex_size
# 以下 7 个是 map_baker.gd 的烘焙常量（第 421–453 行），逐值镜像；改动时两边同步。
const BAKE_RIVER_STROKE_HEX_FACTOR := 0.048   # map_baker.gd::RIVER_STROKE_HEX_FACTOR
const BAKE_SDF_MAX_DIST_PX := 3.5             # map_baker.gd::SDF_MAX_DIST_PX
const BAKE_RIVER_CR_STEP := 12                # map_baker.gd::RIVER_CR_STEP
const BAKE_SHORE_CARVE_AMP := 0.06            # map_baker.gd::SHORE_CARVE_AMP
const BAKE_SHORE_CARVE_BAND := 6              # map_baker.gd::SHORE_CARVE_BAND
const BAKE_COAST_SDF_MAX_DIST_PX := 8.0       # map_baker.gd::COAST_SDF_MAX_DIST_PX
# droplet 常量（生产值；当前 dem_erosion_mode=spl ⇒ C++ 不跑 droplet，这一组只在
# DEM 缺省改回 carve 时才影响结果 —— 那时也要和 map_baker.gd 保持一致）。
const BAKE_DROPLET_KNOBS := {
	"num_drops": 6000, "max_steps": 5, "inertia": 0.10,
	"capacity_factor": 1.5, "min_capacity": 0.01, "deposit_speed": 0.30,
	"erode_speed": 0.10, "evaporation": 0.025, "gravity": 4.0, "brush_radius": 2,
}

# DCTerrainIndexBaker.DEM_DEFAULTS 的镜像（terrain_index_baker.gd:74–146，经
# dem_landform_knobs() 并入融合 pass knobs）。**不 preload 生产脚本**是有意的：指纹测与
# erosion_spl_bake_test.gd::A12 一样坚持「零跨文件依赖」，本文件是 static 工具、要被 4 个
# 测试复用。缺省值变动时同步这张表（C++ 侧缺省与它同值）。project.godot 里没有
# project_keynes/rendering/dem/* 覆盖，所以「表值 = 生产实际值」在当前仓库成立。
const BAKE_DEM_DEFAULTS := {
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


# ═════════════════════════════════════════════════════════════════════════════
# cfg / profile / 种子集
# ═════════════════════════════════════════════════════════════════════════════

# 与 ridge_drainage_metrics_test.gd::_cfg() 逐键一致（宽度/高度/种子按行填）。
static func default_cfg(seed_value: int, w: int, h: int) -> Dictionary:
	return {
		"num_continents": 3,
		"continent_size": 0.9,
		"sea_level": SEA_FALLBACK,
		"river_count": 12,
		"width": w,
		"height": h,
		"seed": seed_value,
	}


# 与 ridge_drainage_metrics_test.gd::_profile() 逐键一致（2026-11-18 P5 标定值）。
# 保留 ridge_debug_dump=1：它让 base pass 额外输出 ridge_add_arr，**不改变任何正式数组**
# （纯诊断），本文件也不 hash 它 —— 留着是为了和 ridge 测试的 profile 逐键同源。
static func default_profile() -> Dictionary:
	return {
		"native_generation_mode": 2,
		"ridge_boost_amp": 0.60,
		"spl_iters": 14,
		"spl_erodibility": 1.2,
		"spl_area_exp": 0.45,
		"spl_uplift_rate": 0.08,
		"spl_ridge_uplift": 0.010,
		"spl_hillslope_diffusion": 0.08,
		"ridge_residual_frac": 0.15,
		"ridge_debug_dump": 1,
	}


# 计划 §2.1 的种子集：4 种子 × 60×40 + 2 种子 × 200×150。
static func seed_set() -> Array:
	var out: Array = []
	for s in SEEDS_SMALL:
		out.append({"seed": int(s), "w": W_SMALL, "h": H_SMALL})
	for s in SEEDS_LARGE:
		out.append({"seed": int(s), "w": W_LARGE, "h": H_LARGE})
	return out


static func row_key(seed_value: int, w: int, h: int) -> String:
	return "%d|%d|%d" % [seed_value, w, h]


static func env_stat_tol() -> float:
	var raw := OS.get_environment("FINGERPRINT_STAT_TOL").strip_edges()
	if raw.is_valid_float():
		return maxf(0.0, raw.to_float())
	return STAT_TOL_DEFAULT


static func env_compare_hashes() -> bool:
	return OS.get_environment("FINGERPRINT_HASH").strip_edges() != "0"


# ═════════════════════════════════════════════════════════════════════════════
# hash（FNV-1a 64）
# ═════════════════════════════════════════════════════════════════════════════

# 64 位有符号 int 累积（语义见文件头）；返回值只有 bit pattern 有意义。
static func fnv1a64(bytes: PackedByteArray) -> int:
	var h := FNV64_OFFSET
	var n := bytes.size()
	for i in range(n):
		h = (h ^ int(bytes[i])) * FNV64_PRIME
	return h


# 把有符号 int64 渲染成无符号 16 位十六进制串（两个 32 位半区拼接，避免负数打印出 '-'）。
static func hex64(value: int) -> String:
	var hi := (value >> 32) & 0xFFFFFFFF
	var lo := value & 0xFFFFFFFF
	return "%08x%08x" % [hi, lo]


# ═════════════════════════════════════════════════════════════════════════════
# bake height_buffer（计划 §5.3 / T2）
# ═════════════════════════════════════════════════════════════════════════════

# 该种子是否要烘一次：只认 seed_set 里的 60×40（计划 §5.3：200×150 的 bake 太慢，
# 且像素数只由平台档决定，200×150 不多覆盖），再与 BAKE_SEEDS 取交集。
static func should_bake(seed_value: int, w: int, h: int) -> bool:
	if w != W_SMALL or h != H_SMALL:
		return false
	for s in BAKE_SEEDS:
		if int(s) == seed_value:
			return true
	return false


# 世界包围盒（= map_baker.gd::compute_world_bounds / surface_baker.gd:848）：
# px = √3·hex·(map_w + 0.5)、py = 1.5·hex·map_h + 0.5·hex，四周各留 2 hex 的烘焙 padding。
static func bake_world_bounds(map_w: int, map_h: int) -> Rect2:
	var px := sqrt(3.0) * BAKE_HEX_SIZE * (float(map_w) + 0.5)
	var py := 1.5 * BAKE_HEX_SIZE * float(map_h) + 0.5 * BAKE_HEX_SIZE
	return Rect2(Vector2(-BAKE_HEX_SIZE * 2.0, -BAKE_HEX_SIZE * 2.0),
			Vector2(px + BAKE_HEX_SIZE * 4.0, py + BAKE_HEX_SIZE * 4.0))


# 长边取 **常量** BAKE_HM_MAX_DIM（desktop 档）、短边按包围盒长宽比、取偶且 >= 256
# ——— 与 terrain_baker.gd::_resolve_hm_size 同式，但 dim_max 是写死的常量。
# 60×40 / hex=22 → bounds 2393.4×1419.0 → aspect 1.687 → **1024×606**（= 生产 desktop 档）。
# 这里**没有**任何平台/画质判断（_hm_max_dim() 会按平台回 512/1024/2048），
# 所以 headless 与其他平台上这条指纹的口径恒定。
static func bake_hm_size(map_w: int, map_h: int) -> Vector2i:
	var bounds := bake_world_bounds(map_w, map_h)
	var hm_w := BAKE_HM_MAX_DIM
	var hm_h := BAKE_HM_MAX_DIM
	if bounds.size.x >= 0.01 and bounds.size.y >= 0.01:
		var aspect := bounds.size.x / bounds.size.y
		if aspect >= 1.0:
			hm_w = BAKE_HM_MAX_DIM
			hm_h = roundi(float(BAKE_HM_MAX_DIM) / aspect)
		else:
			hm_h = BAKE_HM_MAX_DIM
			hm_w = roundi(float(BAKE_HM_MAX_DIM) * aspect)
	hm_w = (hm_w / 2) * 2
	hm_h = (hm_h / 2) * 2
	return Vector2i(maxi(hm_w, 256), maxi(hm_h, 256))


# 融合几何 pass 的完整 knobs：键名与算式逐条对齐生产入口
# terrain_baker.gd::_bake_geometry_fields_native（第 547–587 行），写法同时与
# erosion_spl_bake_test.gd::A12 的 _a12_bake_knobs() 同源（那条链路已验证跑通）。
# cell SoA 直接取 post_base 的 *_arr（生产走 build_cell_inputs(map)，两者同源同值）。
static func bake_knobs(post: Dictionary, seed_value: int, map_w: int, map_h: int,
		hm: Vector2i, sea: float) -> Dictionary:
	var n_cells := map_w * map_h
	var o2i := PackedInt32Array()
	o2i.resize(n_cells)
	for i in range(n_cells):
		o2i[i] = i    # 生成期 cell.index 就是 row*map_w+col（world_ext_generate_base.cpp）
	var bounds := bake_world_bounds(map_w, map_h)
	var inv_world := Vector2(float(hm.x) / bounds.size.x, float(hm.y) / bounds.size.y)
	var stroke_radius_px := maxf(BAKE_HEX_SIZE * BAKE_RIVER_STROKE_HEX_FACTOR * inv_world.x, 0.5)
	var knobs := {
		# 共用几何参数
		"width": int(hm.x), "height": int(hm.y),
		"origin_x": bounds.position.x, "origin_y": bounds.position.y,
		"hex_size": BAKE_HEX_SIZE, "seed": seed_value,
		# terrain-index
		"map_width": map_w, "map_height": map_h, "n_cells": n_cells,
		"size_x": bounds.size.x, "size_y": bounds.size.y,
		"wrap_period_x": float(map_w) * sqrt(3.0) * BAKE_HEX_SIZE,
		"sea_level": sea,
		"cell_elevation": post.get("elevation_arr", PackedFloat32Array()),
		"cell_moisture": post.get("moisture_arr", PackedFloat32Array()),
		"cell_terrain": post.get("terrain_arr", PackedByteArray()),
		"cell_landform": post.get("landform_arr", PackedByteArray()),
		"cell_vegetation": post.get("vegetation_arr", PackedByteArray()),
		"cell_cover": post.get("cover_arr", PackedByteArray()),
		"cell_water_depth": post.get("water_depth_arr", PackedFloat32Array()),
		"offset_to_index": o2i,
		# river SDF
		"inv_world_x": inv_world.x, "inv_world_y": inv_world.y,
		"base_radius_px": stroke_radius_px,
		"sdf_max_dist_px": BAKE_SDF_MAX_DIST_PX,
		"cr_step": BAKE_RIVER_CR_STEP,
		# coast SDF carve
		"shore_carve_amp": BAKE_SHORE_CARVE_AMP,
		"shore_carve_band": BAKE_SHORE_CARVE_BAND,
		"coast_sdf_max_dist_px": BAKE_COAST_SDF_MAX_DIST_PX,
	}
	for key in BAKE_DROPLET_KNOBS:
		knobs[key] = BAKE_DROPLET_KNOBS[key]
	# 侵蚀：dem_* 全走镜像的 DEM 缺省（dem_erosion_mode=spl → 生产路径）。
	# 故意**不**开 dem_erosion_area_dump（那是 A12 取 area_hex_buffer 的诊断开关，本文件不用）。
	for key in BAKE_DEM_DEFAULTS:
		knobs[key] = BAKE_DEM_DEFAULTS[key]
	return knobs


# 跑一次融合几何 pass，量 bake 的 height_buffer。返回：
#   {measured, ok, reason, seed, w, h, ms, hash, land_px, stats{bake_h_p50/p90/p99},
#    mode, grid_w, grid_h, grid_factor, spl_p99_drop}
# · measured=false：该种子不覆盖 bake（不是失败，调用方不记 missing）。
# · measured=true 且 ok=false：**真实缺陷**（方法未导出 / fallback / 键缺失 / 尺寸不符），
#   调用方必须记 missing + error，不能静默跳过。
static func _measure_bake_height(ext: Object, post: Dictionary, seed_value: int,
		map_w: int, map_h: int, sea: float) -> Dictionary:
	var out := {
		"measured": should_bake(seed_value, map_w, map_h),
		"ok": false, "reason": "", "seed": seed_value,
		"w": 0, "h": 0, "ms": -1.0, "hash": "",
		"land_px": 0, "stats": {},
		"mode": "", "grid_w": -1, "grid_h": -1, "grid_factor": -1,
		"spl_p99_drop": -1.0,
	}
	if not bool(out["measured"]):
		out["reason"] = "not_covered"
		return out
	if ext == null or not ext.has_method("run_bake_geometry_fields_pass"):
		out["reason"] = "fused_pass_not_exported"
		return out
	var hm := bake_hm_size(map_w, map_h)
	out["w"] = int(hm.x)
	out["h"] = int(hm.y)
	var n_px := int(hm.x) * int(hm.y)
	var knobs := bake_knobs(post, seed_value, map_w, map_h, hm, sea)
	var t0 := Time.get_ticks_usec()
	var rep_v = ext.call("run_bake_geometry_fields_pass", knobs)
	out["ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	if not (rep_v is Dictionary):
		out["reason"] = "fused_returned_non_dict"
		return out
	var rep: Dictionary = rep_v
	out["mode"] = str(rep.get("erosion_mode", ""))
	out["grid_w"] = int(rep.get("erosion_grid_w", -1))
	out["grid_h"] = int(rep.get("erosion_grid_h", -1))
	out["grid_factor"] = int(rep.get("erosion_grid_factor", -1))
	out["spl_p99_drop"] = float(rep.get("spl_p99_drop", -1.0))
	if bool(rep.get("fallback", true)):
		out["reason"] = "fused_fallback:%s" % str(rep.get("reason", "?"))
		return out
	var height: PackedFloat32Array = rep.get("height_buffer", PackedFloat32Array())
	if height.size() != n_px:
		out["reason"] = "height_buffer_size %d != %d" % [height.size(), n_px]
		return out

	# ① 精确 hash：对整张 height_buffer 逐字节 FNV-1a 64（与 5 条 cell 数组同口径）。
	out["hash"] = hex64(fnv1a64(height.to_byte_array()))

	# ② 陆地像素高度分位：height_buffer 本身就是 0..1 高度场，陆地 = height >= sea_level
	#    （与 _build_stats 的 land_h 同判据）。先 resize 再截断，避免 append 反复扩容。
	var land := PackedFloat32Array()
	land.resize(n_px)
	var m := 0
	for i in range(n_px):
		var v := float(height[i])
		if v >= sea:
			land[m] = v
			m += 1
	out["land_px"] = m
	if m <= 0:
		out["reason"] = "no_land_pixels"
		return out
	land.resize(m)
	land.sort()
	out["stats"] = {
		"bake_h_p50": _num(_percentile(land, 0.50)),
		"bake_h_p90": _num(_percentile(land, 0.90)),
		"bake_h_p99": _num(_percentile(land, 0.99)),
	}
	out["ok"] = true
	return out


# 写进基线 meta 的 bake 摘要（hash 在 hashes.bake_height，这里留一份便于报告/肉眼看基线）。
static func _bake_meta_row(bake: Dictionary) -> Dictionary:
	return {
		"measured": bool(bake.get("measured", false)),
		"ok": bool(bake.get("ok", false)),
		"reason": str(bake.get("reason", "")),
		"hash": str(bake.get("hash", "")),
		"w": int(bake.get("w", 0)), "h": int(bake.get("h", 0)),
		"ms": float(bake.get("ms", -1.0)),
		"land_px": int(bake.get("land_px", 0)),
		"mode": str(bake.get("mode", "")),
		"grid_w": int(bake.get("grid_w", -1)),
		"grid_h": int(bake.get("grid_h", -1)),
		"grid_factor": int(bake.get("grid_factor", -1)),
	}


# ═════════════════════════════════════════════════════════════════════════════
# 单种子测量
# ═════════════════════════════════════════════════════════════════════════════

# 跑 base + post_base 两个原生 pass（+ 需要时再跑一次融合几何 pass 取 bake 高度），
# 返回 {meta, hashes, stats, ok, reason, missing}。
# cfg / profile 传空字典时用与 ridge 测试同源的缺省；bake=false 时**不**烘（precheck 用，
# 让 golden 三个测试保持原来的开销，且它们只关心 cell 级一致性）。
static func compute(ext: Object, seed_value: int, w: int, h: int,
		cfg: Dictionary = {}, profile: Dictionary = {}, bake_enabled: bool = true) -> Dictionary:
	var use_cfg: Dictionary = default_cfg(seed_value, w, h) if cfg.is_empty() else cfg
	var use_profile: Dictionary = default_profile() if profile.is_empty() else profile
	var n := w * h
	var out := {
		"seed": seed_value,
		"w": w,
		"h": h,
		"ok": false,
		"reason": "",
		"missing": [],
		"hashes": {},
		"stats": {},
		"meta": {
			"seed": seed_value, "w": w, "h": h, "n_cells": n,
			"sea_level": float(use_cfg.get("sea_level", SEA_FALLBACK)),
			"base_ms": -1.0, "post_ms": -1.0,
			"cfg": use_cfg, "profile": use_profile,
		},
	}
	if ext == null:
		out["reason"] = "ext_null"
		return out
	if not ext.has_method("run_native_world_generate_base_pass") \
			or not ext.has_method("run_native_world_generate_post_base_pass"):
		out["reason"] = "ext_missing_generation_api"
		return out
	var t0 := Time.get_ticks_usec()
	var base: Dictionary = ext.call("run_native_world_generate_base_pass",
			seed_value, use_cfg, use_profile)
	var base_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	out["meta"]["base_ms"] = base_ms
	if int(base.get("rc", -1)) != 0 or bool(base.get("fallback", true)):
		out["reason"] = "base_failed rc=%d fallback=%s reason=%s" % [
			int(base.get("rc", -1)), str(base.get("fallback", true)),
			str(base.get("reason", ""))]
		return out
	var t1 := Time.get_ticks_usec()
	var post: Dictionary = ext.call("run_native_world_generate_post_base_pass",
			seed_value, use_cfg, use_profile, base)
	out["meta"]["post_ms"] = float(Time.get_ticks_usec() - t1) / 1000.0
	if int(post.get("rc", -1)) != 0 or bool(post.get("fallback", true)):
		out["reason"] = "post_base_failed rc=%d fallback=%s reason=%s" % [
			int(post.get("rc", -1)), str(post.get("fallback", true)),
			str(post.get("reason", ""))]
		return out

	var elevation: PackedFloat32Array = base.get("elevation_arr", PackedFloat32Array())
	var terrain: PackedByteArray = base.get("terrain_arr", PackedByteArray())
	var landform: PackedByteArray = base.get("landform_arr", PackedByteArray())
	var has_river: PackedByteArray = post.get("has_river_arr", PackedByteArray())
	var hydro_parent: PackedInt32Array = post.get("hydro_parent_arr", PackedInt32Array())
	# base pass 与 post_base 都会回传 terrain/landform（post_base 会改写它们）。指纹取 base 的
	# 那一份（= 地形成形后的正式结果）；只有 base 缺失时才退回 post_base，并在 meta.notes 留痕
	# （回退不是「缺数组」，不参与 ok 判定）。
	var notes: Array = []
	if terrain.size() != n:
		terrain = post.get("terrain_arr", PackedByteArray())
		notes.append("terrain_from_post_base")
	if landform.size() != n:
		landform = post.get("landform_arr", PackedByteArray())
		notes.append("landform_from_post_base")
	out["meta"]["notes"] = notes

	var hashes: Dictionary = {}
	var missing: Array = out["missing"]
	_record_hash(hashes, missing, "elevation",
			elevation.to_byte_array(), n * 4)
	_record_hash(hashes, missing, "terrain", terrain, n)
	_record_hash(hashes, missing, "landform", landform, n)
	_record_hash(hashes, missing, "has_river", has_river, n)
	_record_hash(hashes, missing, "hydro_parent", hydro_parent.to_byte_array(), n * 4)
	out["hashes"] = hashes

	var sea := float(out["meta"]["sea_level"])
	out["stats"] = _build_stats(elevation, terrain, landform, post, sea, n)

	# ── bake height_buffer（计划 §5.3）：只对 BAKE_SEEDS 里的 60×40 种子跑一次融合几何 pass ──
	# meta.bake 总是写（未覆盖的种子写 measured=false + reason=not_covered，便于报告里区分
	# 「没覆盖」与「跑了但失败」）。
	var bake: Dictionary
	if bake_enabled:
		bake = _measure_bake_height(ext, post, seed_value, w, h, sea)
	else:
		bake = {
			"measured": false, "ok": false, "reason": "disabled", "seed": seed_value,
			"w": 0, "h": 0, "ms": -1.0, "hash": "", "land_px": 0, "stats": {},
			"mode": "", "grid_w": -1, "grid_h": -1, "grid_factor": -1,
			"spl_p99_drop": -1.0,
		}
	out["meta"]["bake"] = _bake_meta_row(bake)
	if bool(bake.get("measured", false)):
		if bool(bake.get("ok", false)):
			hashes[BAKE_HASH_KEY] = str(bake.get("hash", ""))
			var bstats: Dictionary = bake.get("stats", {})
			for key in BAKE_H_STAT_KEYS:
				out["stats"][key] = bstats.get(key, null)
		else:
			# 跑了却拿不到 ⇒ 真实缺陷（方法未导出 / fallback / 键缺失 / 尺寸不符）：
			# 记 missing + 明确 reason，让 ok=false 走 ERROR/FAIL，写基线时直接中止。
			missing.append(BAKE_HASH_KEY)
			hashes[BAKE_HASH_KEY] = ""
			if str(out["reason"]) == "":
				out["reason"] = "bake_height_failed %s (hm=%dx%d, missing=[%s])" % [
					str(bake.get("reason", "?")), int(bake.get("w", 0)),
					int(bake.get("h", 0)), _join_names(missing)]
	out["hashes"] = hashes

	# ok = 「5 条 hash 全部算得出来」+ base/post 都成功（+ 覆盖到的种子 bake 高度也算得出来）。
	# 少一条就当 error（无法指纹化世界），不把它伪装成 SKIP，否则「世界变了」会被静默吞掉。
	out["ok"] = elevation.size() == n and terrain.size() == n and landform.size() == n \
			and (missing as Array).is_empty()
	if not out["ok"] and str(out["reason"]) == "":
		if not (missing as Array).is_empty():
			out["reason"] = "missing_arrays %s" % _join_names(missing)
		else:
			out["reason"] = "array_size_mismatch elev=%d terrain=%d landform=%d n=%d" % [
				elevation.size(), terrain.size(), landform.size(), n]
	return out


static func _join_names(values: Array) -> String:
	var text := ""
	for value in values:
		text += "%s " % str(value)
	return text.strip_edges()


static func _record_hash(hashes: Dictionary, missing: Array, name: String,
		bytes: PackedByteArray, expected_size: int) -> void:
	if expected_size <= 0 or bytes.size() != expected_size:
		missing.append(name)
		hashes[name] = ""
		return
	hashes[name] = hex64(fnv1a64(bytes))


static func _build_stats(elevation: PackedFloat32Array, terrain: PackedByteArray,
		landform: PackedByteArray, post: Dictionary, sea: float, n: int) -> Dictionary:
	var stats := {
		"land_h_p10": null, "land_h_p50": null, "land_h_p90": null, "land_h_p99": null,
		"terrain_hist": {}, "landform_hist": {},
		"river_count": int(post.get("river_count", -1)),
		"lake_count": int(post.get("lake_count", -1)),
		"highland_river_count": int(post.get("highland_river_count", -1)),
		"peak_count": int(post.get("peak_count", -1)),
		"plateau_count": int(post.get("plateau_count", -1)),
	}
	if elevation.size() == n:
		# land_h = elevation − sea_level，只取陆地格（elevation >= sea，与 ridge 测试同口径）
		var land_h := PackedFloat32Array()
		for i in range(n):
			var e := float(elevation[i])
			if e >= sea:
				land_h.append(e - sea)
		land_h.sort()
		if land_h.size() > 0:
			stats["land_h_p10"] = _num(_percentile(land_h, 0.10))
			stats["land_h_p50"] = _num(_percentile(land_h, 0.50))
			stats["land_h_p90"] = _num(_percentile(land_h, 0.90))
			stats["land_h_p99"] = _num(_percentile(land_h, 0.99))
	stats["terrain_hist"] = _histogram_ratio(terrain)
	stats["landform_hist"] = _histogram_ratio(landform)
	return stats


# u8 数组 → {值字符串: 占比}，只输出非零桶；按键值升序插入（JSON 里也是升序）。
static func _histogram_ratio(values: PackedByteArray) -> Dictionary:
	var out := {}
	var total := values.size()
	if total <= 0:
		return out
	var counts := PackedInt32Array()
	counts.resize(256)
	for i in range(total):
		counts[int(values[i])] += 1
	for k in range(256):
		if counts[k] > 0:
			out[str(k)] = float(counts[k]) / float(total)
	return out


# numpy 口径的线性插值分位（values 必须已升序）。
static func _percentile(values: PackedFloat32Array, q: float) -> float:
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


static func _num(v: float) -> Variant:
	if is_nan(v) or not is_finite(v):
		return null
	return v


# ═════════════════════════════════════════════════════════════════════════════
# 比对
# ═════════════════════════════════════════════════════════════════════════════

# 返回 {ok, hash_diffs:[数组名], stat_diffs:[{key, expected, actual, rel}], missing,
#       config_match, stat_tol, actual, expected}
# · hash 逐位比（compare_hashes=false 时只比 stats，对应计划 §10 K1 的「其他配置」）
# · stats 按容差比（口径见文件头）
static func compare(actual: Dictionary, expected: Dictionary,
		stat_tol: float = STAT_TOL_DEFAULT, compare_hashes: bool = true) -> Dictionary:
	var out := {
		"ok": true,
		"hash_diffs": [],
		"stat_diffs": [],
		"missing": [],
		"config_match": true,
		"stat_tol": stat_tol,
		"actual": actual,
		"expected": expected,
	}
	var a_hashes: Dictionary = actual.get("hashes", {})
	var e_hashes: Dictionary = expected.get("hashes", {})
	for key in HASH_KEYS:
		var k := str(key)
		var av := str(a_hashes.get(k, ""))
		var ev := str(e_hashes.get(k, ""))
		if av == "" or ev == "":
			out["missing"].append(k)
			continue
		if compare_hashes and av != ev:
			out["hash_diffs"].append(k)

	# ── bake_height：严格 hash 比对，与 5 条 cell 数组同一规则 ──
	var e_meta: Dictionary = expected.get("meta", {})
	var a_meta: Dictionary = actual.get("meta", {})
	var a_bake_meta: Dictionary = a_meta.get("bake", {})
	# 差别 ①「两侧都没有」时**跳过**：BAKE_SEEDS 之外的种子本来就不覆盖 bake（meta.bake 里
	#   measured=false），那是设计，不是 missing。只有「基线有 / 实际算不出」或反之才记 missing。
	# 差别 ②precheck 走的是 compute(..., bake=false)（golden 三个测试不为前置校验多付一次
	#   ≈265 ms 的 bake）⇒ 实际侧 reason=disabled 时整项跳过，不制造假的 missing 噪声。
	var bake_skipped := not bool(a_bake_meta.get("measured", false)) \
			and str(a_bake_meta.get("reason", "")) == "disabled"
	var bav := str(a_hashes.get(BAKE_HASH_KEY, ""))
	var bev := str(e_hashes.get(BAKE_HASH_KEY, ""))
	var bake_missing := false
	if bake_skipped:
		pass
	elif bav == "" and bev == "":
		pass
	elif bav == "" or bev == "":
		out["missing"].append(BAKE_HASH_KEY)
		bake_missing = true
	elif compare_hashes and bav != bev:
		out["hash_diffs"].append(BAKE_HASH_KEY)
	out["bake_missing"] = bake_missing
	out["bake_skipped"] = bake_skipped

	out["config_match"] = JSON.stringify(a_meta.get("cfg", {})) == JSON.stringify(e_meta.get("cfg", {})) \
			and JSON.stringify(a_meta.get("profile", {})) == JSON.stringify(e_meta.get("profile", {}))
	var n_cells := float(e_meta.get("n_cells", actual.get("w", 1) * actual.get("h", 1)))
	if n_cells <= 0.0:
		n_cells = 1.0

	var e_flat := _flatten_stats(expected.get("stats", {}))
	var a_flat := _flatten_stats(actual.get("stats", {}))
	var keys: Array = e_flat.keys()
	for key in a_flat.keys():
		if not e_flat.has(key):
			keys.append(key)
	keys.sort()
	for key in keys:
		var k := str(key)
		var has_e := e_flat.has(k)
		var has_a := a_flat.has(k)
		if not has_e and not has_a:
			continue
		# bake 高度分位只在**两侧都有**时比：一侧缺席（基线没重写 / precheck 故意不烘）时
		# 继续比会拿默认 0.0 当期望值 ⇒ 必然 rel=∞ 假漂移。缺席已由上面 bake_height 的 hash
		# 比对记进 missing（precheck 则整项跳过），不在这里重复报。
		if BAKE_H_STAT_KEYS.has(k) and not (has_e and has_a):
			continue
		var e_val := float(e_flat.get(k, 0.0))
		var a_val := float(a_flat.get(k, 0.0))
		var is_cell_count := k.find(".") >= 0 or COUNT_STAT_KEYS.has(k)
		var expected_cells := e_val * (n_cells if k.find(".") >= 0 else 1.0)
		var actual_cells := a_val * (n_cells if k.find(".") >= 0 else 1.0)
		var delta := absf(actual_cells - expected_cells)
		if is_cell_count:
			# 计数 / 直方图：容差 = max(1 格, stat_tol × 期望)
			if delta > maxf(1.0, stat_tol * absf(expected_cells)) + 1.0e-9:
				out["stat_diffs"].append({
					"key": k, "expected": e_val, "actual": a_val,
					"rel": delta / maxf(absf(expected_cells), 1.0), "kind": "count"})
		else:
			# 高度分位：相对容差
			var rel := absf(a_val - e_val) / maxf(absf(e_val), 1.0e-4)
			if rel > stat_tol + 1.0e-9:
				out["stat_diffs"].append({
					"key": k, "expected": e_val, "actual": a_val,
					"rel": rel, "kind": "height"})
	out["ok"] = (out["hash_diffs"] as Array).is_empty() \
			and (out["stat_diffs"] as Array).is_empty()
	return out


# 统计拍平成一维：{key: float}。直方图键写成 "<group>.<值>"，缺席 = 0。
static func _flatten_stats(stats: Dictionary) -> Dictionary:
	var flat := {}
	for key in HEIGHT_STAT_KEYS:
		var k := str(key)
		if stats.has(k) and stats[k] != null:
			flat[k] = float(stats[k])
	# bake 高度分位（height_buffer 陆地像素）：与 land_h_* 同走「高度分位」的相对容差分支
	# （键里没有 "."、也不在 COUNT_STAT_KEYS 里 ⇒ compare() 自动按 height 比）。
	for key in BAKE_H_STAT_KEYS:
		var k := str(key)
		if stats.has(k) and stats[k] != null:
			flat[k] = float(stats[k])
	for key in COUNT_STAT_KEYS:
		var k := str(key)
		if stats.has(k) and stats[k] != null:
			flat[k] = float(stats[k])
	for group in HIST_STAT_KEYS:
		var g := str(group)
		var hist: Dictionary = stats.get(g, {})
		for bucket in hist.keys():
			flat["%s.%s" % [g, str(bucket)]] = float(hist[bucket])
	return flat


# 人能读的摘要：**必须**点名哪个数组 hash 变了、哪个统计差多少。
# 接受 verify()/precheck() 的返回值（含 compare 子字典）或 compare() 的返回值本身。
static func format_report(result: Dictionary) -> String:
	var cmp: Dictionary = result.get("compare", result)
	var lines: Array = []
	var head := "fingerprint"
	if result.has("seed"):
		head = "seed=%d %dx%d" % [int(result.get("seed", -1)),
				int(result.get("w", -1)), int(result.get("h", -1))]
	var tol := float(cmp.get("stat_tol", STAT_TOL_DEFAULT))
	lines.append("%s ok=%s stat_tol=%.1f%%" % [head, str(bool(cmp.get("ok", false))),
			tol * 100.0])
	if not bool(cmp.get("config_match", true)):
		lines.append("  cfg/profile 与基线不同（本身就是漂移来源之一）")
	var hash_diffs: Array = cmp.get("hash_diffs", [])
	if hash_diffs.is_empty():
		lines.append("  hashes: 全部一致（或 FINGERPRINT_HASH=0 未比）")
	else:
		var e_hashes: Dictionary = (cmp.get("expected", {}) as Dictionary).get("hashes", {})
		var a_hashes: Dictionary = (cmp.get("actual", {}) as Dictionary).get("hashes", {})
		for name in hash_diffs:
			var k := str(name)
			lines.append("  hash DRIFT %s: baseline=%s actual=%s" % [
					k, str(e_hashes.get(k, "")), str(a_hashes.get(k, ""))])
	var stat_diffs: Array = cmp.get("stat_diffs", [])
	if stat_diffs.is_empty():
		lines.append("  stats: 全部在容差内")
	else:
		for entry in stat_diffs:
			var d: Dictionary = entry
			lines.append("  stat DRIFT %s: baseline=%.6f actual=%.6f rel=%.2f%% (%s)" % [
					str(d.get("key", "?")), float(d.get("expected", 0.0)),
					float(d.get("actual", 0.0)), float(d.get("rel", 0.0)) * 100.0,
					str(d.get("kind", "?"))])
	var missing: Array = cmp.get("missing", [])
	if not missing.is_empty():
		var names := ""
		for m in missing:
			names += ("%s " % str(m))
		lines.append("  missing: %s" % names.strip_edges())
	# bake height 的覆盖摘要：点名「跑了但失败」和「该种子本来就不覆盖」，与 hash/stats 漂移区分开。
	# precheck（bake=false）整项跳过，不打印，免得把「前置校验故意不烘」说成缺陷。
	var a_row: Dictionary = cmp.get("actual", {})
	var e_row: Dictionary = cmp.get("expected", {})
	var a_row_meta: Dictionary = a_row.get("meta", {})
	var e_row_meta: Dictionary = e_row.get("meta", {})
	var a_bake: Dictionary = a_row_meta.get("bake", {})
	var e_bake: Dictionary = e_row_meta.get("bake", {})
	if not bool(cmp.get("bake_skipped", false)) \
			and (not a_bake.is_empty() or not e_bake.is_empty()):
		lines.append("  bake_height: baseline=%s actual=%s" % [
				_bake_brief(e_bake), _bake_brief(a_bake)])
	return "\n".join(PackedStringArray(lines))


# bake 摘要的一行文本：未覆盖 / 失败原因 / hash 前 8 位 + 尺寸 + 陆地像素数。
static func _bake_brief(entry: Dictionary) -> String:
	if entry.is_empty():
		return "absent"
	if not bool(entry.get("measured", false)):
		return "not-covered(%s)" % str(entry.get("reason", "?"))
	var text := "%s %dx%d land_px=%d" % [
			str(entry.get("hash", "")).substr(0, 8), int(entry.get("w", 0)),
			int(entry.get("h", 0)), int(entry.get("land_px", 0))]
	if not bool(entry.get("ok", false)):
		text += " FAILED(%s)" % str(entry.get("reason", "?"))
	return text


# ═════════════════════════════════════════════════════════════════════════════
# 基线文件读写
# ═════════════════════════════════════════════════════════════════════════════

# 读基线：返回 {ok, reason, doc, rows}；rows = {"seed|w|h": 行}。
static func load_baseline(path: String = BASELINE_PATH) -> Dictionary:
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return {"ok": false, "doc": {}, "rows": {},
			"reason": "baseline missing (run with FINGERPRINT_WRITE=1): %s" % path}
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return {"ok": false, "doc": {}, "rows": {},
			"reason": "baseline unreadable (err=%d): %s" % [FileAccess.get_open_error(), path]}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "doc": {}, "rows": {},
			"reason": "baseline is not a JSON object: %s" % path}
	var doc: Dictionary = parsed
	var rows := {}
	var row_list = doc.get("rows", [])
	if row_list is Array:
		for entry in row_list:
			if not (entry is Dictionary):
				continue
			var row: Dictionary = entry
			var key := row_key(int(row.get("seed", -1)), int(row.get("w", -1)),
					int(row.get("h", -1)))
			rows[key] = row
	if rows.is_empty():
		return {"ok": false, "doc": doc, "rows": {},
			"reason": "baseline has no usable rows: %s" % path}
	return {"ok": true, "doc": doc, "rows": rows, "reason": ""}


static func build_baseline_document(rows: Array) -> Dictionary:
	return {
		"schema": SCHEMA,
		"version": SCHEMA_VERSION,
		"written_utc": Time.get_datetime_string_from_system(true),
		"godot": str(Engine.get_version_info().get("string", "?")),
		"platform": OS.get_name(),
		"hash_algo": "fnv1a-64 over to_byte_array()（只在同平台/同编译配置下比）",
		"stat_tol_default": STAT_TOL_DEFAULT,
		"stat_rule": "高度分位按相对容差；直方图/计数按 cell 数，容差 = max(1 格, tol × 期望)",
		"bake_rule": "hashes.bake_height = 融合几何 pass（base→post_base→run_bake_geometry_fields_pass）"
				+ " 的 height_buffer 整场 FNV-1a-64；stats.bake_h_p50/p90/p99 = 该高度场陆地像素"
				+ "（height >= sea_level）分位，按高度分位的相对容差比。分辨率固定 desktop 档"
				+ "（BAKE_HM_MAX_DIM=1024 常量 + bounds 长宽比 ⇒ 60×40 时为 1024×606），"
				+ "**不读** map_baker.gd::_hm_max_dim() 的平台判断。只覆盖 BAKE_SEEDS 里的种子。",
		"bake_seeds": BAKE_SEEDS,
		"bake_hm_max_dim": BAKE_HM_MAX_DIM,
		"seed_set": seed_set(),
		"row_count": rows.size(),
		"rows": rows,
	}


static func write_baseline(path: String, doc: Dictionary) -> Dictionary:
	var abs_path := ProjectSettings.globalize_path(path)
	var dir := abs_path.get_base_dir()
	if dir != "":
		var err := DirAccess.make_dir_recursive_absolute(dir)
		if err != OK and err != ERR_ALREADY_EXISTS:
			return {"ok": false, "path": abs_path,
				"reason": "mkdir failed err=%d dir=%s" % [err, dir]}
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "path": abs_path, "reason": "open failed err=%d" % FileAccess.get_open_error()}
	f.store_string(JSON.stringify(doc, "  ", false, false) + "\n")
	f.close()
	return {"ok": true, "path": abs_path, "reason": ""}


# ═════════════════════════════════════════════════════════════════════════════
# 校验入口
# ═════════════════════════════════════════════════════════════════════════════

# 拿 ext：优先 host.world_ext()（host 有该方法时），否则 ClassDB.instantiate("DCWorldExt")。
# 也接受「直接传一个已经实例化好的 ext」（测试里 ext 已经在手上时，别再建第二个实例）。
static func resolve_ext(host: Variant = null) -> Object:
	if host != null and host is Object:
		var host_object: Object = host
		if host_object.has_method("run_native_world_generate_base_pass"):
			return host_object
		if host_object.has_method("world_ext"):
			var from_host = host_object.call("world_ext")
			if from_host != null and from_host is Object:
				return from_host as Object
	if ClassDB.class_exists("DCWorldExt"):
		return ClassDB.instantiate("DCWorldExt") as Object
	return null


# 单种子校验：返回 {status, reason, seed, w, h, compare, actual, expected}。
# bake=true 时（正式指纹测）额外比 hashes.bake_height / stats.bake_h_p*；precheck 传 false。
static func verify(ext: Object, seed_value: int, w: int, h: int,
		path: String = BASELINE_PATH, stat_tol: float = STAT_TOL_DEFAULT,
		compare_hashes: bool = true, bake: bool = true) -> Dictionary:
	var head := {"status": "skip", "reason": "", "seed": seed_value, "w": w, "h": h}
	var loaded := load_baseline(path)
	if not bool(loaded.get("ok", false)):
		head["reason"] = str(loaded.get("reason", "baseline missing"))
		return head
	var rows: Dictionary = loaded.get("rows", {})
	var key := row_key(seed_value, w, h)
	if not rows.has(key):
		head["reason"] = "baseline has no row for %s (rows=%d)" % [key, rows.size()]
		return head
	if ext == null:
		head["reason"] = "DCWorldExt unavailable"
		return head
	var actual := compute(ext, seed_value, w, h, {}, {}, bake)
	if not bool(actual.get("ok", false)):
		head["status"] = "error"
		head["reason"] = "generation failed: %s" % str(actual.get("reason", "?"))
		head["actual"] = actual
		return head
	var expected: Dictionary = rows[key]
	var cmp := compare(actual, expected, stat_tol, compare_hashes)
	head["status"] = "ok" if bool(cmp.get("ok", false)) else "drift"
	head["compare"] = cmp
	head["actual"] = actual
	head["expected"] = expected
	return head


# §2.2 用的轻量前置校验：拿 ext + 比 1 个 60×40 种子（缺省 20260718）。
# host 参数可以是 WorldRuntimeHost（走 host.world_ext()），也可以直接是已实例化的 ext。
# 容差与 hash 开关走环境变量，与正式指纹测试同一套口径。
# **不烘 bake height_buffer**：golden / 等价性测试只关心 cell 级一致性，没必要为一个
# 前置校验多付一次 1024×606 融合几何 pass（≈265 ms）；正式门禁由 world_fingerprint_test 跑。
static func precheck(host: Variant = null, seed_value: int = SEED_BASE,
		w: int = W_SMALL, h: int = H_SMALL) -> Dictionary:
	var ext := resolve_ext(host)
	if ext == null:
		return {"status": "skip", "seed": seed_value, "w": w, "h": h,
			"reason": "DCWorldExt unavailable (class missing or instantiate returned null)"}
	return verify(ext, seed_value, w, h, BASELINE_PATH, env_stat_tol(),
			env_compare_hashes(), false)
