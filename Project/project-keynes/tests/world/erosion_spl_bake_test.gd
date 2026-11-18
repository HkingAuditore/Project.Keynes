extends SceneTree

# ─────────────────────────────────────────────────────────────────────────────
# erosion_spl_bake_test.gd — 烘焙期地形侵蚀 SPL 重构（terrain-erosion-spl）A1–A11
#
# 规格：
#   docs/plans/terrain-erosion-spl-plan.md      §3.2 硬不变量 / §4.7 Web 栅格 / §4.11 输出契约 / §8.1 断言表
#   docs/plans/terrain-erosion-spl-contracts.md §5 测试骨架 / §2 pass 内核语义 / §3 融合 pass 接线
#
# 跑法（由 root 统一编译 + 执行；本文件不自行启动 Godot）：
#   godot --headless -s res://tests/world/erosion_spl_bake_test.gd
#
# 被测方法（并行实现，契约 §3.3 / §3.4）：
#   ext.run_bake_erosion_spl_pass(knobs)     → A1–A4 / A6 / A7 / A9–A11
#   ext.run_bake_geometry_fields_pass(knobs) → A5 / A8（融合 pass 的模式分支与回退 hash）
#
# **SKIP 策略（契约 §5 明文要求，不假装通过）**：
#   · 方法未导出（DLL 未重编）或基线 pass 直接 fallback 导致后续断言无从谈起时，
#     用 _skip(tag, reason) 打印 "<An>: SKIP reason=..."，计入 _checks 与 _skips，
#     但**不计失败**；末尾多打一行 "[erosion-spl] skips=N"，root 可区分「全绿」与「被跳过」。
#   · 反向不成立：方法存在但**合法输入下返回 fallback** 属真实缺陷，走 FAIL 而非 SKIP。
#   · 任何断言都**不允许**为了变绿而放宽阈值；每条标签以 "A1:"…"A11:" 开头，便于逐项核对。
#
# 合成地形（全部可解析，不依赖种子程序生成）：
#   · 主地形（A1/A2/A4/A10，A7 用无湖版）128×96、hex_px=17、sea_level=0.64：中央 cos 钟形山体
#     + 两级正弦扰动，外圈落到海面以下形成外海；内陆另挖一个碗形圆湖（与海不连通，
#     A2 用洪泛证明它不与外海连通）以测「水体逐位不变」。
#   · 单坡脊谷场（_sample_ridge）128×96 与 128×80 / 256×160：沿 -y 严格递减 + x 向正弦脊谷，
#     无闭合洼地 ⇒ 汇水面积跨 3 个 decade，用于 A3（谷深–面积）与 A9（分辨率无关）。
#   · 经线周期场（_sample_wrap）128×96、周期 64 列：用于 A6（wrap_cols 别名列/接缝）。
#   · wet = 1 当且仅当 h <= sea + 1e-3；留 5e-4 余量是为了让每个陆地像素的 h_pre 都严格
#     高于 sea+eps，避免 H_pre 落在 (sea, sea+eps] 的退化带（那里不变量 1 与 2 互斥）。
#   · relief = |∇h|（height / hex，hex 空间中心差分）→ 与栅格分辨率无关（计划 §4.2）。
#   · 尺寸都按「测试要快」压到 128×96 / 128×80 / 256×160 / 256×192；A9、A11 保留 2× 倍数
#     关系（计划 §8.1 写 512/1024 与 2048/1024，测试等比缩小但判据不变）。
#
# ── A12 叠加验证（2026-11-18 新增；规格 docs/plans/terrain-followup-verification-plan.md §3，
#   口径与门禁按 docs/plans/terrain-same-caliber-review-plan.md §2.1/§2.2 修正）──
#   「cell 河流是否落进 bake 像素谷」：在**真实生成的地图**（60×40 cell / 桌面 hm 1024×606）上量 X1/X1s/X1r/X3。
#   · 链路：base → post_base（填 ext 内部 _gen_river_* 拓扑）→ run_bake_geometry_fields_pass。
#     **相对门禁**要求比对照，所以同一张 cell 地形跑**两次 bake**：dem_erosion_mode="spl"（现状）与
#     "carve"（旧全序基线），两次只有这一个键不同。river SDF 不依赖高度（world_ext_bake.cpp:1453
#     「不依赖高度，提前算好供汇流刻谷把河道当作出口」）⇒ 两次 flow_buffer 应逐位相同，实测用
#     flow_same 打印佐证（相对门禁成立的前提）。与 tests/world/ridge_drainage_metrics_test.gd::_measure()
#     同源；**不碰** A1–A11 的合成输入。
#   · 河心像素 = flow_buffer >= 0.6（与 carve 的 dem_valley_river_outlet_flow 缺省一致）。
#   · X1（主判据，计划 §2.1 原定义）：河心高度 <= **半径 3 px 圆盘**（dx²+dy² <= 9，排除自身、
#     窗口夹紧到图像边界、跳过水体）内像素高度**中位数** 的比例。门禁是**相对**的：
#     X1(spl) >= X1(carve) - 0.01（同一张新 cell 地形 / 同一 DLL / 同种子，全部参与种子都要满足）。
#   · X1s（只记录）：上一轮口径 = 河心高度 <= 其 7×7（±3 px）**陆地**邻域中位数 的比例。
#     两种口径的唯一差异是窗口形状（方窗 vs 圆盘），中位数比较规则相同 ⇒ 差值即「口径差多少」。
#   · X1r（只记录，连续量）：河心高度在**半径 6 px 圆盘**内像素高度分布中的百分位（mid-rank
#     pct=(lo+hi)/2/n，0 = 圆盘内最低 / 1 = 最高），取全部河心像素的中位数；判据边界附近更稳。
#   · X3 河岸坡对称性（只记录）：河心东西各 4 px 高度差 |Δh| / 局地起伏 的中位数。
#   · **X2 已删除**（2026-11-18，计划 §2.2）：河心像素是 wet 出口，汇水在出口处 continue、面积停在
#     初值 1/hex_px²，「河心汇水低于陆地中位数」是**实现决定的**、不是测出来的 ⇒ 构造上不可测。
#     area_hex_buffer 退化为 spl 侧 aux 诊断（land/river area p50 打印），不参与任何判定；
#     carve 分支不填该诊断（只在 SPL 管线里分配），carve 侧相关打印为 -1。
#   · **绝对阈值 0.95 已取消**（计划 R5）：它来自合成锥坡，对真实地图没有依据。
#   · 缺 flow_buffer / 河心样本 → 打印 "A12: SKIP reason=..." 并计入 skips，**不假装通过**；
#     合法输入下 pass 直接 fallback 属真实缺陷 → FAIL（同下方 SKIP 策略）。
# ─────────────────────────────────────────────────────────────────────────────

const SEA := 0.64                      # sea_level：与计划 §4.10 / carve 缺省同值
const SEA_EPS := 5.0e-4                # 陆地不下海余量（与 bake_dem_landform.h 写回段同值）
const WET_MARGIN := 1.0e-3             # wet 判定余量：陆地因此严格 >= sea + 1e-3
const HEX_PX := 17.0                   # 主地形上「一个 hex 跨度」的像素数
const MAIN_W := 128
const MAIN_H := 96
const LAKE_BOTTOM := 0.615             # 内陆湖底高度（< sea）
const LAKE_R_HW := 5.0 / 17.0          # 湖底半径（hex 单位，= 5 px @ hex_px=17）
const DX := [1, -1, 0, 0, 1, 1, -1, -1]
const DY := [0, 0, 1, -1, 1, -1, 1, -1]
const DL := [1.0, 1.0, 1.0, 1.0, 1.4142135623730951, 1.4142135623730951,
		1.4142135623730951, 1.4142135623730951]

# ── A12（真实地图叠加验证）常量 ───────────────────────────────────────────────
const A12_SEEDS := [20260718, 20260719]      # 计划 §7 T3：先 2 个种子（每种子 2 次 bake）；扩到 4 个只改这一行
const A12_MAP_W := 60
const A12_MAP_H := 40
const A12_HEX_SIZE := 22.0                   # main.gd / world_runtime_host.gd 的缺省 hex_size
const A12_HM_MAX_DIM := 1024                 # map_baker.gd::HM_MAX_DIM_DESKTOP（桌面 1024×606）
const A12_RIVER_FLOW := 0.6                  # 河心判据（carve 的 dem_valley_river_outlet_flow 缺省）
const A12_WIN := 3                           # X1s / X3 的方窗半径 ±3 px ⇒ 7×7（上一轮口径）
const A12_X1_R := 3                          # X1 圆盘半径（px；计划 §2.1 的「3 px 邻域」）
const A12_X1R_R := 6                         # X1r 圆盘半径（px；计划 §2.1）
const A12_SIDE := 4                          # X3 两侧采样距离（px）
const A12_MIN_WINDOW := 9                    # X1s / X3 的 7×7 陆地样本下限（< 9 ⇒ 窗口退化，不计样本）
const A12_MIN_R3 := 9                        # X1 的半径 3 圆盘陆地样本下限（满窗 28 个 ⇒ 32%）
const A12_MIN_R6 := 24                       # X1r 的半径 6 圆盘陆地样本下限（满窗 112 个 ⇒ 21%）
const A12_X1_REL_TOL := 0.01                 # 相对门禁：X1(spl) >= X1(carve) - 0.01（计划 §2.1）
const A12_X1_REL_WARN := 0.03                # spl 比 carve 差超过它 → 打「关注」行（仍按 -0.01 判失败）
const A12_RIVER_STROKE_HEX_FACTOR := 0.048   # map_baker.gd::RIVER_STROKE_HEX_FACTOR
const A12_SDF_MAX_DIST_PX := 3.5             # map_baker.gd::SDF_MAX_DIST_PX
const A12_RIVER_CR_STEP := 12                # map_baker.gd::RIVER_CR_STEP
const A12_SHORE_CARVE_AMP := 0.06            # map_baker.gd::SHORE_CARVE_AMP
const A12_SHORE_CARVE_BAND := 6              # map_baker.gd::SHORE_CARVE_BAND
const A12_COAST_SDF_MAX_DIST_PX := 8.0       # map_baker.gd::COAST_SDF_MAX_DIST_PX
# DCTerrainIndexBaker.DEM_DEFAULTS 的镜像（terrain_index_baker.gd:74–146）。测试不 preload 该脚本
# 是为了「只改一个文件、零跨文件依赖」；缺省值变动时同步这张表（C++ 侧缺省与它同值）。
const A12_DEM_DEFAULTS := {
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

var _checks := 0
var _failures := 0
var _skips := 0
var _ext: Object = null
var _has_spl := false
var _has_fused := false
var _main := {}          # 主合成地形（height / relief / wet）
var _base_knobs := {}    # 基线 knobs（dep 关、限坡缺省、wrap 关）
var _base := {}          # 基线 pass 结果


func _init() -> void:
	_run()
	print("[erosion-spl] skips=%d" % _skips)
	print("[erosion-spl] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect(false, "DCWorldExt is available (DLL 未编入？)")
		return
	_ext = ClassDB.instantiate("DCWorldExt")
	if _ext == null:
		_expect(false, "DCWorldExt can be instantiated")
		return
	_has_spl = _ext.has_method("run_bake_erosion_spl_pass")
	_has_fused = _ext.has_method("run_bake_geometry_fields_pass")
	print("[erosion-spl] methods spl=%s fused=%s" % [_has_spl, _has_fused])
	_prepare()
	_test_a1()
	_test_a2()
	_test_a3()
	_test_a4()
	_test_a5()
	_test_a6()
	_test_a7()
	_test_a8()
	_test_a9()
	_test_a10()
	_test_a11()
	_test_a12()


# 基线：主地形跑一次 SPL 管线，A1/A2/A4/A7/A10 共用（同 knobs 的第一次结果即「P2 基线」）。
func _prepare() -> void:
	if not _has_spl:
		return
	var t0 := Time.get_ticks_msec()
	_main = _sample_massif(MAIN_W, MAIN_H, HEX_PX, true)
	_base_knobs = _spl_knobs(_main, MAIN_W, MAIN_H, HEX_PX, 0)
	_base = _ext.run_bake_erosion_spl_pass(_base_knobs)
	var wall := Time.get_ticks_msec() - t0
	print("[erosion-spl] baseline fallback=%s reason=%s elapsed=%.2fms wall=%dms grid=%dx%d factor=%d p99=%.6f max=%.6f"
			% [bool(_base.get("fallback", true)), str(_base.get("reason", "")),
			float(_base.get("elapsed_ms", -1.0)), wall,
			int(_base.get("erosion_grid_w", -1)), int(_base.get("erosion_grid_h", -1)),
			int(_base.get("erosion_grid_factor", -1)),
			float(_base.get("spl_p99_drop", -1.0)), float(_base.get("spl_max_drop", -1.0))])


# ── A1 不变量 1：全像素 h_out <= h_pre，无 NaN（buffer 与 report 两侧都查）──────────────
func _test_a1() -> void:
	var tag := "A1"
	var label := tag + ": 不变量1 全像素 h_out <= h_pre 且 spl_nan=0、无 NaN"
	if not _has_spl:
		_skip(tag, "run_bake_erosion_spl_pass 未导出（DLL 未重编？）")
		return
	if bool(_base.get("fallback", true)):
		print("[erosion-spl/A1] baseline fallback reason=%s" % str(_base.get("reason", "")))
		_expect(false, label)   # 合法合成输入不应 fallback：真实缺陷
		return
	var h_pre: PackedFloat32Array = _main["height"]
	var h_out: PackedFloat32Array = _base.get("height_out", PackedFloat32Array())
	var size_ok := h_out.size() == h_pre.size()
	var only_down := size_ok
	var nan_buffer := 0
	var max_rise := 0.0
	var changed := 0
	if size_ok:
		for i in range(h_pre.size()):
			var a := float(h_pre[i])
			var b := float(h_out[i])
			if not is_finite(b):
				nan_buffer += 1
				only_down = false
				continue
			if b > a:
				only_down = false
				max_rise = maxf(max_rise, b - a)
			elif b < a:
				changed += 1
	var nan_report := int(_base.get("spl_nan", -1))
	print("[erosion-spl/A1] size_ok=%s nan_buffer=%d nan_report=%d max_rise=%.9f lowered_px=%d"
			% [size_ok, nan_buffer, nan_report, max_rise, changed])
	_expect(only_down and nan_buffer == 0 and nan_report == 0, label)


# ── A2 不变量 2/3：陆地 >= sea+eps；水体与河心像素逐位不变 ───────────────────────────────
func _test_a2() -> void:
	var tag := "A2"
	var label := tag + ": 陆地 >= sea+5e-4 且水体/河心像素逐位不变"
	if _need_baseline(tag):
		return
	var h_pre: PackedFloat32Array = _main["height"]
	var wet: PackedByteArray = _main["wet"]
	var h_out: PackedFloat32Array = _base.get("height_out", PackedFloat32Array())
	var sizes_ok := h_out.size() == h_pre.size() and wet.size() == h_pre.size()
	var land_ok := sizes_ok
	var wet_ok := sizes_ok
	var n_land := 0
	var n_wet := 0
	var n_inland_wet := 0
	var lowest_land := 2.0
	var wet_drift := 0.0
	if sizes_ok:
		var floor_h := SEA + SEA_EPS - 1.0e-9   # 1e-9 = float32 表示余量，不是放宽判据
		for i in range(h_pre.size()):
			if wet[i] != 0:
				n_wet += 1
				var drift := absf(float(h_out[i]) - float(h_pre[i]))
				if drift > 0.0:
					wet_ok = false
					wet_drift = maxf(wet_drift, drift)
			else:
				n_land += 1
				lowest_land = minf(lowest_land, float(h_out[i]))
				if float(h_out[i]) < floor_h:
					land_ok = false
		# 「至少一块内陆水体」：从地图边缘的全部 wet 像素做 4 邻接洪泛，未被洪泛到的 wet 像素
		# 就是与海不连通的内陆湖（本合成地形的圆湖由 _sample_massif 挖出）。没有这一条，
		# 「水体逐位不变」可能只是在海里白测。
		var reached := PackedByteArray()
		reached.resize(h_pre.size())
		var stack := PackedInt32Array()
		for y in range(MAIN_H):
			for x in range(MAIN_W):
				if y != 0 and y != MAIN_H - 1 and x != 0 and x != MAIN_W - 1:
					continue
				var edge_i := y * MAIN_W + x
				if wet[edge_i] != 0 and reached[edge_i] == 0:
					reached[edge_i] = 1
					stack.append(edge_i)
		while stack.size() > 0:
			var cur := stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			var cx := cur % MAIN_W
			var cy := (cur - cx) / MAIN_W
			for k in range(4):
				var nx := cx + (1 if k == 0 else (-1 if k == 1 else 0))
				var ny := cy + (1 if k == 2 else (-1 if k == 3 else 0))
				if nx < 0 or nx >= MAIN_W or ny < 0 or ny >= MAIN_H:
					continue
				var ni := ny * MAIN_W + nx
				if wet[ni] == 0 or reached[ni] != 0:
					continue
				reached[ni] = 1
				stack.append(ni)
		for i in range(h_pre.size()):
			if wet[i] != 0 and reached[i] == 0:
				n_inland_wet += 1
	if lowest_land > 1.5:
		lowest_land = -1.0
	print("[erosion-spl/A2] land=%d wet=%d inland_wet=%d land_ok=%s wet_bitwise=%s wet_drift=%.9f lowest_land=%.6f"
			% [n_land, n_wet, n_inland_wet, land_ok, wet_ok, wet_drift, lowest_land])
	_expect(land_ok and wet_ok and n_land > 0 and n_inland_wet > 0, label)


# ── A3 谷深 vs log(汇水面积)：单坡上 Pearson > 0.8 ────────────────────────────────────
func _test_a3() -> void:
	var tag := "A3"
	var label := tag + ": 单坡 drop vs log(A) Pearson > 0.8（自建 D8 面积代理，pits_in=0）"
	if _need_baseline(tag):
		return
	# 替代判据说明（计划 §8.1 原写「drop vs log(A_hex) 相关 > 0.8」）：
	#   ① pass 的输出契约（plan §4.11 / contracts §3.4）只上报 stats，**不返回 area_hex**，
	#      测试拿不到内部的汇水面积；这里按契约 §2.2 的同一套规则（argmax (z_i-z_nb)/DL、
	#      只接受严格更低、平局取 k 小者）在同一入口高度上重建流树并累加 area_px。
	#      本合成坡严格沿 -y 递减 → 无闭合洼地（pits_in 另行断言为 0，证明代理与 build_flow
	#      的填洼面同树、代理面积 = 内部 A_hex 的常数倍）。Pearson 对 log 底与常数因子不敏感，
	#      因此 area_px 不必换成 hex²。
	#   ② 地形由「单锥坡」改成「沿 y 单向下坡 + x 向正弦脊谷」（任务允许锥体/山脊二选一）：
	#      纯轴对称锥体的流线是放射状、几乎不合并，汇水面积只在 O(r) 内变化（< 2 个 decade），
	#      而 drop ∝ A^0.45 是凹函数 —— 与 log A 的线性相关理论上只有 0.4~0.6，测不到 SPL 的
	#      A–谷深关系。改成能沿谷合并汇流的单坡后 logA 跨 3 个 decade（q50≈6 px, q99≈760 px）。
	#   ③ knobs 全部用计划 §4.10 的缺省值（k=0.03 / iters=6 / m=0.45 / min_area=0.03 /
	#      限坡 5.0），不做任何「为了变绿」的放宽：本场 relief≈0.06~0.09，缺省坡限 s≈0.02/px
	#      远高于实际坡度 ≈0.004/px，限坡天然不触发，drop 就是纯 SPL 下切。
	var field := _sample_ridge(MAIN_W, MAIN_H, HEX_PX, 0.22, 0.008, 6, 0.001, 1.6, 0.90)
	var knobs := _spl_knobs(field, MAIN_W, MAIN_H, HEX_PX, 0)
	var rep: Dictionary = _ext.run_bake_erosion_spl_pass(knobs)
	if bool(rep.get("fallback", true)):
		print("[erosion-spl/A3] pass fallback reason=%s" % str(rep.get("reason", "")))
		_expect(false, label)
		return
	var h_pre: PackedFloat32Array = field["height"]
	var h_out: PackedFloat32Array = rep.get("height_out", PackedFloat32Array())
	var n := h_pre.size()
	if h_out.size() != n:
		_expect(false, label)
		return
	var area := _area_proxy_px(h_pre, MAIN_W, MAIN_H)
	var xs := PackedFloat32Array()
	var ys := PackedFloat32Array()
	xs.resize(n)
	ys.resize(n)
	var biggest := 1.0
	for i in range(n):
		xs[i] = log(maxf(float(area[i]), 1.0))
		ys[i] = maxf(float(h_pre[i]) - float(h_out[i]), 0.0)
		biggest = maxf(biggest, float(area[i]))
	var corr := _pearson(xs, ys)
	var pits_in := int(rep.get("pits_in", -1))
	var pits_ok := pits_in == 0        # 无洼地 = 代理树与 build_flow 的填洼面同构
	print("[erosion-spl/A3] pearson=%.4f max_area_px=%.0f pits_in=%d p99=%.6f max_drop=%.6f"
			% [corr, biggest, pits_in, float(rep.get("spl_p99_drop", -1.0)),
			float(rep.get("spl_max_drop", -1.0))])
	_expect(corr > 0.8 and pits_ok, label)


# ── A4 确定性：同 knobs 两次结果逐元素相等 ───────────────────────────────────────────
func _test_a4() -> void:
	var tag := "A4"
	var label := tag + ": 确定性 同 knobs 两次 height_out 逐位相等"
	if _need_baseline(tag):
		return
	var again: Dictionary = _ext.run_bake_erosion_spl_pass(_base_knobs)
	var a: PackedFloat32Array = _base.get("height_out", PackedFloat32Array())
	var b: PackedFloat32Array = again.get("height_out", PackedFloat32Array())
	var same := a.size() == b.size()
	var first_diff := 0.0
	if same:
		for i in range(a.size()):
			if float(a[i]) != float(b[i]):
				same = false
				first_diff = maxf(first_diff, absf(float(a[i]) - float(b[i])))
	print("[erosion-spl/A4] same=%s hash_a=%08x hash_b=%08x max_diff=%.9f"
			% [same, _hash32(a), _hash32(b), first_diff])
	_expect(not bool(again.get("fallback", true)) and same, label)


# ── A5 线程/任务无关：融合 pass 重复调用逐位相等（契约 §5 允许的退化判据）──────────────────
func _test_a5() -> void:
	var tag := "A5"
	var label := tag + ": 融合 pass(spl) 两次 height_buffer 逐位相等（任务数不可控时的退化判据）"
	if not _has_fused:
		_skip(tag, "run_bake_geometry_fields_pass 未导出（DLL 未重编？）")
		return
	# 计划 §8.1 A5 要求「融合 pass 内真并行的部分（terrain-index、放大）用 1/N 任务数各跑一次」。
	# 现状：任务数由 world_ext_bake.cpp 的 bake_row_tasks(rows) = min(16, rows/8) 按行数决定，
	# **没有 knobs 入口**，测试无法从外部指定 1/N；按契约 §5「若不可控则断言两次融合 pass 结果
	# 逐位相等」退化。为避免「两次都 fallback」的空断言，同时要求侵蚀阶段真的执行了
	# （erosion_mode=spl、erosion_ok、flow_ms>=0）。
	var knobs := _fused_knobs({"dem_erosion_mode": "spl"})
	var a: Dictionary = _ext.run_bake_geometry_fields_pass(knobs)
	var b: Dictionary = _ext.run_bake_geometry_fields_pass(knobs)
	var fallback_a := bool(a.get("fallback", true))
	var fallback_b := bool(b.get("fallback", true))
	var ha: PackedFloat32Array = a.get("height_buffer", PackedFloat32Array())
	var hb: PackedFloat32Array = b.get("height_buffer", PackedFloat32Array())
	var same := ha.size() == hb.size() and ha.size() > 0 and ha == hb
	var mode := str(a.get("erosion_mode", ""))
	var ran := bool(a.get("erosion_ok", false)) and float(a.get("flow_ms", -1.0)) >= 0.0
	print("[erosion-spl/A5] fallback=%s/%s mode=%s erosion_ok=%s flow_ms=%.2f same=%s hash=%08x"
			% [fallback_a, fallback_b, mode, bool(a.get("erosion_ok", false)),
			float(a.get("flow_ms", -1.0)), same, _hash32(ha)])
	if fallback_a or fallback_b:
		print("[erosion-spl/A5] reason=%s / %s"
				% [str(a.get("reason", "")), str(b.get("reason", ""))])
	_expect(not fallback_a and not fallback_b and mode == "spl" and ran and same, label)


# ── A6 经线接缝：wrap_cols 开启时别名列（首末列）与周期本体逐位一致 < 2e-6 ────────────────
func _test_a6() -> void:
	var tag := "A6"
	var label := tag + ": wrap_cols 经线接缝 首末列（别名列）差 < 2e-6"
	if _need_baseline(tag):
		return
	# 栅格布局与 carve / SPL 同一约定（contracts §3.2-2）：前 wrap_cols 列是一个经线周期，
	# 其后列 x 是 x-wrap_cols 的别名列。输入按 x % period 采样 → 别名列与本体逐位相同；
	# 输出也必须逐位相同（管线里是「先紧凑成周期本体算、写回时别名列按 delta 复制」）。
	var period := 64
	var field := _sample_wrap(MAIN_W, MAIN_H, period, HEX_PX)
	var knobs := _spl_knobs(field, MAIN_W, MAIN_H, HEX_PX, period)
	var rep: Dictionary = _ext.run_bake_erosion_spl_pass(knobs)
	if bool(rep.get("fallback", true)):
		print("[erosion-spl/A6] pass fallback reason=%s" % str(rep.get("reason", "")))
		_expect(false, label)
		return
	var h_pre: PackedFloat32Array = field["height"]
	var h_out: PackedFloat32Array = rep.get("height_out", PackedFloat32Array())
	if h_out.size() != h_pre.size():
		_expect(false, label)
		return
	var seam := 0.0
	var changed := 0
	for y in range(MAIN_H):
		var row := y * MAIN_W
		for x in range(MAIN_W):
			var i := row + x
			if absf(float(h_out[i]) - float(h_pre[i])) > 0.0:
				changed += 1
			if x >= period:
				var j := row + (x % period)   # 周期本体里的同位置
				seam = maxf(seam, absf(float(h_out[i]) - float(h_out[j])))
	print("[erosion-spl/A6] period=%d wrap_cols=%d seam_max=%.9f lowered_px=%d grid=%dx%d factor=%d"
			% [period, period, seam, changed, int(rep.get("erosion_grid_w", -1)),
			int(rep.get("erosion_grid_h", -1)), int(rep.get("erosion_grid_factor", -1))])
	_expect(seam < 2.0e-6 and changed > 0, label)


# ── A7 限坡：per_relief 调小 → 最大邻格坡度下降；per_relief 极大 → 与无限制坡逐位相等 ────────
func _test_a7() -> void:
	var tag := "A7"
	var label := tag + ": 限坡 per_relief 调小 → 最大邻格坡度下降；per_relief 极大 → 与无限制坡逐位相等"
	if _need_baseline(tag):
		return
	# 主地形带内陆湖 → 湖岸是水/陆边界（水体既不改也不作约束源），会在陆侧留下一道陡坎，
	# 会污染「最大邻格坡度」这个判据，所以 A7 用同一个解析场的无湖版本（整幅只有海/陆平滑过渡）。
	#
	# 另一处必须隔离的变量是 dem_slope_limit_cap_per_relief（单像素削减上限 cap = cap×relief）：
	# 山脊顶/峰顶的 relief→0 ⇒ cap→0 ⇒ 峰顶几乎不许削，而它旁边 relief 较大的像素会被削下去，
	# 结果「per_relief 调小」反而在峰顶制造陡坎、最大邻格坡度变大（实测 cap=1.4 时 0.0248 vs
	# 0.0108）。A7 的命题是 per_relief 的作用，所以两组都把 cap 放到极大（恒不触发），
	# 只改 per_relief —— 这是隔离变量，不是放宽判据。
	var field := _sample_massif(MAIN_W, MAIN_H, HEX_PX, false)
	var tight_knobs := _spl_knobs(field, MAIN_W, MAIN_H, HEX_PX, 0)
	tight_knobs["dem_slope_limit_per_relief"] = 0.3
	tight_knobs["dem_slope_limit_cap_per_relief"] = 1.0e6
	var loose_knobs := _spl_knobs(field, MAIN_W, MAIN_H, HEX_PX, 0)
	loose_knobs["dem_slope_limit_per_relief"] = 1.0e6
	loose_knobs["dem_slope_limit_cap_per_relief"] = 1.0e6
	var huge_knobs := _spl_knobs(field, MAIN_W, MAIN_H, HEX_PX, 0)
	huge_knobs["dem_slope_limit_per_relief"] = 1.0e9
	huge_knobs["dem_slope_limit_cap_per_relief"] = 1.0e6
	var tight: Dictionary = _ext.run_bake_erosion_spl_pass(tight_knobs)
	var loose: Dictionary = _ext.run_bake_erosion_spl_pass(loose_knobs)
	var huge: Dictionary = _ext.run_bake_erosion_spl_pass(huge_knobs)
	var fallback_any := bool(tight.get("fallback", true)) or bool(loose.get("fallback", true)) \
			or bool(huge.get("fallback", true))
	if fallback_any:
		print("[erosion-spl/A7] pass fallback reason=%s"
				% str(tight.get("reason", "")))
		_expect(false, label)
		return
	var h_tight: PackedFloat32Array = tight.get("height_out", PackedFloat32Array())
	var h_loose: PackedFloat32Array = loose.get("height_out", PackedFloat32Array())
	var h_huge: PackedFloat32Array = huge.get("height_out", PackedFloat32Array())
	var slope_tight := _slope_max(h_tight, MAIN_W, MAIN_H, false)
	var slope_loose := _slope_max(h_loose, MAIN_W, MAIN_H, false)
	var extremes_equal := h_loose.size() == h_huge.size() and h_loose == h_huge
	print("[erosion-spl/A7] slope_tight=%.6f slope_loose=%.6f ratio=%.3f per_relief→1e6/1e9 bitwise=%s"
			% [slope_tight, slope_loose, slope_tight / maxf(slope_loose, 1.0e-9), extremes_equal])
	_expect(slope_tight < slope_loose - 1.0e-6 and extremes_equal, label)


# ── A8 回退：carve 模式不跑 SPL 且两次逐位相同；缺省（不传 knob）与显式 carve 一致 ────────────
func _test_a8() -> void:
	var tag := "A8"
	var label := tag + ": carve 回退 两次逐位相等 + mode=carve + SPL 未执行 + 缺省==显式 carve"
	if not _has_fused:
		_skip(tag, "run_bake_geometry_fields_pass 未导出（DLL 未重编？）")
		return
	# 契约 §5 的 A8：无法在测试内跑固定 seed 的 MapBaker 基线 → 退化为结构性断言
	# 「两次调用逐位相同 + erosion_mode=="carve" + valley_ms>=0 且 spl_p99_drop<0」，
	# 并打印 FNV-1a 32-bit hash 供 root 与改动前基线 DLL 的 hash 比对（逐位回退的最终门禁）。
	# 追加一条契约 §3.1/§3.2-7 的直接证据：**不传 dem_erosion_mode**（C++ 缺省恒 carve）
	# 与显式 "carve" 必须给出同一份 height_buffer。
	var carve := _fused_knobs({"dem_erosion_mode": "carve"})
	var a: Dictionary = _ext.run_bake_geometry_fields_pass(carve)
	var b: Dictionary = _ext.run_bake_geometry_fields_pass(carve)
	var c: Dictionary = _ext.run_bake_geometry_fields_pass(_fused_knobs({}))
	var fallback_a := bool(a.get("fallback", true))
	var fallback_b := bool(b.get("fallback", true))
	var fallback_c := bool(c.get("fallback", true))
	var ha: PackedFloat32Array = a.get("height_buffer", PackedFloat32Array())
	var hb: PackedFloat32Array = b.get("height_buffer", PackedFloat32Array())
	var hc: PackedFloat32Array = c.get("height_buffer", PackedFloat32Array())
	var mode := str(a.get("erosion_mode", ""))
	var valley_ms := float(a.get("valley_ms", -1.0))
	var p99 := float(a.get("spl_p99_drop", 0.0))
	var hash_a := _hash32(ha)
	var hash_b := _hash32(hb)
	var hash_c := _hash32(hc)
	print("[erosion-spl/A8] mode=%s valley_ms=%.2f spl_p99_drop=%.3f carve_hash=%08x repeat=%08x default_hash=%08x"
			% [mode, valley_ms, p99, hash_a, hash_b, hash_c])
	print("[erosion-spl/A8] fill_ms=%.2f mfd_ms=%.2f wall_ms=%.2f carve_ms=%.2f"
			% [float(a.get("fill_ms", -1.0)), float(a.get("mfd_ms", -1.0)),
			float(a.get("wall_ms", -1.0)), float(a.get("carve_ms", -1.0))])
	var ok := not fallback_a and not fallback_b and not fallback_c \
			and ha.size() > 0 and ha == hb and hash_a == hash_c \
			and mode == "carve" and valley_ms >= 0.0 and p99 < 0.0
	_expect(ok, label)


# ── A9 分辨率无关：同一解析地形两档栅格，delta 相关 > 0.85、p99 差 < 20% ─────────────────
func _test_a9() -> void:
	var tag := "A9"
	var label := tag + ": 分辨率无关 delta 相关 > 0.85 且 p99 下切量相差 < 20%"
	if _need_baseline(tag):
		return
	# 计划 §8.1 A9 写 512 / 1024；测试等比缩小到 128×80 @ hex_px=17 与 256×160 @ hex_px=34：
	# 两者覆盖**同一物理世界**（7.5×4.7 hex，像素密度 2×），判据不变。hex_px 随分辨率翻倍
	# 正是「参数以 hex 为单位」的实现方式（计划 §4.2），因此 delta 应当宏观一致。
	# 地形用「沿 y 单向下坡 + x 向 8 条正弦脊谷」的全陆解析坡（无海/湖 wet 边界）：
	# 海岸线的 wet 阈值在像素级抖动会改变出口集合、进而改变流向树，把「算法分辨率无关性」
	# 淹在「合成场在海陆边界上的抽签噪声」里（实测 massif 场 corr 只有 0.65）；全陆坡上的
	# 汇流格局由大尺度脊谷决定，两档分辨率给出同一套水系，才能测到算法本身。
	var lo_w := 128
	var lo_h := 80
	var lo_hex := 17.0
	var hi_w := lo_w * 2
	var hi_h := lo_h * 2
	var hi_hex := lo_hex * 2.0
	var lo_field := _sample_ridge(lo_w, lo_h, lo_hex, 0.20, 0.010, 8, 0.0006, 4.0, 0.88)
	var hi_field := _sample_ridge(hi_w, hi_h, hi_hex, 0.20, 0.010, 8, 0.0006, 4.0, 0.88)
	var lo_rep: Dictionary = _ext.run_bake_erosion_spl_pass(
			_spl_knobs(lo_field, lo_w, lo_h, lo_hex, 0))
	var hi_rep: Dictionary = _ext.run_bake_erosion_spl_pass(
			_spl_knobs(hi_field, hi_w, hi_h, hi_hex, 0))
	if bool(lo_rep.get("fallback", true)) or bool(hi_rep.get("fallback", true)):
		print("[erosion-spl/A9] pass fallback reason=%s / %s"
				% [str(lo_rep.get("reason", "")), str(hi_rep.get("reason", ""))])
		_expect(false, label)
		return
	var lo_delta: PackedFloat32Array = _drop(lo_field["height"],
			lo_rep.get("height_out", PackedFloat32Array()))
	var hi_delta: PackedFloat32Array = _drop(hi_field["height"],
			hi_rep.get("height_out", PackedFloat32Array()))
	if lo_delta.size() != lo_w * lo_h or hi_delta.size() != hi_w * hi_h:
		_expect(false, label)
		return
	var hi_at_lo := _downsample_box_f32(hi_delta, hi_w, hi_h, 2)
	var corr := _pearson(hi_at_lo, lo_delta)
	var p99_lo := _p99(lo_delta)
	var p99_hi := _p99(hi_delta)
	var rel := absf(p99_hi - p99_lo) / maxf(maxf(p99_hi, p99_lo), 1.0e-9)
	print("[erosion-spl/A9] corr=%.4f p99_lo=%.6f p99_hi=%.6f rel=%.3f grid=%dx%d/%dx%d"
			% [corr, p99_lo, p99_hi, rel,
			int(lo_rep.get("erosion_grid_w", -1)), int(lo_rep.get("erosion_grid_h", -1)),
			int(hi_rep.get("erosion_grid_w", -1)), int(hi_rep.get("erosion_grid_h", -1))])
	_expect(corr > 0.85 and rel < 0.2, label)


# ── A10 沉积：deposited <= eroded、pits_out <= pits_in、h<=h_pre；dep 关 → 逐位回到基线 ──────
func _test_a10() -> void:
	var tag := "A10"
	var label := tag + ": 沉积 deposited<=eroded、pits_out<=pits_in、h<=h_pre；dep=false 逐位回到基线"
	if _need_baseline(tag):
		return
	var on_knobs := _base_knobs.duplicate()
	on_knobs["dem_dep_enabled"] = true
	on_knobs["dem_erosion_pit_audit"] = true
	var off_knobs := _base_knobs.duplicate()
	off_knobs["dem_dep_enabled"] = false
	off_knobs["dem_erosion_pit_audit"] = true
	var dep: Dictionary = _ext.run_bake_erosion_spl_pass(on_knobs)
	var off: Dictionary = _ext.run_bake_erosion_spl_pass(off_knobs)
	if bool(dep.get("fallback", true)) or bool(off.get("fallback", true)):
		print("[erosion-spl/A10] pass fallback reason=%s / %s"
				% [str(dep.get("reason", "")), str(off.get("reason", ""))])
		_expect(false, label)
		return
	var eroded := float(dep.get("eroded_vol", -1.0))
	var deposited := float(dep.get("deposited_vol", -1.0))
	var pits_in := int(dep.get("pits_in", -1))
	var pits_out := int(dep.get("pits_out", -1))
	var h_pre: PackedFloat32Array = _main["height"]
	var h_dep: PackedFloat32Array = dep.get("height_out", PackedFloat32Array())
	var no_rise := h_dep.size() == h_pre.size()
	if no_rise:
		for i in range(h_pre.size()):
			if float(h_dep[i]) > float(h_pre[i]):
				no_rise = false
				break
	var h_off: PackedFloat32Array = off.get("height_out", PackedFloat32Array())
	var h_base: PackedFloat32Array = _base.get("height_out", PackedFloat32Array())
	var back_to_base := h_off.size() == h_base.size() and h_off == h_base
	var diff_px := 0
	if h_dep.size() == h_base.size():
		for i in range(h_base.size()):
			if float(h_dep[i]) != float(h_base[i]):
				diff_px += 1
	print("[erosion-spl/A10] eroded=%.6f deposited=%.6f pits_in=%d pits_out=%d h<=h_pre=%s dep_off==base=%s dep_changed_px=%d dep_ms=%.2f"
			% [eroded, deposited, pits_in, pits_out, no_rise, back_to_base, diff_px,
			float(dep.get("dep_ms", -1.0))])
	_expect(deposited <= eroded and pits_out <= pits_in and no_rise and back_to_base, label)


# ── A11 Web 计算栅格：max_dim 下采样路径 == 「先盒式下采样再原生烘焙」+ 放大写回 ──────────────
func _test_a11() -> void:
	var tag := "A11"
	var label := tag + ": 2048+max_dim 路径与「先下采样再原生烘焙」+delta 双线性放大写回一致"
	if _need_baseline(tag):
		return
	# 计划 §8.1 A11 写「2048 输入 + dem_erosion_max_dim=1024」；测试等比缩小为
	# 256×192 @ hex_px=34 + max_dim=128（factor 同为 2），判据不变。做法：
	#   A 组：256×192 输入 + max_dim=128 → 管线内部盒式下采样到 128×96、算完再把 delta↑ 放大写回；
	#   B 组：用**同一套盒式下采样规则**把 A 的输入降到 128×96（hex_px=17），原生烘焙（factor=1）；
	#   断言：两组计算栅格尺寸相同、A 的结果 == 用 B 的 delta 按契约 §2.2 的 upsample 语义
	#        放大后写回的高度（容差 2e-6 = float32 双精度中间量末位差，不是放宽判据）。
	# 用 wrap（整幅为一个经线周期）避开 upsample 在非周期栅格上的边缘列特殊处理路径。
	var hi_w := 256
	var hi_h := 192
	var hi_hex := 34.0
	var factor := 2
	var lo_w := hi_w / factor
	var lo_h := hi_h / factor
	var lo_hex := hi_hex / factor
	var hi_field := _sample_massif(hi_w, hi_h, hi_hex, false)
	var auto_knobs := _spl_knobs(hi_field, hi_w, hi_h, hi_hex, hi_w)
	auto_knobs["dem_erosion_max_dim"] = lo_w
	var auto_rep: Dictionary = _ext.run_bake_erosion_spl_pass(auto_knobs)
	# B 组输入 = 管线内部的同一套下采样规则（contracts §2.2 downsample_box_f32 / _u8）
	var lo_height := _downsample_box_f32(hi_field["height"], hi_w, hi_h, factor)
	var lo_relief := _downsample_box_f32(hi_field["relief"], hi_w, hi_h, factor)
	var lo_wet := _downsample_box_u8(hi_field["wet"], hi_w, hi_h, factor)
	var lo_field := {"height": lo_height, "relief": lo_relief, "wet": lo_wet}
	var native_knobs := _spl_knobs(lo_field, lo_w, lo_h, lo_hex, lo_w)
	native_knobs["dem_erosion_max_dim"] = 0
	var native_rep: Dictionary = _ext.run_bake_erosion_spl_pass(native_knobs)
	if bool(auto_rep.get("fallback", true)) or bool(native_rep.get("fallback", true)):
		print("[erosion-spl/A11] pass fallback reason=%s / %s"
				% [str(auto_rep.get("reason", "")), str(native_rep.get("reason", ""))])
		_expect(false, label)
		return
	var same_grid := int(auto_rep.get("erosion_grid_w", -1)) == int(native_rep.get("erosion_grid_w", -1)) \
			and int(auto_rep.get("erosion_grid_h", -1)) == int(native_rep.get("erosion_grid_h", -1)) \
			and int(auto_rep.get("erosion_grid_factor", -1)) == factor \
			and int(native_rep.get("erosion_grid_factor", -1)) == 1 \
			and int(native_rep.get("erosion_grid_w", -1)) == lo_w \
			and int(native_rep.get("erosion_grid_h", -1)) == lo_h
	# B 组 delta → 按契约 §2.2 的 upsample 语义放大 → 用管线 §3.2-4 的写回规则复原 A 组应得的高度
	var lo_delta := _drop(lo_height, native_rep.get("height_out", PackedFloat32Array()))
	var delta_hi := _upsample_bilinear(lo_delta, lo_w, lo_h, factor, hi_w, hi_h)
	var expect_hi := _writeback(hi_field["height"], hi_field["wet"], delta_hi)
	var h_auto: PackedFloat32Array = auto_rep.get("height_out", PackedFloat32Array())
	var worst := 0.0
	if h_auto.size() == expect_hi.size():
		for i in range(h_auto.size()):
			worst = maxf(worst, absf(float(h_auto[i]) - float(expect_hi[i])))
	else:
		worst = 1.0e9
	print("[erosion-spl/A11] same_grid=%s factor=%d/%d grid=%dx%d worst=%.9f upsample_ms=%.2f"
			% [same_grid, int(auto_rep.get("erosion_grid_factor", -1)),
			int(native_rep.get("erosion_grid_factor", -1)),
			int(auto_rep.get("erosion_grid_w", -1)), int(auto_rep.get("erosion_grid_h", -1)),
			worst, float(auto_rep.get("upsample_ms", -1.0))])
	_expect(same_grid and worst < 2.0e-6, label)


# ═════════════════════════════════════════════════════════════════════════════
# A12 叠加验证：cell 河流是否落进 bake 像素谷（计划 §3 X1–X3；口径按 §2.1 修正、X2 删除）
#
# 口径（全部只用 bake 输出，不复制 C++ 算法）：
#   · 空间：真实链路 base → post_base → run_bake_geometry_fields_pass ×2（spl / carve），地图 60×40 cell、
#     桌面 hm 1024×606（HM_MAX_DIM_DESKTOP）；像素索引 i = y * hm_w + x。
#   · 水体：biome_buffer[i] ∈ {0,1,18,19,20,21}（pk_is_water_terrain 同集合，与融合 pass 构造
#     侵蚀出口集合 wet 用的是同一判据）。水体高度不代表河谷 ⇒ 三种邻域（圆盘 3 / 方窗 7×7 / 圆盘 6）、
#     局地起伏、X3 两侧采样点都把它剔除。
#   · 河心：flow_buffer[i] >= 0.6（river SDF 归一化 1=河上、0=离河 >= SDF_MAX_DIST_PX）。
#   · X1（主判据）：半径 3 px 圆盘（dx²+dy² <= 9、**排除自身**、越界样本跳过、跳过水体）的陆地高度
#     **中位数** >= 自身高度 ⇒ 计 hit。样本数 < A12_MIN_R3 的河心像素不进分子分母。
#   · X1s（只记录）：上一轮口径逐字保留 —— 7×7 方窗（±3 px，排除自身、跳过水体/越界）陆地中位数，
#     样本数 < A12_MIN_WINDOW 不计。**与 X1 唯一的差异是窗口形状**，因此 X1−X1s 即口径差。
#   · X1r（只记录）：半径 6 圆盘（同样排除自身/跳过水体/夹紧边界）内的高度升序分布上取
#     mid-rank 百分位 pct = (lower_bound + upper_bound) / 2 / n（并列值算同一位），
#     0 = 圆盘内最低、1 = 最高；再对全部河心像素取中位数。样本 < A12_MIN_R6 的进 x1r_skip。
#     ⚠ 方向：河在谷里 ⇒ pct 偏小（计划 §10 G3 的验收写「<= 0.25」），所以 X1r **越小越好**。
#   · X3（只记录）：河心东西各 4 px 的 |Δh| / 局地起伏；局地起伏 = 与 X1s 同一 7×7 陆地邻域的
#     高度 range（计划 §3 允许 dem_relief_buffer 或 ±3px range，取后者以保证与 X1s 同窗口可复算）。
#     ⚠ 口径提示（记录项，非门禁）：东西向采样对**南北走向**的河段量的是跨谷两侧（正是「河贴
#     谷壁」想看的量），对**东西走向**的河段量的是沿河方向的高低差（与谷壁无关，偏小）。
#   · 边界：三种窗口一律**跳过越界样本**（窗口夹紧到图像边界，不复制边缘像素，避免边界重复加权）；
#     x < 4 或 x >= hm_w-4 的河心像素没有 X3 两侧样本 ⇒ 计入 x3_edge，不进 X3 样本。
#   · 中位数：偶数个样本取中间两个的算术平均（标准定义，_a12_median）。
#   · 相对门禁：同种子 X1(spl) >= X1(carve) - A12_X1_REL_TOL（0.01），全部 A12_SEEDS 都满足才 PASS；
#     若 X1(spl) 比 X1(carve) 差超过 A12_X1_REL_WARN（0.03）另打一行「关注」，但门禁仍按 0.01 判。
#   · 打印格式固定（lead 用同一探针跑旧地形对照）：
#       [erosion-spl/A12] seed=20260718 mode=spl   X1=... X1s=... X1r=... X3=... n_px=... n_x1=...
#       [erosion-spl/A12] seed=20260718 mode=carve X1=... X1s=... X1r=... X3=... n_px=... n_x1=...
#       [erosion-spl/A12/rel] seed=20260718 X1_spl=... X1_carve=... X1_diff=... gate=... pass=...
#       [erosion-spl/A12/aux] ...（诊断，不参与判定）
#       [erosion-spl/A12/mean] n_seeds=2 n_rel_ok=2 X1_spl=... X1_carve=... X1_diff_min=...
# ═════════════════════════════════════════════════════════════════════════════

func _test_a12() -> void:
	var tag := "A12"
	# 显式 String（不靠 := 推断 "String % Array" 的返回类型，避免 Variant 推断歧义）。
	var label: String = tag + ": 河心落谷率相对门禁 X1(spl) >= X1(carve) - %.2f（半径 %d px 圆盘陆地中位数）" \
			% [A12_X1_REL_TOL, A12_X1_R]
	if not _has_fused:
		_skip(tag, "run_bake_geometry_fields_pass 未导出（DLL 未重编？）")
		return
	if not _ext.has_method("run_native_world_generate_base_pass") \
			or not _ext.has_method("run_native_world_generate_post_base_pass"):
		_skip(tag, "真实生成链路方法缺失（run_native_world_generate_base_pass / post_base_pass 未导出）")
		return
	var rows: Array = []
	var skip_reason := ""
	var fatal_reason := ""
	for seed_v in A12_SEEDS:
		var r: Dictionary = _a12_measure(int(seed_v))
		rows.append(r)
		if bool(r.get("ok", false)):
			var spl: Dictionary = r["spl"]
			var carve: Dictionary = r["carve"]
			var d_x1 := float(spl["x1"]) - float(carve["x1"])
			var d_x1r := float(spl["x1r"]) - float(carve["x1r"])
			var d_x1s := float(spl["x1s"]) - float(carve["x1s"])
			print("[erosion-spl/A12] seed=%d mode=spl   X1=%.4f X1s=%.4f X1r=%.4f X3=%.4f n_px=%d n_x1=%d n_x1r=%d"
					% [int(seed_v), float(spl["x1"]), float(spl["x1s"]), float(spl["x1r"]),
					float(spl["x3"]), int(spl["n_riv"]), int(spl["x1_n"]), int(spl["x1r_n"])])
			print("[erosion-spl/A12] seed=%d mode=carve X1=%.4f X1s=%.4f X1r=%.4f X3=%.4f n_px=%d n_x1=%d n_x1r=%d"
					% [int(seed_v), float(carve["x1"]), float(carve["x1s"]), float(carve["x1r"]),
					float(carve["x3"]), int(carve["n_riv"]), int(carve["x1_n"]), int(carve["x1r_n"])])
			print("[erosion-spl/A12/rel] seed=%d X1_spl=%.4f X1_carve=%.4f X1_diff=%.4f gate=%.4f pass=%s X1r_diff=%.4f X1s_diff=%.4f"
					% [int(seed_v), float(spl["x1"]), float(carve["x1"]), d_x1, -A12_X1_REL_TOL,
					str(d_x1 >= -A12_X1_REL_TOL), d_x1r, d_x1s])
			print("[erosion-spl/A12/aux] seed=%d hm=%dx%d hex_px=%.2f land_px=%d wet_px=%d river_px=%d x1_miss=%d/%d x1s_miss=%d/%d x1r_skip=%d/%d x3_n=%d x3_edge=%d x3_water=%d x3_flat=%d land_area_p50=%.5f river_area_p50=%.5f grid=%dx%d factor=%d mode=%s/%s flow_same=%s wall_ms=%.0f bake_ms_spl=%.0f bake_ms_carve=%.0f"
					% [int(seed_v), int(r["hm_w"]), int(r["hm_h"]), float(r["hex_px"]),
					int(spl["n_land"]), int(spl["n_wet"]), int(spl["n_riv"]),
					int(spl["x1_miss"]), int(carve["x1_miss"]),
					int(spl["x1s_miss"]), int(carve["x1s_miss"]),
					int(spl["x1r_skip"]), int(carve["x1r_skip"]),
					int(spl["x3_n"]), int(spl["x3_edge"]), int(spl["x3_water"]), int(spl["x3_flat"]),
					float(spl["land_area_p50"]), float(spl["river_area_p50"]),
					int(r["grid_w"]), int(r["grid_h"]), int(r["factor"]),
					str(r["mode_spl"]), str(r["mode_carve"]), str(r["flow_same"]),
					float(r["wall_ms"]), float(r["wall_ms_spl"]), float(r["wall_ms_carve"])])
			if d_x1 < -A12_X1_REL_WARN:
				print("[erosion-spl/A12] A12: 关注 spl 比 carve 差 >%.2f seed=%d X1_spl=%.4f X1_carve=%.4f X1_diff=%.4f（门禁按 -%.2f 判，这种差必然 FAIL）"
						% [A12_X1_REL_WARN, int(seed_v), float(spl["x1"]), float(carve["x1"]),
						d_x1, A12_X1_REL_TOL])
		else:
			print("[erosion-spl/A12/aux] seed=%d ok=false stage=%s reason=%s"
					% [int(seed_v), str(r.get("stage", "?")), str(r.get("reason", "?"))])
			if bool(r.get("fatal", false)):
				if fatal_reason == "":
					fatal_reason = "seed=%d %s: %s" % [int(seed_v),
							str(r.get("stage", "?")), str(r.get("reason", "?"))]
			elif skip_reason == "":
				skip_reason = "seed=%d %s: %s" % [int(seed_v),
						str(r.get("stage", "?")), str(r.get("reason", "?"))]
	var n_ok := 0
	var n_rel_ok := 0
	var sum_x1_spl := 0.0
	var sum_x1_carve := 0.0
	var sum_x1s_spl := 0.0
	var sum_x1s_carve := 0.0
	var sum_x1r_spl := 0.0
	var sum_x1r_carve := 0.0
	var min_diff := 1.0e9
	var n_px_total := 0
	var flow_same_all := true
	for r in rows:
		if not bool(r.get("ok", false)):
			continue
		var spl: Dictionary = r["spl"]
		var carve: Dictionary = r["carve"]
		var d_x1 := float(spl["x1"]) - float(carve["x1"])
		n_ok += 1
		if d_x1 >= -A12_X1_REL_TOL:
			n_rel_ok += 1
		min_diff = minf(min_diff, d_x1)
		flow_same_all = flow_same_all and bool(r.get("flow_same", false))
		sum_x1_spl += float(spl["x1"])
		sum_x1_carve += float(carve["x1"])
		sum_x1s_spl += float(spl["x1s"])
		sum_x1s_carve += float(carve["x1s"])
		sum_x1r_spl += float(spl["x1r"])
		sum_x1r_carve += float(carve["x1r"])
		n_px_total += int(spl["n_riv"])
	if n_ok > 0:
		var inv_n := 1.0 / float(n_ok)
		print("[erosion-spl/A12/mean] n_seeds=%d n_rel_ok=%d X1_spl=%.4f X1_carve=%.4f X1s_spl=%.4f X1s_carve=%.4f X1r_spl=%.4f X1r_carve=%.4f X1_diff_min=%.4f gate_min=%.4f flow_same=%s river_px_total=%d"
				% [n_ok, n_rel_ok, sum_x1_spl * inv_n, sum_x1_carve * inv_n,
				sum_x1s_spl * inv_n, sum_x1s_carve * inv_n,
				sum_x1r_spl * inv_n, sum_x1r_carve * inv_n,
				min_diff, -A12_X1_REL_TOL, str(flow_same_all), n_px_total])
	if fatal_reason != "":
		print("[erosion-spl/A12] FAIL reason=%s" % fatal_reason)
		# 合法输入下 pass fallback / 尺寸错位 / 模式未分派 = 真实缺陷（文件头 SKIP 策略），不能当 SKIP 放过。
		_expect(false, label)
		return
	if skip_reason != "":
		_skip(tag, skip_reason)
		return
	_expect(n_ok == A12_SEEDS.size() and n_rel_ok == A12_SEEDS.size() and n_px_total > 0, label)


# 单种子真实链路：base → post_base → bake×2（spl 现状 + carve 对照）→ X1/X1s/X1r/X3。
# 返回 {ok, fatal, stage, reason, spl{...}, carve{...}, ...}；ok=false 时 stage 指出断在哪一步。
# 两次 bake 只有 dem_erosion_mode 一个键不同（同一张 cell 地形、同一 DLL、同种子）⇒ 相对门禁只反映
# 侵蚀模式差，不含生成/地表差异。knobs 必须每次新构造：C++ 融合 pass 会往传入的 Dictionary 里写
# height_buffer / biome_buffer（world_ext_bake.cpp:1599/1654），复用同一个 dict 会污染第二次调用。
func _a12_measure(seed_v: int) -> Dictionary:
	var out := {"ok": false, "fatal": false, "stage": "", "reason": "",
			"hm_w": 0, "hm_h": 0, "hex_px": 0.0,
			"grid_w": -1, "grid_h": -1, "factor": -1,
			"mode_spl": "", "mode_carve": "", "flow_same": false,
			"wall_ms": 0.0, "wall_ms_spl": 0.0, "wall_ms_carve": 0.0,
			"spl": {}, "carve": {}}
	var t0 := Time.get_ticks_msec()
	var bounds := _a12_bounds()
	var hm := _a12_hm_size(bounds)
	var n_pix := int(hm.x) * int(hm.y)
	out["hm_w"] = int(hm.x)
	out["hm_h"] = int(hm.y)
	out["hex_px"] = A12_HEX_SIZE * sqrt(3.0) / (bounds.size.x / float(hm.x))
	var cfg := _a12_cfg(seed_v)
	var profile := _a12_profile()
	# ① base：真实程序生成（种子 → 大陆/高程/气候/地形）
	var base_v = _ext.call("run_native_world_generate_base_pass", seed_v, cfg, profile)
	if not (base_v is Dictionary):
		out["stage"] = "base"
		out["reason"] = "run_native_world_generate_base_pass 未返回 Dictionary"
		out["fatal"] = true
		return out
	var base: Dictionary = base_v
	if int(base.get("rc", -1)) != 0 or bool(base.get("fallback", true)):
		out["stage"] = "base"
		out["reason"] = "rc=%d fallback=%s reason=%s" % [int(base.get("rc", -1)),
				str(bool(base.get("fallback", true))), str(base.get("reason", ""))]
		out["fatal"] = true
		return out
	# ② post_base：填 ext 内部 _gen_river_* 拓扑（river SDF 的 flow 前置），并产出最终 cell SoA
	var post_v = _ext.call("run_native_world_generate_post_base_pass", seed_v, cfg, profile, base)
	if not (post_v is Dictionary):
		out["stage"] = "post_base"
		out["reason"] = "run_native_world_generate_post_base_pass 未返回 Dictionary"
		out["fatal"] = true
		return out
	var post: Dictionary = post_v
	if int(post.get("rc", -1)) != 0 or bool(post.get("fallback", true)):
		out["stage"] = "post_base"
		out["reason"] = "rc=%d fallback=%s reason=%s" % [int(post.get("rc", -1)),
				str(bool(post.get("fallback", true))), str(post.get("reason", ""))]
		out["fatal"] = true
		return out
	# ③ bake 前的 cell SoA 尺寸校验（post_base 的输出就是 bake 的输入）。
	# 尺寸不足说明 DLL 版本不匹配 ⇒ SKIP（不是缺陷）
	var n_cells := A12_MAP_W * A12_MAP_H
	var cell_elev: PackedFloat32Array = post.get("elevation_arr", PackedFloat32Array())
	var cell_moist: PackedFloat32Array = post.get("moisture_arr", PackedFloat32Array())
	var cell_terr: PackedByteArray = post.get("terrain_arr", PackedByteArray())
	var cell_veg: PackedByteArray = post.get("vegetation_arr", PackedByteArray())
	var cell_cov: PackedByteArray = post.get("cover_arr", PackedByteArray())
	if cell_elev.size() < n_cells or cell_moist.size() < n_cells \
			or cell_terr.size() < n_cells or cell_veg.size() < n_cells \
			or cell_cov.size() < n_cells:
		out["stage"] = "post_base/cell_soa"
		out["reason"] = "cell SoA 过短（elev=%d moist=%d terr=%d veg=%d cov=%d < %d）" % [
				cell_elev.size(), cell_moist.size(), cell_terr.size(), cell_veg.size(),
				cell_cov.size(), n_cells]
		return out
	# ③ 两次 bake 几何场（terrain-index → 侵蚀 spl / carve → river SDF → latitude）。
	#    carve 那次只需要 height_buffer + flow_buffer：river SDF 在侵蚀之前算、不依赖高度，两次 bake
	#    各自算一份（成本 = 一次 SDF，不额外单跑 pass），用 flow_same 证明两份逐位相同。
	var knobs_spl := _a12_bake_knobs(post, seed_v, hm, bounds, "spl")
	var t_spl := Time.get_ticks_msec()
	var rep_spl_v = _ext.call("run_bake_geometry_fields_pass", knobs_spl)
	out["wall_ms_spl"] = float(Time.get_ticks_msec() - t_spl)
	if not (rep_spl_v is Dictionary):
		out["stage"] = "bake/spl"
		out["reason"] = "run_bake_geometry_fields_pass(spl) 未返回 Dictionary"
		out["fatal"] = true
		return out
	var rep_spl: Dictionary = rep_spl_v
	var knobs_carve := _a12_bake_knobs(post, seed_v, hm, bounds, "carve")
	var t_carve := Time.get_ticks_msec()
	var rep_carve_v = _ext.call("run_bake_geometry_fields_pass", knobs_carve)
	out["wall_ms_carve"] = float(Time.get_ticks_msec() - t_carve)
	if not (rep_carve_v is Dictionary):
		out["stage"] = "bake/carve"
		out["reason"] = "run_bake_geometry_fields_pass(carve) 未返回 Dictionary"
		out["fatal"] = true
		return out
	var rep_carve: Dictionary = rep_carve_v
	out["wall_ms"] = float(Time.get_ticks_msec() - t0)
	# 模式分派自检：DLL 必须真的按 dem_erosion_mode 走了两条分支。若两边返回同一个模式串
	# （旧 DLL 不认这个 knob），相对门禁会退化成恒真式 ⇒ 按真实缺陷 FAIL，不假装通过。
	out["mode_spl"] = str(rep_spl.get("erosion_mode", ""))
	out["mode_carve"] = str(rep_carve.get("erosion_mode", ""))
	if str(out["mode_spl"]) != "spl" or str(out["mode_carve"]) != "carve":
		out["stage"] = "bake/erosion_mode"
		out["reason"] = "dem_erosion_mode 未按预期分派（spl=%s carve=%s，DLL 未重编？）⇒ spl-vs-carve 相对门禁无意义" % [
				str(out["mode_spl"]), str(out["mode_carve"])]
		out["fatal"] = true
		return out
	# grid/factor 只有 spl 分支有（carve 的 erosion_grid_* 恒 -1，见 world_ext_bake.cpp:1783–1785）
	out["grid_w"] = int(rep_spl.get("erosion_grid_w", -1))
	out["grid_h"] = int(rep_spl.get("erosion_grid_h", -1))
	out["factor"] = int(rep_spl.get("erosion_grid_factor", -1))
	var ev_spl := _a12_state_of_report(rep_spl, n_pix, hm, "spl")
	var ev_carve := _a12_state_of_report(rep_carve, n_pix, hm, "carve")
	out["spl"] = ev_spl.get("st", {})
	out["carve"] = ev_carve.get("st", {})
	if not bool(ev_spl.get("ok", false)):
		out["stage"] = str(ev_spl.get("stage", ""))
		out["reason"] = str(ev_spl.get("reason", ""))
		out["fatal"] = bool(ev_spl.get("fatal", false))
		return out
	if not bool(ev_carve.get("ok", false)):
		out["stage"] = str(ev_carve.get("stage", ""))
		out["reason"] = str(ev_carve.get("reason", ""))
		out["fatal"] = bool(ev_carve.get("fatal", false))
		return out
	# 相对门禁的前提证据：两次 bake 的 river SDF 逐位相同 ⇒ 河心像素集合一致、X1 可直接相减。
	out["flow_same"] = _hash32(rep_spl.get("flow_buffer", PackedFloat32Array())) \
			== _hash32(rep_carve.get("flow_buffer", PackedFloat32Array()))
	out["ok"] = true
	return out


# 圆盘邻域样本：dx*dx + dy*dy <= r*r 的像素高度（**排除自身**；越界样本跳过 = 窗口夹紧到图像边界、
# 不复制边缘像素；跳过水体）。Packed*Array 按值传递，所以在函数内新建并返回，不能靠调用方预分配 buffer。
func _a12_disk_samples(height: PackedFloat32Array, water: PackedByteArray,
		w: int, h: int, cx: int, cy: int, r: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var r2 := r * r
	for dy in range(-r, r + 1):
		var yy := cy + dy
		if yy < 0 or yy >= h:
			continue
		var row := yy * w
		for dx in range(-r, r + 1):
			if dx == 0 and dy == 0:
				continue
			if dx * dx + dy * dy > r2:
				continue
			var xx := cx + dx
			if xx < 0 or xx >= w:
				continue
			var j := row + xx
			if water[j] != 0:
				continue
			out.append(float(height[j]))
	return out


# X1/X1s/X1r/X3 的纯计算（输入只有 bake 输出与尺寸；旧地形对照可直接复用这一份口径）。
# 2026-11-18 改口径（计划 §2.1）：X1 = 半径 3 px 圆盘陆地邻域中位数（主判据）、
# X1s = 上一轮的 7×7 方窗中位数（只记录）、X1r = 半径 6 px 圆盘内的百分位中位数（只记录）。
# **X2 已删除**：河心像素是 wet 出口，汇水在出口 continue、area 停在初值 ⇒ 构造上不可测（计划 §2.2）。
# area 可为空（carve 分支不导出 area_hex_buffer），此时 area 诊断项给 -1，不影响 X1/X1s/X1r/X3。
func _a12_state(height: PackedFloat32Array, flow: PackedFloat32Array,
		area: PackedFloat32Array, biome: PackedByteArray, w: int, h: int) -> Dictionary:
	var n := w * h
	var has_area := area.size() == n
	var st := {"n_wet": 0, "n_land": 0, "n_riv": 0,
			"x1": 0.0, "x1s": 0.0, "x1r": 0.0, "x3": 0.0,
			"x1_n": 0, "x1_miss": 0, "x1s_n": 0, "x1s_miss": 0,
			"x1r_n": 0, "x1r_skip": 0,
			"x3_n": 0, "x3_edge": 0, "x3_water": 0, "x3_flat": 0,
			"land_area_p50": -1.0, "river_area_p50": -1.0}
	var water := PackedByteArray()
	water.resize(n)
	var land_area := PackedFloat32Array()
	var riv := PackedInt32Array()
	var n_wet := 0
	for i in range(n):
		# pk_is_water_terrain（world_ext_internal.h:306）：0 海洋 / 1 海岸 / 18 湖 / 19 礁 /
		# 20 海藻 / 21 海冰。水体高度不代表河谷 ⇒ 所有邻域样本与局地起伏都剔掉。
		var t := int(biome[i])
		if t == 0 or t == 1 or t == 18 or t == 19 or t == 20 or t == 21:
			water[i] = 1
			n_wet += 1
		elif has_area:
			land_area.append(float(area[i]))
		if float(flow[i]) >= A12_RIVER_FLOW:
			riv.append(i)
	land_area.sort()
	var n_land := n - n_wet
	var n_riv := riv.size()
	st["n_wet"] = n_wet
	st["n_land"] = n_land
	st["n_riv"] = n_riv
	if n_land == 0 or n_riv == 0:
		return st
	if has_area:
		# X2 删除后 area 只作 aux 诊断：陆地 / 河心 area_hex 中位数（对照上一轮打印量的量级）。
		st["land_area_p50"] = _a12_median(land_area)
		var river_area := PackedFloat32Array()
		for k in range(n_riv):
			river_area.append(float(area[riv[k]]))
		st["river_area_p50"] = _a12_median(river_area)
	var buf := PackedFloat32Array()
	var pcts := PackedFloat32Array()
	var ratios := PackedFloat32Array()
	var x1_hit := 0
	var n_x1 := 0
	var x1s_hit := 0
	var n_x1s := 0
	var n_x1r := 0
	var x1r_skip := 0
	var x3_edge := 0
	var x3_water := 0
	var x3_flat := 0
	for k in range(n_riv):
		var idx := riv[k]
		var x := idx % w
		var y := (idx - x) / w
		var self_h := float(height[idx])
		# ── X1s（上一轮口径，只记录）：7×7 方窗（排除自身；越界样本跳过；跳过水体）→ 中位数 + 局地起伏 ──
		buf.clear()
		var lo_h := 1.0e30
		var hi_h := -1.0e30
		for dy in range(-A12_WIN, A12_WIN + 1):
			var yy := y + dy
			if yy < 0 or yy >= h:
				continue
			var row := yy * w
			for dx in range(-A12_WIN, A12_WIN + 1):
				if dx == 0 and dy == 0:
					continue
				var xx := x + dx
				if xx < 0 or xx >= w:
					continue
				var j := row + xx
				if water[j] != 0:
					continue
				var v := float(height[j])
				buf.append(v)
				if v < lo_h:
					lo_h = v
				if v > hi_h:
					hi_h = v
		if buf.size() >= A12_MIN_WINDOW:
			n_x1s += 1
			if self_h <= _a12_median(buf):
				x1s_hit += 1
		# ── X1（主判据）：半径 3 px 圆盘（排除自身 / 跳过水体 / 夹紧边界）中位数 ──
		var disk3 := _a12_disk_samples(height, water, w, h, x, y, A12_X1_R)
		if disk3.size() >= A12_MIN_R3:
			n_x1 += 1
			if self_h <= _a12_median(disk3):
				x1_hit += 1
		# ── X1r（只记录）：半径 6 px 圆盘内的 mid-rank 百分位（0 = 最低 / 1 = 最高）──
		var disk6 := _a12_disk_samples(height, water, w, h, x, y, A12_X1R_R)
		if disk6.size() >= A12_MIN_R6:
			disk6.sort()
			var rank_lo := _a12_lower_bound(disk6, self_h)
			var rank_hi := _a12_upper_bound(disk6, self_h)
			pcts.append((float(rank_lo) + float(rank_hi)) * 0.5 / float(disk6.size()))
			n_x1r += 1
		else:
			x1r_skip += 1
		# ── X3：东西各 4 px 高度差 / 同一 7×7 陆地邻域的局地起伏 ──
		if x < A12_SIDE or x >= w - A12_SIDE:
			x3_edge += 1
			continue
		var jl := idx - A12_SIDE
		var jr := idx + A12_SIDE
		if water[jl] != 0 or water[jr] != 0:
			x3_water += 1
			continue
		var relief := hi_h - lo_h
		if relief <= 1.0e-6:
			x3_flat += 1
			continue
		ratios.append(absf(float(height[jr]) - float(height[jl])) / relief)
	st["x1_n"] = n_x1
	st["x1_miss"] = n_x1 - x1_hit
	st["x1s_n"] = n_x1s
	st["x1s_miss"] = n_x1s - x1s_hit
	st["x1r_n"] = n_x1r
	st["x1r_skip"] = x1r_skip
	st["x3_n"] = ratios.size()
	st["x3_edge"] = x3_edge
	st["x3_water"] = x3_water
	st["x3_flat"] = x3_flat
	st["x1"] = float(x1_hit) / float(maxi(n_x1, 1))
	st["x1s"] = float(x1s_hit) / float(maxi(n_x1s, 1))
	st["x1r"] = _a12_median(pcts)
	st["x3"] = _a12_median(ratios)
	return st


# 单次 bake 报告 → 口径指标（尺寸校验 + _a12_state）。mode 只用于 stage 命名。
# height/flow/biome 尺寸不符 = 真实缺陷（fatal）；缺 flow_buffer / 河心样本 = 探针无法测量（SKIP）。
func _a12_state_of_report(rep: Dictionary, n_pix: int, hm: Vector2i, mode: String) -> Dictionary:
	var out := {"ok": false, "fatal": false, "stage": "", "reason": "", "st": {}}
	if bool(rep.get("fallback", true)):
		out["stage"] = "bake/" + mode + "/fallback"
		out["reason"] = "fallback reason=%s" % str(rep.get("reason", ""))
		out["fatal"] = true
		return out
	var height: PackedFloat32Array = rep.get("height_buffer", PackedFloat32Array())
	var flow: PackedFloat32Array = rep.get("flow_buffer", PackedFloat32Array())
	var biome: PackedByteArray = rep.get("biome_buffer", PackedByteArray())
	var area: PackedFloat32Array = rep.get("area_hex_buffer", PackedFloat32Array())
	if height.size() != n_pix:
		out["stage"] = "bake/" + mode + "/height_buffer"
		out["reason"] = "尺寸 %d != %d" % [height.size(), n_pix]
		out["fatal"] = true
		return out
	if flow.size() != n_pix:
		out["stage"] = "bake/" + mode + "/flow_buffer"
		out["reason"] = "尺寸 %d != %d（river_ok=%s reason=%s）" % [flow.size(), n_pix,
				str(bool(rep.get("river_ok", false))), str(rep.get("river_reason", ""))]
		return out
	if biome.size() != n_pix:
		out["stage"] = "bake/" + mode + "/biome_buffer"
		out["reason"] = "尺寸 %d != %d" % [biome.size(), n_pix]
		return out
	var st := _a12_state(height, flow, area, biome, int(hm.x), int(hm.y))
	out["st"] = st
	if int(st["n_riv"]) == 0:
		out["stage"] = "bake/" + mode + "/river_center"
		out["reason"] = "河心像素为 0（flow>=%.2f 无样本；river_ok=%s）" % [A12_RIVER_FLOW,
				str(bool(rep.get("river_ok", false)))]
		return out
	if int(st["x1_n"]) == 0:
		out["stage"] = "bake/" + mode + "/x1_window"
		out["reason"] = "全部河心像素的半径 %d px 圆盘陆地样本 < %d" % [A12_X1_R, A12_MIN_R3]
		return out
	out["ok"] = true
	return out


# 真实生成链路的 bake knobs：照 scripts/rendering/bakers/terrain_baker.gd::_bake_geometry_fields_native
# 的键与算式逐条对齐（origin/size/hex_size/wrap_period_x/inv_world/stroke_radius + DEM 缺省）。
# mode 只影响 dem_erosion_mode 一个键：spl = 主判据；carve = 同图同种子同 DLL 的对照（相对门禁用）。
func _a12_bake_knobs(post: Dictionary, seed_v: int, hm: Vector2i, bounds: Rect2,
		mode: String) -> Dictionary:
	var n_cells := A12_MAP_W * A12_MAP_H
	var o2i := PackedInt32Array()
	o2i.resize(n_cells)
	for i in range(n_cells):
		o2i[i] = i                     # 生成期 cell.index 就是 row*width+col（world_ext_generate_base.cpp）
	var inv_world := Vector2(float(hm.x) / bounds.size.x, float(hm.y) / bounds.size.y)
	var stroke_radius_px := maxf(A12_HEX_SIZE * A12_RIVER_STROKE_HEX_FACTOR * inv_world.x, 0.5)
	var knobs := {
		"width": int(hm.x), "height": int(hm.y),
		"origin_x": bounds.position.x, "origin_y": bounds.position.y,
		"hex_size": A12_HEX_SIZE, "seed": seed_v,
		"map_width": A12_MAP_W, "map_height": A12_MAP_H, "n_cells": n_cells,
		"size_x": bounds.size.x, "size_y": bounds.size.y,
		"wrap_period_x": float(A12_MAP_W) * sqrt(3.0) * A12_HEX_SIZE,
		"sea_level": SEA,
		"cell_elevation": post.get("elevation_arr", PackedFloat32Array()),
		"cell_moisture": post.get("moisture_arr", PackedFloat32Array()),
		"cell_terrain": post.get("terrain_arr", PackedByteArray()),
		"cell_landform": post.get("landform_arr", PackedByteArray()),
		"cell_vegetation": post.get("vegetation_arr", PackedByteArray()),
		"cell_cover": post.get("cover_arr", PackedByteArray()),
		"cell_water_depth": post.get("water_depth_arr", PackedFloat32Array()),
		"offset_to_index": o2i,
		# 侵蚀：dem_* 走下面镜像的 DEM 缺省；droplet 在 spl 模式下不执行（carve 模式下 num_drops=0 ⇒ 空跑）
		"num_drops": 0, "brush_radius": 2,
		# river SDF
		"inv_world_x": inv_world.x, "inv_world_y": inv_world.y,
		"base_radius_px": stroke_radius_px,
		"sdf_max_dist_px": A12_SDF_MAX_DIST_PX,
		"cr_step": A12_RIVER_CR_STEP,
		# coast SDF carve
		"shore_carve_amp": A12_SHORE_CARVE_AMP,
		"shore_carve_band": A12_SHORE_CARVE_BAND,
		"coast_sdf_max_dist_px": A12_COAST_SDF_MAX_DIST_PX,
	}
	for key in A12_DEM_DEFAULTS:
		knobs[key] = A12_DEM_DEFAULTS[key]
	# 侵蚀模式：A12_DEM_DEFAULTS 里镜像的是生产缺省 spl，这里按本次对照显式改（唯一不同的键）。
	knobs["dem_erosion_mode"] = mode
	# [S2] 诊断开关：额外返回 area_hex_buffer（像素层汇水面积，hex²；不影响高度）。
	# C++ 从 **bake knobs** 读它（world_ext_bake.cpp:855），不是从 profile。只有 SPL 分支会填这份诊断
	# （carve 侧 area_hex_buffer 为空 ⇒ aux 打印 -1）；X2 删除后它只用于 aux，不参与判定。
	knobs["dem_erosion_area_dump"] = true
	return knobs


# 60×40 / hex_size=22 的世界包围盒（= MapBaker.compute_world_bounds / surface_baker.gd:848）。
func _a12_bounds() -> Rect2:
	var px := sqrt(3.0) * A12_HEX_SIZE * (float(A12_MAP_W) + 0.5)
	var py := 1.5 * A12_HEX_SIZE * float(A12_MAP_H) + 0.5 * A12_HEX_SIZE
	return Rect2(Vector2(-A12_HEX_SIZE * 2.0, -A12_HEX_SIZE * 2.0),
			Vector2(px + A12_HEX_SIZE * 4.0, py + A12_HEX_SIZE * 4.0))


# 桌面 hm 尺寸（= TerrainBaker._resolve_hm_size / terrain_baker.gd:459：长边 1024、短边按 aspect、取偶）。
func _a12_hm_size(bounds: Rect2) -> Vector2i:
	var hm_w := A12_HM_MAX_DIM
	var hm_h := A12_HM_MAX_DIM
	if bounds.size.x >= 0.01 and bounds.size.y >= 0.01:
		var aspect := bounds.size.x / bounds.size.y
		if aspect >= 1.0:
			hm_w = A12_HM_MAX_DIM
			hm_h = roundi(float(A12_HM_MAX_DIM) / aspect)
		else:
			hm_h = A12_HM_MAX_DIM
			hm_w = roundi(float(A12_HM_MAX_DIM) * aspect)
	hm_w = (hm_w / 2) * 2
	hm_h = (hm_h / 2) * 2
	return Vector2i(maxi(hm_w, 256), maxi(hm_h, 256))


# 生成 cfg：与 tests/world/ridge_drainage_metrics_test.gd::_cfg() 逐字一致（contracts §D-1）。
func _a12_cfg(seed_v: int) -> Dictionary:
	return {
		"num_continents": 3,
		"continent_size": 0.9,
		"sea_level": SEA,
		"river_count": 12,
		"width": A12_MAP_W,
		"height": A12_MAP_H,
		"seed": seed_v,
	}


# 生成 profile：与 ridge_drainage_metrics_test.gd::_profile() 同源（contracts §D-1 的代表 profile）；
# 多出的 dem_erosion_area_dump 只对 bake 有效（生成 pass 忽略未知键），写在这里是为了让「同一份
# profile 自证包含该开关」，真正的读取点是 _a12_bake_knobs() 的 knobs。
func _a12_profile() -> Dictionary:
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
		"dem_erosion_area_dump": true,
	}


# 升序切片上第一个 >= v 的下标（并列值共享下界）。
func _a12_lower_bound(sorted_vals: PackedFloat32Array, v: float) -> int:
	var lo := 0
	var hi := sorted_vals.size()
	while lo < hi:
		var mid := (lo + hi) / 2
		if float(sorted_vals[mid]) < v:
			lo = mid + 1
		else:
			hi = mid
	return lo


# 升序切片上第一个 > v 的下标。
func _a12_upper_bound(sorted_vals: PackedFloat32Array, v: float) -> int:
	var lo := 0
	var hi := sorted_vals.size()
	while lo < hi:
		var mid := (lo + hi) / 2
		if float(sorted_vals[mid]) <= v:
			lo = mid + 1
		else:
			hi = mid
	return lo


# 中位数（原地升序；偶数取中间两个的算术平均）。
func _a12_median(values: PackedFloat32Array) -> float:
	var m := values.size()
	if m == 0:
		return 0.0
	values.sort()
	if m % 2 == 1:
		return float(values[(m - 1) / 2])
	return (float(values[m / 2 - 1]) + float(values[m / 2])) * 0.5


# ═════════════════════════════════════════════════════════════════════════════
# 合成地形（全部可解析：锥体/山脊 + 正弦扰动；relief 用 hex 空间中心差分）
# ═════════════════════════════════════════════════════════════════════════════

# 主地形：中央 cos 钟形山体 + 两级正弦扰动（2.6 hex / 1.2 hex）；u/v 以 hex 为单位。
func _massif_h(u: float, v: float, w_hex: float, h_hex: float) -> float:
	var cx := w_hex * 0.5
	var cy := h_hex * 0.5
	var dx := u - cx
	var dy := v - cy
	var radius := maxf(minf(w_hex, h_hex) * 0.55, 1.0e-6)
	var rr := sqrt(dx * dx + dy * dy) / radius
	var massif := 0.0
	if rr < 1.0:
		massif = 0.28 * pow(cos(rr * PI * 0.5), 2.0)
	var wave := 0.010 * sin((u + 0.35 * v) * TAU / 2.6) + 0.005 * sin((v - 0.25 * u) * TAU / 1.2)
	return 0.615 + massif + wave


# 采样主地形 → height / relief / wet（with_lake=true 时在内陆压出一个碗形湖，供 A2 用）。
func _sample_massif(w: int, h: int, hex_px: float, with_lake: bool) -> Dictionary:
	var w_hex := float(w) / hex_px
	var h_hex := float(h) / hex_px
	var n := w * h
	var height := PackedFloat32Array()
	var relief := PackedFloat32Array()
	var wet := PackedByteArray()
	height.resize(n)
	relief.resize(n)
	wet.resize(n)
	var lake_u := w_hex * 0.5 - w_hex * 0.06
	var lake_v := h_hex * 0.5 + h_hex * 0.05
	var lake_out := LAKE_R_HW * 2.0
	var du := 0.1
	for y in range(h):
		for x in range(w):
			var i := y * w + x
			var u := (float(x) + 0.5) / hex_px
			var v := (float(y) + 0.5) / hex_px
			var hv := _massif_h(u, v, w_hex, h_hex)
			if with_lake:
				var dl := sqrt((u - lake_u) * (u - lake_u) + (v - lake_v) * (v - lake_v))
				if dl < lake_out:
					var t := dl / lake_out
					hv = LAKE_BOTTOM + (hv - LAKE_BOTTOM) * t * t * t
			height[i] = hv
			var gx := (_massif_h(u + du, v, w_hex, h_hex) - _massif_h(u - du, v, w_hex, h_hex)) / (2.0 * du)
			var gy := (_massif_h(u, v + du, w_hex, h_hex) - _massif_h(u, v - du, w_hex, h_hex)) / (2.0 * du)
			relief[i] = sqrt(gx * gx + gy * gy)
			wet[i] = 1 if hv <= SEA + WET_MARGIN else 0
	return {"height": height, "relief": relief, "wet": wet}


# A3 / A9 用的「单坡 + 正弦脊谷」解析场（y_amp / ridge_amp / periods / micro_* 由调用方给）：
# 沿 -y 严格递减 ⇒ 处处可下坡、无闭合洼地（priority-flood 不填任何像素），
# x 向的脊谷负责把水流并成树枝状沟谷。参数以 hex 为单位 ⇒ 两档分辨率采到同一物理场。
func _ridge_h(u: float, v: float, w_hex: float, h_hex: float, y_amp: float, ridge_amp: float,
		periods: float, micro_amp: float, micro_wl: float, base: float) -> float:
	var down := base - y_amp * (v / maxf(h_hex, 1.0e-6))
	var ridge := ridge_amp * cos(u * TAU * periods / maxf(w_hex, 1.0e-6))
	var micro := micro_amp * sin((u * 1.7 + v * 0.9) * TAU / micro_wl)
	return down + ridge + micro


func _sample_ridge(w: int, h: int, hex_px: float, y_amp: float, ridge_amp: float,
		periods: float, micro_amp: float, micro_wl: float, base: float) -> Dictionary:
	var w_hex := float(w) / hex_px
	var h_hex := float(h) / hex_px
	var n := w * h
	var height := PackedFloat32Array()
	var relief := PackedFloat32Array()
	var wet := PackedByteArray()
	height.resize(n)
	relief.resize(n)
	wet.resize(n)
	var du := 0.1
	for y in range(h):
		for x in range(w):
			var i := y * w + x
			var u := (float(x) + 0.5) / hex_px
			var v := (float(y) + 0.5) / hex_px
			height[i] = _ridge_h(u, v, w_hex, h_hex, y_amp, ridge_amp, periods, micro_amp,
					micro_wl, base)
			var gx := (_ridge_h(u + du, v, w_hex, h_hex, y_amp, ridge_amp, periods, micro_amp,
					micro_wl, base)
					- _ridge_h(u - du, v, w_hex, h_hex, y_amp, ridge_amp, periods, micro_amp,
					micro_wl, base)) / (2.0 * du)
			var gy := (_ridge_h(u, v + du, w_hex, h_hex, y_amp, ridge_amp, periods, micro_amp,
					micro_wl, base)
					- _ridge_h(u, v - du, w_hex, h_hex, y_amp, ridge_amp, periods, micro_amp,
					micro_wl, base)) / (2.0 * du)
			relief[i] = sqrt(gx * gx + gy * gy)
			wet[i] = 1 if float(height[i]) <= SEA + WET_MARGIN else 0
	return {"height": height, "relief": relief, "wet": wet}


# A6 用的经线周期场：u 方向严格以 p_hex 为周期（cos/sin 的整数倍频），v 方向单向下坡。
func _wrap_h(u: float, v: float, p_hex: float, h_hex: float) -> float:
	var ridge := 0.020 * cos(u * TAU * 3.0 / maxf(p_hex, 1.0e-6)) \
			+ 0.008 * sin(u * TAU * 5.0 / maxf(p_hex, 1.0e-6))
	var slope := 0.18 * (1.0 - v / maxf(h_hex, 1.0e-6))
	return 0.70 + ridge + slope


func _sample_wrap(w: int, h: int, period: int, hex_px: float) -> Dictionary:
	var n := w * h
	var p_hex := float(period) / hex_px
	var h_hex := float(h) / hex_px
	var height := PackedFloat32Array()
	var relief := PackedFloat32Array()
	var wet := PackedByteArray()
	height.resize(n)
	relief.resize(n)
	wet.resize(n)
	var du := 0.1
	for y in range(h):
		var v := (float(y) + 0.5) / hex_px
		for x in range(w):
			var i := y * w + x
			var u := (float(x % period) + 0.5) / hex_px
			height[i] = _wrap_h(u, v, p_hex, h_hex)
			var gx := (_wrap_h(u + du, v, p_hex, h_hex) - _wrap_h(u - du, v, p_hex, h_hex)) / (2.0 * du)
			var gy := (_wrap_h(u, v + du, p_hex, h_hex) - _wrap_h(u, v - du, p_hex, h_hex)) / (2.0 * du)
			relief[i] = sqrt(gx * gx + gy * gy)
			wet[i] = 1 if float(height[i]) <= SEA + WET_MARGIN else 0
	return {"height": height, "relief": relief, "wet": wet}


# ═════════════════════════════════════════════════════════════════════════════
# knobs / 度量
# ═════════════════════════════════════════════════════════════════════════════

# run_bake_erosion_spl_pass 的入参（契约 §3.3）。缺省值 = 计划 §4.10 的「C++ 缺省」列。
func _spl_knobs(field: Dictionary, w: int, h: int, hex_px: float, wrap_cols: int) -> Dictionary:
	return {
		"width": w,
		"height": h,
		"height_buffer": field["height"],
		"relief_buffer": field["relief"],
		"wet_buffer": field["wet"],
		"sea_level": SEA,
		"hex_px": hex_px,
		"wrap_cols": wrap_cols,
		"dem_erosion_mode": "spl",
		"dem_erosion_max_dim": 0,          # 0 = 不下采样（A11 显式覆盖）
		"dem_spl_iters": 6,
		"dem_spl_k": 0.03,
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
		"dem_erosion_pit_audit": false,
	}


# 融合 pass（A5/A8）的合成 cell SoA：照 tests/world/mountain_relief_bake_test.gd 的 7×7 单元写法，
# 只换尺寸与 seed，保证 run_bake_geometry_fields_pass 走 native 分支（fallback=false）。
func _fused_knobs(extra: Dictionary) -> Dictionary:
	var elev := PackedFloat32Array()
	var moist := PackedFloat32Array()
	var terr := PackedByteArray()
	var land := PackedByteArray()
	var veg := PackedByteArray()
	var ids := PackedInt32Array()
	for row in range(7):
		for col in range(7):
			elev.append(0.86 + (float(row) - 3.0) * 0.012)
			moist.append(0.5)
			terr.append(6)
			land.append(7)
			veg.append(0)
			ids.append(row * 7 + col)
	var knobs := {
		"width": 256,
		"height": 160,
		"map_width": 7,
		"map_height": 7,
		"n_cells": 49,
		"origin_x": 0.0,
		"origin_y": 15.0,
		"size_x": sqrt(3.0) * 70.0,
		"size_y": 60.0,
		"hex_size": 10.0,
		"wrap_period_x": sqrt(3.0) * 70.0,
		"seed": 20261118,
		"sea_level": SEA,
		"cell_elevation": elev,
		"cell_moisture": moist,
		"cell_terrain": terr,
		"cell_landform": land,
		"cell_vegetation": veg,
		"cell_cover": veg,
		"offset_to_index": ids,
		"num_drops": 0,
		"shore_carve_amp": 0.0,
		"dem_valley_river_outlet_flow": 1.0,
	}
	for key in extra:
		knobs[key] = extra[key]
	return knobs


# 逐像素下切量 delta = max(0, h_pre - h_out)（高度单位）。
func _drop(h_pre: PackedFloat32Array, h_out: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if h_pre.size() != h_out.size():
		return out
	out.resize(h_pre.size())
	for i in range(h_pre.size()):
		var d := float(h_pre[i]) - float(h_out[i])
		out[i] = d if d > 0.0 else 0.0
	return out


# 最大邻格坡度（height / px，8 邻接；wrap=true 时 x 方向环绕）。
func _slope_max(h: PackedFloat32Array, w: int, ht: int, wrap: bool) -> float:
	var best := 0.0
	for y in range(ht):
		for x in range(w):
			var i := y * w + x
			for k in range(8):
				var nx := x + int(DX[k])
				var ny := y + int(DY[k])
				if ny < 0 or ny >= ht:
					continue
				if nx < 0 or nx >= w:
					if not wrap:
						continue
					nx = (nx + w) % w
				var s := absf(float(h[i]) - float(h[ny * w + nx])) / float(DL[k])
				if s > best:
					best = s
	return best


# Pearson 相关（两个等长序列）。
func _pearson(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := mini(a.size(), b.size())
	if n < 2:
		return 0.0
	var sa := 0.0
	var sb := 0.0
	for i in range(n):
		sa += float(a[i])
		sb += float(b[i])
	var ma := sa / float(n)
	var mb := sb / float(n)
	var cov := 0.0
	var va := 0.0
	var vb := 0.0
	for i in range(n):
		var da := float(a[i]) - ma
		var db := float(b[i]) - mb
		cov += da * db
		va += da * da
		vb += db * db
	if va <= 0.0 or vb <= 0.0:
		return 0.0
	return cov / sqrt(va * vb)


# p99（排序法；样本量只有 5k–41k，成本可忽略）。
func _p99(values: PackedFloat32Array) -> float:
	if values.size() == 0:
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var idx := mini(sorted.size() - 1, int(float(sorted.size()) * 0.99))
	return float(sorted[idx])


# D8 汇水面积代理（面积单位 = px；A3 用）。规则与契约 §2.2 build_flow 一致：
# 取 argmax_k (z[i]-z[nb_k])/DL[k]，只接受严格更低的邻点，平局保留 k 小者；
# 沿「高度降序」（= 上游→下游的合法拓扑序）累加。本合成坡无洼地，故不做填洼。
func _area_proxy_px(height: PackedFloat32Array, w: int, ht: int) -> PackedFloat32Array:
	var n := w * ht
	# 排序容器用 Array 而不是 PackedInt32Array：sort_custom 只保证在 Array 上可用（本项目其它
	# 用例也都是 Array.sort_custom），Packed*Array 只有 sort()，避免依赖未确认的内建方法。
	var order: Array = []
	order.resize(n)
	for i in range(n):
		order[i] = i
	order.sort_custom(func(a: int, b: int) -> bool: return (float(height[a]) > float(height[b])) if (float(height[a]) != float(height[b])) else (a < b))
	var rcv := PackedInt32Array()
	rcv.resize(n)
	rcv.fill(-1)
	for y in range(ht):
		for x in range(w):
			var i := y * w + x
			var best := 0.0
			var best_n := -1
			for k in range(8):
				var nx := x + int(DX[k])
				var ny := y + int(DY[k])
				if nx < 0 or nx >= w or ny < 0 or ny >= ht:
					continue
				var dz := float(height[i]) - float(height[ny * w + nx])
				if dz <= 0.0:
					continue
				var slope := dz / float(DL[k])
				if slope > best:
					best = slope
					best_n = ny * w + nx
			rcv[i] = best_n
	var area := PackedFloat32Array()
	area.resize(n)
	for i in range(n):
		area[i] = 1.0
	for oi in range(n):
		var i := int(order[oi])
		var r := rcv[i]
		if r < 0:
			continue
		area[r] = float(area[r]) + float(area[i])
	return area


# 盒式下采样（wrap 感知，越界 y 克隆边缘）——逐条复刻 contracts §2.2 的 downsample_box_f32。
func _downsample_box_f32(src: PackedFloat32Array, w: int, ht: int, f: int) -> PackedFloat32Array:
	var dw := maxi(1, int(floor(float(w) / float(f))))
	var dh := maxi(1, int(floor(float(ht) / float(f))))
	var dst := PackedFloat32Array()
	dst.resize(dw * dh)
	if f <= 1:
		if src.size() >= w * ht:
			for i in range(w * ht):
				dst[i] = src[i]
		return dst
	var inv := 1.0 / float(f * f)
	for y in range(dh):
		for x in range(dw):
			var acc := 0.0
			for j in range(f):
				var sy := y * f + j
				if sy >= ht:
					sy = ht - 1
				for i in range(f):
					var sx := (x * f + i) % w
					acc += float(src[sy * w + sx])
			dst[y * dw + x] = acc * inv
	return dst


# 盒式下采样（u8 掩码）：块内 1 的个数 >= 半数 → 1（面积多数表决），复刻 contracts §2.2。
func _downsample_box_u8(src: PackedByteArray, w: int, ht: int, f: int) -> PackedByteArray:
	var dw := maxi(1, int(floor(float(w) / float(f))))
	var dh := maxi(1, int(floor(float(ht) / float(f))))
	var dst := PackedByteArray()
	dst.resize(dw * dh)
	if f <= 1:
		if src.size() >= w * ht:
			for i in range(w * ht):
				dst[i] = src[i]
		return dst
	var half := (f * f + 1) / 2
	for y in range(dh):
		for x in range(dw):
			var acc := 0
			for j in range(f):
				var sy := y * f + j
				if sy >= ht:
					sy = ht - 1
				for i in range(f):
					var sx := (x * f + i) % w
					if src[sy * w + sx] != 0:
						acc += 1
			dst[y * dw + x] = 1 if acc >= half else 0
	return dst


# delta 双线性放大：dst(x,y) = bilinear(src, u, v)，u = (x+0.5)/f - 0.5 按 w 取模、
# v = (y+0.5)/f - 0.5 夹紧到 [0, h-1]（逐条复刻 contracts §2.2 的 upsample_box_f32）。
func _upsample_bilinear(src: PackedFloat32Array, w: int, ht: int, f: int,
		w_hi: int, h_hi: int) -> PackedFloat32Array:
	var dst := PackedFloat32Array()
	dst.resize(w_hi * h_hi)
	var ff := maxi(1, f)
	var inv_f := 1.0 / float(ff)
	for y in range(h_hi):
		var v := (float(y) + 0.5) * inv_f - 0.5
		if v < 0.0:
			v = 0.0
		if v > float(ht - 1):
			v = float(ht - 1)
		var j0 := int(floor(v))
		if j0 < 0:
			j0 = 0
		if j0 > ht - 1:
			j0 = ht - 1
		var j1 := j0 + 1
		if j1 > ht - 1:
			j1 = ht - 1
		var tv := v - float(j0)
		for x in range(w_hi):
			var u := fposmod((float(x) + 0.5) * inv_f - 0.5, float(w))
			var i0 := int(floor(u))
			if i0 < 0:
				i0 = 0
			if i0 > w - 1:
				i0 = w - 1
			var i1 := i0 + 1
			if i1 > w - 1:
				i1 = 0                       # u 按 w 取模 → 右邻回绕
			var tu := u - float(i0)
			var a := float(src[j0 * w + i0]) * (1.0 - tu) + float(src[j0 * w + i1]) * tu
			var b := float(src[j1 * w + i0]) * (1.0 - tu) + float(src[j1 * w + i1]) * tu
			dst[y * w_hi + x] = a * (1.0 - tv) + b * tv
	return dst


# 管线在 factor>1 时的写回规则（contracts §3.2-4）：wet 原样、陆地 clamp 到 sea+eps、只降。
# 逐条复刻 world_ext_bake.cpp 的 upsample 写回段，用于 A11 反推「应得的高度」。
func _writeback(h_pre: PackedFloat32Array, wet: PackedByteArray,
		delta_hi: PackedFloat32Array) -> PackedFloat32Array:
	var out := h_pre.duplicate()
	var sea_floor := SEA + SEA_EPS
	for i in range(out.size()):
		if i < wet.size() and wet[i] != 0:
			continue
		var h0 := float(h_pre[i])
		var hn := h0 - float(delta_hi[i])
		if h0 > SEA and hn < sea_floor:
			hn = sea_floor
		if hn > h0:
			hn = h0
		out[i] = hn
	return out


# FNV-1a 32-bit（对 F32 buffer 的原始字节；供 root 与基线 DLL 的 hash 比对）。
func _hash32(values: PackedFloat32Array) -> int:
	var bytes := values.to_byte_array()
	var hsh := 0x811C9DC5
	for i in range(bytes.size()):
		hsh = (hsh ^ int(bytes[i])) * 16777619
		hsh = hsh & 0xFFFFFFFF
	return hsh


# ═════════════════════════════════════════════════════════════════════════════
# 断言 / 跳过
# ═════════════════════════════════════════════════════════════════════════════

# 基线不可用（方法缺失 / 基线 pass fallback）→ 打印 SKIP 并返回 true（不计失败）。
func _need_baseline(tag: String) -> bool:
	if not _has_spl:
		_skip(tag, "run_bake_erosion_spl_pass 未导出（DLL 未重编？）")
		return true
	if bool(_base.get("fallback", true)):
		_skip(tag, "基线 pass fallback: " + str(_base.get("reason", "")))
		return true
	return false


func _skip(tag: String, reason: String) -> void:
	_checks += 1
	_skips += 1
	print("%s: SKIP reason=%s" % [tag, reason])


func _expect(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)
