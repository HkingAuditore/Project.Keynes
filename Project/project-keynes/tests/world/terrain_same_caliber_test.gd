extends SceneTree

# ═════════════════════════════════════════════════════════════════════════════
# terrain_same_caliber_test.gd — S7 §3「同口径新旧对比」（checklist T4.1–T4.6）
#
# 规格：docs/plans/terrain-same-caliber-review-plan.md §3.1–§3.5
#      docs/plans/terrain-same-caliber-review-checklist.md §4
# 定位：**只做诊断**。本任务唯一新增物就是这个文件：不改 C++、不改既有测试、
#      不改 docs/checklist、不改 climate_profile.gd，只写 res://tmp/same_caliber/。
#
# 跑法（由 lead 编译 DLL 后统一执行；本文件**不**自行启动 Godot / scons）：
#   godot --headless -s res://tests/world/terrain_same_caliber_test.gd
#   退出码：0 = 跑完（含 SKIP）；1 = 硬失败（无 DCWorldExt / 前置诊断缺失 / 写盘失败）
#
# ── 为什么需要这一节 ────────────────────────────────────────────────────────
# 上一轮的跨版本比较全部作废：旧版 ridge_add 在 SPL **之后**用最终 E 算、新版在 SPL **之前**
# 用 E0 算 —— 两个场的幅值差 3–5 倍、高脊格集合 Jaccard 只有 0.31–0.43。拿各自版本的
# ridge_add 当「哪里是脊」去比较，测的是场差而不是地形差。
# §3 的做法：**用 E0 版 ridge_add 当两版共用的「哪里是脊」定义**，然后各自用自己那版的
# 地形与排水网算指标。本文件实现这一点。
#
# ── 数据来源 ────────────────────────────────────────────────────────────────
# 新：当前 DLL 的 base pass（profile.debug_dump_ridge_e0=1 ⇒ e0_arr / ridge_e0_arr）
#     + post_base（hydro_parent_arr / has_river_arr / elevation_arr / terrain_arr）
# 旧：res://tmp/p5_calib/baseline/seed_<seed>_<w>x<h>_{elev,terr,land}.bin（冻结裸字节，无文件头）
#     · _elev.bin = Float32 LE，旧 **base** pass 输出（= 旧 post_base 里 Priority-Flood 的输入面）
#     · _terr.bin = Uint8，旧 base terrain 码（水体 = {0,1,18,19,20,21}，同 pk_is_water_terrain）
#     · _land.bin = Uint8，**landform 码，不是 0/1 陆地掩码**：ridge_drainage_metrics_test.gd
#       的 _write_bins 写的是 m["lf"] = base.landform_arr，文件名叫 land 属历史误名。
#       本文件**不用**它，陆地一律从 terrain 码按 pk_is_water_terrain 推（与 C++ 的 land
#       列表同定义）。运行时会打印一行实测证据（取值集合不是 {0,1}）。
#     · 旧 hydro_parent **未冻结** ⇒ 本文件按 §3.5 从旧 E 重建（见下）。
#
# ── 阶段口径（同口径的关键，务必先读）───────────────────────────────────────
# 旧版 post_base 之后的 E 没有冻结，所以两版一律用 **base 阶段**（= PF 的输入面）的 E：
#   old E = 冻结 _elev.bin；new E = base["elevation_arr"]
# 这不是"退而求其次"：post_base 的 Priority-Flood 就是在 base E 上跑的（对 E[] 的写回全在
# PF 之后：river-incise world_ext_generate.cpp:1333/1345、wave-erosion 1387、volcano 1708/
# 1717），所以 base E 正是"该版 hydro_parent 所依附的那个面"。任何用 post E 算的 cell 指标
# 都会把河道下切/波蚀/火山混进来，而旧版没有对应数据 ⇒ 不可比。
# 唯一例外：新版额外用 post E 重算一次 C1/C2 落 JSON（键名 *_post_stage，纯诊断、不参与判定）。
#
# ── §3.5 旧 hydro_parent 重建（与 post-base 逐条同构：world_ext_generate.cpp:902-965）──
#   1) 种子 = **row==0 或 row==height-1 的全部格**（与地形无关，不是"海岸格"）；东西经度环绕
#      由 NB(posmod) 处理、南北不环绕 ⇒ 没有东西边界。**全格都会入堆**（六边形网格整连通）。
#   2) 最小堆按 (fill, idx) 字典序弹出（C++ 是 priority_queue<pair<float,int>, greater<>>）。
#   3) 邻居 ni 首次被发现时：seen=1；fill[ni] = max(E[ni], fill[cur])；
#      **parent[ni] = cur（关闭者，不是最陡受体）**；入堆。**不加 ε、不抖动**。
#   4) 种子自身 parent = −1 ⇒ 沿 parent 追到 <0 即"出口"，出口 = 该格自身。
#   5) 水体格**也有** parent（只有南北两行没有）：上一轮注释里"水体格 parent<0"是错的，
#      这条误解正是 ws_all 口径把海岸格大量判成分水岭的来源（见 M1' 口径说明）。
#   6) up_count：陆地（terrain 非水体）初值 1、水体 0，按**出栈逆序**（= 到出口距离降序，
#      同一条"父先于子"的拓扑序）向 parent 累加。C++ 用 hydro_order 逆序，本文件用 dist
#      降序：两者都是逆拓扑序，每个格只向上传一次 ⇒ 结果相同。
#   自测：对**新**最终 E（base["elevation_arr"]）用同一套规则重建，与真实 hydro_parent_arr
#   比逐格一致率，**≥ 99% 才允许把旧列写进结果**；< 99% 打印实测值并把旧列全部 [SKIP]
#   （绝不硬编、也不把"重建不如 99%"的结果当旧版数字）。
#
# ── M1' / M2b / C1–C3 的精确口径（对应计划 §3.2–§3.4）────────────────────────
# 公共参照场（两版共用，每图只算一次）：
#   land_shared = 新版 **base** terrain 非水体（同阶段、同 pk_is_water_terrain 口径）
#   p75         = land_shared 上 ridge_e0 的 p75（numpy 线性插值口径）
#   脊顶格 tops = land_shared 内、ridge_e0 为 6 邻**局部极大**（不弱于所有邻居，且严格大于
#                 至少一个邻居 —— 避免平台 ties 把整片平顶算成脊顶）且 ridge_e0 ≥ p75
#   高脊带 high = ridge_e0 ≥ p75（全格；水体格 ridge_e0 恒 0 ⇒ 自动排除）
#
# M1'(版) = |tops ∩ 分水岭(版)| / |tops|
#   分水岭(版)[i] = 存在邻格 j 使 trace_outlet(版,i) != trace_outlet(版,j)
#   两种口径**同时**算：ws_land（**只比陆地邻格**，主判据）/ ws_all（6 邻全比，计划字面）。
#   只比陆地邻格的理由：PF 只把南北两行当出口，两个相邻的海洋格也可以各有不同出口，
#   于是字面口径会把大量海岸格判成分水岭、系统性抬高零假设（=压低差值，保守偏差）。
#   上一轮探针的 ws_land 还有 early-break 缺陷（第一个"出口不同"的邻居若是水就 break，
#   后面更强的陆地证据看不到）；本文件修成"扫完 6 邻再落 flag"。
#   零假设(版) = 固定 RNG（seed*1000003+n）从 land_shared 里抽 |tops| 个陆地格，同法算比例。
#   **两版共用同一批抽样下标** ⇒ 差异只来自排水网，不来自抽样。
#
# M2b(版) = 该版 E 上「填洼深度 ≥ hydro_lake_min_depth 且溢流口落在高脊带」的**闭合洼地数**
#   洼地格 = 该版 base terrain 非水体 且 未被"海洋连通"BFS 标记（connected==0，同 C++）且
#            fill[i] − E[i] ≥ hydro_lake_min_depth
#   闭合洼地 = 洼地格的 6 连通分量；**溢流口** = 分量内"parent 落在分量外"的格里 fill 最小
#            那个（平局取小下标）。分量内无逃逸边（触南北边界）记 no_spill，不计数。
#   面积占比 = (溢流口在高脊带的分量格数) / (全部洼地格数) —— 避免只数个数被碎洼地主导。
#   另报**旧口径** cell 计数 M2b_cells（上一轮 M2_ridge_pits：pit 格且 ridge ≥ p75），
#   便于和上一轮的表对齐；它数的是**格**不是洼地，两列不可混用。
#
# C1(版) = 河流格中 E[i] ≤ 6 邻 E 中位数（numpy 中位数：6 邻取第 3/4 两值平均）的比例
#          主口径 = 6 邻全比；C1_land = 只比陆地邻（JSON）
# C2(版) = 河流格的 ridge_e0 中位数（越低 = 河越避开脊）
# C3(版) = 河段中"穿过高脊带"的比例。**河段** = 沿 parent 的相邻河格对 (i, parent[i])，
#          两端都是河格；穿过 = **至少一端**在高脊带。C3_both = 两端都在高脊带（更严，JSON）。
#
# 河流格（两版同一条代理规则，§3.4）：
#   旧版没有 has_river ⇒ 两版都用同一代理：up_count(版) ≥ channel_init 且该格是陆地。
#   channel_init = max(2, round(16 × max(0.25, n/15000)))，与 world_ext_generate.cpp:615-620
#   同式（本文件对该式求值，并用 post_base 的 river_channel_init_effective 交叉校验）。
#   代理与 C++ 真实选河规则的差别：C++ 还额外 (a) 用 **post-lake 后**的 land 列表、
#   (b) headwater 延伸、(c) 孤立/过短河段清理、(d) 无河无水的孤立河格反标记。
#   所以新版另外用真实 has_river_arr 算一次 C1/C2/C3，两者 **C1 差 ≤ 0.03 才采信代理**，
#   否则该图打印 [代理不可信] 并落 JSON（判定列照常写，但带警告标记）。
#
# ── 前置校验（T4.1）─────────────────────────────────────────────────────────
# · 同种子同 profile 连跑两次 base pass，e0_arr / ridge_e0_arr 的 hash 必须相同 ⇒ 打印
#   `E0 determinism: OK`。不一致则旧列全部 [SKIP]（降级为"新版内对比"）。
# · git 侧证据（本文件在 Godot 里跑不了 git，结论人工核对后记在这里，2026-11-18）：
#   `git diff -- gdext/src/world_ext_generate_base.cpp` 只含 §R 之后的诊断插入块与 §2.4' 的
#   消融开关（spl_steepest_receiver），§1 地台 / §2.55 洋底**零改动** ⇒ 「E0 两版相同」成立。
#
# ── 输出 ────────────────────────────────────────────────────────────────────
#   [same-caliber] seed=… WxH M1'_old=… null_old=… | M1'_new=… null_new=… | dM1'=… |
#                  M2b_old=… M2b_new=… | C1_old=… C1_new=… | C2_old=… C2_new=… | C3_old=… C3_new=…
#   紧跟一行：全 6 邻口径 + 高脊洼地面积占比 + 代理可信度；再一行判定。
#   末尾 [same-caliber/summary] 汇总行（lead 直接抄表）。
#   结果落盘 res://tmp/same_caliber/result.json（schema 见 _write_result 上方注释）。
#
# ── 与既有文件的关系 ────────────────────────────────────────────────────────
# · 6 邻表 / trace_outlet / _up_count / Priority-Flood / _percentile 的口径与
#   tests/world/terrain_followup_probe.gd、ridge_drainage_metrics_test.gd **同源**
#   （同样的 DQ/DR、同样的 posmod 环绕、同样的 int64 打包堆键），本文件不另造一套。
# · **不碰** world_fingerprint*、erosion_spl_bake_test.gd、ridge_drainage_metrics_test.gd。
#
# ── 静态自检（用户锁着 DLL，不能跑 Godot，只能静态证明）────────────────────
# · gdtoolkit 4.5.0 的 Godot-4 parser 整文件解析通过（gdparse / gdlint）。
# · 全部 `var x := …` 的右值类型逐个审计过：**零处**是 Variant（Dictionary.get / 无类型
#   Array 下标 / Object.call 一律用带类型的 `var x: T = …` 或裸 `=`，绝不用 `:=`）。
# · tab 缩进、UTF-8、每个 % 的占位符数与实参数一致。
# ═════════════════════════════════════════════════════════════════════════════

# ── 种子 / 尺寸（与 ridge_drainage_metrics_test 的 SEED_BASE 同源）─────────────
const SEED_BASE := 20260718
const W_SMALL := 60
const H_SMALL := 40
const W_LARGE := 200
const H_LARGE := 150
const N_SMALL_SEEDS := 4        # 20260718..20260721 @ 60x40（任务书要求 4 个）
const N_LARGE_SEEDS := 2        # 20260718..20260719 @ 200x150（任务书要求 2 个，超时就降 1 个）

const OUT_ROOT := "res://tmp/same_caliber"
const BASELINE_DIR := "res://tmp/p5_calib/baseline"

# ── 常量（全部注明来源）──────────────────────────────────────────────────────
const SEA_FALLBACK := 0.64          # cfg.sea_level（同 contracts §D-1 / ridge_drainage_metrics_test）
const PIT_EPS := 1.0e-6             # 填洼面 > 原面 + 1e-6 判为 pit（契约 §C）
const MIN_SAMPLE := 8               # 样本 < 8 不下结论（与基线测试同）
const RIDGE_P75 := 0.75             # 高脊/脊顶门槛：陆地 ridge_e0 的 p75
const ZERO_HYP_SEED_MUL := 1000003  # 零假设抽样 RNG 种子 = seed * 该常数 + n（可复现）
# 堆键：int(level × 2^30) × 2^20 + idx。量化步长 1/2^30 = 9.3e-10，比 float32 在 [0,1) 上的
# 取值间距小两个数量级（实测冻结 E 上「相邻不同取值」的最小间距 = 5.96e-8，比步长大 64 倍）
# ⇒ 不同 float32 值绝不落到同一键，弹出序等价于 C++ 的 (fill, idx) 字典序；同 fill 的平局由
# 低频 20 位按 idx 升序解开，也与 C++ 的 pair<float,int> 完全一致。
# 已用「逐行镜像本文件这把堆的 Python 版本」在 4 张冻结图上验证：parent / fill / 弹出序全等。
const LEVEL_SCALE := 1073741824.0   # 2^30
const LEVEL_SHIFT := 1048576        # 2^20：下标占低 20 位（n <= 30000 < 2^20）
const INDEX_MASK := 1048575         # 2^20 − 1
# river 阈值缩放（world_ext_generate.cpp:615-620）
const RIVER_MAP_REF_CELLS := 15000.0
const RIVER_CHANNEL_INIT_BASE := 16
const RIVER_MAP_SCALE_FLOOR := 0.25
const HYDRO_LAKE_MIN_DEPTH_FALLBACK := 0.018   # world_ext_generate.cpp:526 的缺省值
const HYDRO_LAKE_MIN_SECURE := 1.0e-9          # fill − E 的浮点噪声底
# 判定阈值
const CONSISTENCY_MIN := 0.99       # §3.5：重建 parent 与真实 hydro_parent 的一致率门槛
const PROXY_C1_TOL := 0.03          # §3.4：代理与真实 has_river 的 C1 差门槛
const M1_BAND := 0.05               # §3.2 判读带：|新−旧| < 0.05 = 基本无作用
const LARGE_MAP_MS_BUDGET := 3000.0 # §3：单张 200x150 的旧列重建超过 ~3s 就降到大图 1 个种子

const DQ := [1, 1, 0, -1, -1, 0]
const DR := [0, -1, -1, 0, 1, 1]

# 追踪标记：outlet/dist 用 −2 = "还没追过"，−1 = "链异常/无出口"。
const UNRESOLVED := -2

var _ext: Object = null
var _out_dir := ""
var _hard_fail := 0
var _skips: Array = []
var _notes: Array = []
var _heap: PackedInt64Array = PackedInt64Array()
var _heap_n := 0
var _e0_determinism_ok := false
var _rebuild_min_consistency := 1.0
var _old_columns_enabled := true


func _init() -> void:
	print("[same-caliber] start godot=%s" % str(Engine.get_version_info().get("string", "?")))
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[same-caliber] DCWorldExt 不可用（DLL 未编入 / 未加载？）")
		quit(1)
		return
	_ext = ClassDB.instantiate("DCWorldExt")
	if _ext == null:
		push_error("[same-caliber] DCWorldExt 不可实例化")
		quit(1)
		return
	_out_dir = OUT_ROOT
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	var res := _run()
	res["exp"] = "same_caliber"
	res["skips"] = _skips
	res["notes"] = _notes
	res["hard_fail"] = _hard_fail
	res["generated_utc"] = Time.get_datetime_string_from_system(true)
	res["godot"] = str(Engine.get_version_info().get("string", "?"))
	_write_result(res)
	print("[same-caliber] done rows=%d skips=%d hard_fail=%d result=%s/result.json"
			% [int(res.get("row_count", 0)), _skips.size(), _hard_fail, _out_dir])
	quit(0 if _hard_fail == 0 else 1)


# ═════════════════════════════════════════════════════════════════════════════
# 主流程：前置校验 → 逐图对比 → 汇总 → 打印
# ═════════════════════════════════════════════════════════════════════════════

func _run() -> Dictionary:
	var meta := _meta_block()
	_check_frozen_land_semantics()
	# §3.1 / T4.1：E0 确定性（同种子同 profile 连跑两次 base，比 e0_arr / ridge_e0_arr hash）
	var det := _check_e0_determinism(SEED_BASE, W_SMALL, H_SMALL)
	_e0_determinism_ok = bool(det.get("ok", false))
	if not _e0_determinism_ok:
		_old_columns_enabled = false
		if det.has("reason"):
			_skip("T4.1 E0 determinism",
					"%s ⇒ 旧列全部 SKIP，只做新版内对比" % str(det.get("reason", "?")))
		else:
			_skip("T4.1 E0 determinism",
					"同种子两次导出的 e0_arr/ridge_e0_arr hash 不同（e0 a=%s b=%s ; ridge_e0 a=%s b=%s）"
					% [str(det.get("e0_hash_a", "?")), str(det.get("e0_hash_b", "?")),
					str(det.get("ridge_e0_hash_a", "?")), str(det.get("ridge_e0_hash_b", "?"))]
					+ " ⇒ 旧列全部 SKIP，只做新版内对比")
	meta["e0_determinism"] = det

	var specs: Array = []
	for i in range(N_SMALL_SEEDS):
		specs.append([W_SMALL, H_SMALL, SEED_BASE + i])
	for i in range(N_LARGE_SEEDS):
		specs.append([W_LARGE, H_LARGE, SEED_BASE + i])

	var rows: Array = []
	var large_slow := false
	for sp in specs:
		var w := int(sp[0])
		var h := int(sp[1])
		var seed_v := int(sp[2])
		var tag: String = "seed=%d %dx%d" % [seed_v, w, h]
		if w == W_LARGE and large_slow:
			_skip(tag, "前一张 200x150 的排水网重建+指标超过 %.0f ms，按任务书降到 1 个大图种子"
					% LARGE_MAP_MS_BUDGET)
			continue
		var row := _map_row(seed_v, w, h)
		rows.append(row)
		_print_row(row)
		# 「重」= 这张图上所有 Priority-Flood 重建（新版自测 + 旧版重建）的耗时，
		# 两条都在 GDScript 里跑，才是真正决定要不要砍大图种子的量。
		var timing: Dictionary = row.get("timing", {})
		var heavy_ms: float = float(row.get("old_ms", 0.0))
		var rebuild_ms: float = float(timing.get("rebuild_ms", 0.0))
		if rebuild_ms > heavy_ms:
			heavy_ms = rebuild_ms
		if w == W_LARGE and heavy_ms > LARGE_MAP_MS_BUDGET:
			large_slow = true
			_note("200x150 seed=%d 排水网重建 %.0f ms > %.0f ms ⇒ 后续大图种子跳过"
					% [seed_v, heavy_ms, LARGE_MAP_MS_BUDGET])

	var aggregate := {
		"60x40": _aggregate(rows, W_SMALL),
		"200x150": _aggregate(rows, W_LARGE),
		"all": _aggregate(rows, 0),
	}
	_print_summary(aggregate, rows)
	return {
		"meta": meta,
		"rebuild_check": _rebuild_check_block(rows),
		"rows": rows,
		"aggregate": aggregate,
		"row_count": rows.size(),
		"old_columns_enabled": _old_columns_enabled,
	}


func _meta_block() -> Dictionary:
	return {
		"test": "terrain_same_caliber",
		"plan": "docs/plans/terrain-same-caliber-review-plan.md §3.1–§3.5",
		"checklist": "docs/plans/terrain-same-caliber-review-checklist.md §4 (T4.1–T4.6)",
		"purpose": "用 E0 版 ridge_add 当两版共用的「哪里是脊」定义，做同口径 M1'/M2b/C1–C3 新旧对比",
		"stage_caliber": "两版一致使用 base 阶段 E（= post_base Priority-Flood 的输入面）；"
				+ "旧版 post 阶段 E 未冻结，用 post E 会把河道下切/波蚀/火山混进来而旧版无对应数据",
		"old_sources": {
			"elev": BASELINE_DIR + "/seed_<seed>_<w>x<h>_elev.bin (Float32 LE, 旧 base pass 输出)",
			"terr": BASELINE_DIR + "/seed_<seed>_<w>x<h>_terr.bin (Uint8, terrain 码)",
			"land_bin_note": "…_land.bin 是 landform 码（不是 0/1 掩码），本文件不使用；陆地由 terrain 码推",
			"hydro_parent": "未冻结 ⇒ 按 §3.5 在本文件内重建，并用新版数据自测一致率 ≥ 0.99",
		},
		"profile": _profile(),
		"sea_level": SEA_FALLBACK,
		"ridge_p75": RIDGE_P75,
		"thresholds": {
			"consistency_min": CONSISTENCY_MIN,
			"proxy_c1_tol": PROXY_C1_TOL,
			"m1_band": M1_BAND,
			"large_map_ms_budget": LARGE_MAP_MS_BUDGET,
		},
		"caliber": {
			"land_shared": "新版 base terrain 非水体（同阶段、同 pk_is_water_terrain 口径）",
			"ridge_tops": "ridge_e0 的 6 邻局部极大（不弱于全部邻居且严格大于至少一个）且 ≥ 陆地 p75",
			"high_ridge": "ridge_e0 ≥ 陆地 p75（全格）",
			"watershed_primary": "ws_land：只比较相邻**陆地**格的出口（主判据）",
			"watershed_secondary": "ws_all：6 邻全比（计划字面口径，仅记录）",
			"null_sample": "固定 RNG(seed*1000003+n) 从 land_shared 抽 |tops| 个，两版共用同一批下标",
			"river_proxy": "up_count ≥ channel_init 且陆地（两版同一条代理规则）",
			"c1": "河流格 E ≤ 6 邻 E 中位数的比例（主口径 6 邻全比；C1_land 只比陆地邻）",
			"c2": "河流格 ridge_e0 的中位数",
			"c3": "河段（沿 parent 的相邻河格对）中至少一端在高脊带的比例",
			"m2b": "填洼深度 ≥ hydro_lake_min_depth 且溢流口落在高脊带的闭合洼地数",
		},
		"e0_determinism": {"ok": false},
	}


# 冻结 _land.bin 的语义自检：它不是 0/1 陆地掩码，而是 landform 码（历史误名）。
# 只在第一张 60x40 图上做一次，用取值集合证明，避免以后有人把它当掩码读。
func _check_frozen_land_semantics() -> void:
	var n := W_SMALL * H_SMALL
	var lf := _read_u8("%s/seed_%d_%dx%d_land.bin" % [BASELINE_DIR, SEED_BASE, W_SMALL, H_SMALL])
	if lf.size() != n:
		_note("冻结 _land.bin 缺失或尺寸不符，跳过语义自检")
		return
	var distinct := {}
	var above1 := 0
	for i in range(lf.size()):
		distinct[int(lf[i])] = true
		if int(lf[i]) > 1:
			above1 += 1
	var keys: Array = distinct.keys()
	keys.sort()
	_note("冻结 _land.bin 取值集合=%s（>1 的格 %d/%d）⇒ 它是 landform 码而非 0/1 陆地掩码，"
			% [str(keys), above1, n]
			+ "本文件陆地一律由 _terr.bin 按 pk_is_water_terrain 推")


# §3.1 / T4.1：E0 与 ridge_e0 的确定性。同一份 profile 连跑两次 base pass，比 hash。
func _check_e0_determinism(seed_v: int, w: int, h: int) -> Dictionary:
	var n := w * h
	var profile := _profile()
	var gen_a := _gen_base(seed_v, w, h, profile)
	if not bool(gen_a.get("ok", false)):
		_hard_fail += 1
		return {"ok": false, "reason": "base pass 失败：%s" % str(gen_a.get("reason", "?"))}
	var base_a: Dictionary = gen_a["base"]
	var e0_a: PackedFloat32Array = base_a.get("e0_arr", PackedFloat32Array())
	var r_a: PackedFloat32Array = base_a.get("ridge_e0_arr", PackedFloat32Array())
	if e0_a.size() != n or r_a.size() != n:
		_hard_fail += 1
		_skip("T1 诊断键", "base pass 未返回 e0_arr / ridge_e0_arr（profile.debug_dump_ridge_e0=1 未生效？"
				+ " DLL 是否已重编进 S7-T1 诊断？）")
		return {"ok": false, "reason": "diagnostic_keys_missing",
			"e0_size": e0_a.size(), "ridge_e0_size": r_a.size(), "n_cells": n}
	var gen_b := _gen_base(seed_v, w, h, profile)
	if not bool(gen_b.get("ok", false)):
		_hard_fail += 1
		return {"ok": false, "reason": "base pass 第二次失败：%s" % str(gen_b.get("reason", "?"))}
	var base_b: Dictionary = gen_b["base"]
	var e0_b: PackedFloat32Array = base_b.get("e0_arr", PackedFloat32Array())
	var r_b: PackedFloat32Array = base_b.get("ridge_e0_arr", PackedFloat32Array())
	var h_e0_a := _hash32(e0_a)
	var h_e0_b := _hash32(e0_b)
	var h_r_a := _hash32(r_a)
	var h_r_b := _hash32(r_b)
	var ok := h_e0_a == h_e0_b and h_r_a == h_r_b and e0_b.size() == n
	var out := {
		"ok": ok,
		"seed": seed_v, "w": w, "h": h, "n_cells": n,
		"e0_hash_a": "%08x" % h_e0_a, "e0_hash_b": "%08x" % h_e0_b,
		"ridge_e0_hash_a": "%08x" % h_r_a, "ridge_e0_hash_b": "%08x" % h_r_b,
		"base_ms_a": float(gen_a.get("ms", -1.0)), "base_ms_b": float(gen_b.get("ms", -1.0)),
	}
	if ok:
		print("[same-caliber] E0 determinism: OK  (seed=%d %dx%d e0_hash=%s ridge_e0_hash=%s)"
				% [seed_v, w, h, str(out["e0_hash_a"]), str(out["ridge_e0_hash_a"])])
	else:
		print("[same-caliber] E0 determinism: FAIL  (e0 %s vs %s ; ridge_e0 %s vs %s)"
				% [str(out["e0_hash_a"]), str(out["e0_hash_b"]),
				str(out["ridge_e0_hash_a"]), str(out["ridge_e0_hash_b"])])
	return out


# ═════════════════════════════════════════════════════════════════════════════
# 单图：新版 base+post → 公共参照场 → 旧冻结数组 + 重建排水网 → 两列指标
# ═════════════════════════════════════════════════════════════════════════════

func _map_row(seed_v: int, w: int, h: int) -> Dictionary:
	var n := w * h
	var row := {
		"seed": seed_v, "w": w, "h": h, "n_cells": n, "ok": false, "reason": "",
		"old": {}, "new": {}, "delta": {}, "reference": {}, "timing": {},
		"old_ms": 0.0,
	}
	var t_map := Time.get_ticks_usec()
	var profile := _profile()
	var nbr := _neighbor_table(w, h)

	# ── 新版：base（含 E0 诊断）+ post（含真实 hydro_parent / has_river）──────────
	var gen := _gen_base(seed_v, w, h, profile)
	if not bool(gen.get("ok", false)):
		row["reason"] = "base pass 失败：%s" % str(gen.get("reason", "?"))
		_skip("seed=%d %dx%d" % [seed_v, w, h], str(row["reason"]))
		return row
	var base: Dictionary = gen["base"]
	var e0: PackedFloat32Array = base.get("e0_arr", PackedFloat32Array())
	var ridge_e0: PackedFloat32Array = base.get("ridge_e0_arr", PackedFloat32Array())
	var terr_new: PackedByteArray = base.get("terrain_arr", PackedByteArray())
	var elev_new: PackedFloat32Array = base.get("elevation_arr", PackedFloat32Array())
	if e0.size() != n or ridge_e0.size() != n:
		row["reason"] = "e0_arr/ridge_e0_arr 缺失（DLL 未含 S7-T1 诊断？）"
		_hard_fail += 1
		_skip("seed=%d %dx%d" % [seed_v, w, h], str(row["reason"]))
		return row
	if elev_new.size() != n or terr_new.size() != n:
		row["reason"] = "base pass 的 elevation_arr/terrain_arr 尺寸异常"
		_hard_fail += 1
		_skip("seed=%d %dx%d" % [seed_v, w, h], str(row["reason"]))
		return row
	var gen_post := _gen_post(seed_v, w, h, profile, base)
	if not bool(gen_post.get("ok", false)):
		row["reason"] = "post_base 失败：%s" % str(gen_post.get("reason", "?"))
		_skip("seed=%d %dx%d" % [seed_v, w, h], str(row["reason"]))
		return row
	var post: Dictionary = gen_post["post"]
	var hparent_new: PackedInt32Array = post.get("hydro_parent_arr", PackedInt32Array())
	var has_river_new: PackedByteArray = post.get("has_river_arr", PackedByteArray())
	var terr_post: PackedByteArray = post.get("terrain_arr", PackedByteArray())
	var elev_post: PackedFloat32Array = post.get("elevation_arr", PackedFloat32Array())
	var channel_eff := int(post.get("river_channel_init_effective", -1))
	if hparent_new.size() != n:
		row["reason"] = "hydro_parent_arr 尺寸 %d != %d（post_base 未导出水文拓扑）" % [hparent_new.size(), n]
		_skip("seed=%d %dx%d" % [seed_v, w, h], str(row["reason"]))
		return row

	var channel_init := _channel_init_for(n)
	if channel_eff > 0 and channel_eff != channel_init:
		_note("seed=%d %dx%d: 本文件算的 channel_init=%d 与 post_base 的 %d 不一致，改用后者"
				% [seed_v, w, h, channel_init, channel_eff])
		channel_init = channel_eff

	# ── 公共参照场（两版共用，只算一次）─────────────────────────────────────────
	var land_shared := _land_mask_from_terr(terr_new, n)
	var land_post := _land_mask_from_terr(terr_post, n)
	var shared := _shared_ridge_reference(ridge_e0, land_shared, nbr, n, seed_v)
	if not bool(shared.get("ok", false)):
		row["reason"] = str(shared.get("reason", "公共参照场构造失败"))
		_skip("seed=%d %dx%d" % [seed_v, w, h], str(row["reason"]))
		return row
	var p75 := float(shared["p75"])
	var tops: PackedInt32Array = shared["tops"]
	var high_flag: PackedByteArray = shared["high_flag"]
	var sample: PackedInt32Array = shared["sample"]
	row["reference"] = {
		"land_shared_cells": int(shared["land_cells"]),
		"land_post_cells": _count_flag(land_post, n),
		"e0_hash": "%08x" % _hash32(e0),
		"e0_land_cells": _count_at_least(e0, SEA_FALLBACK, n),
		"ridge_p75": _num(p75),
		"ridge_tops": tops.size(),
		"high_ridge_cells": _count_flag(high_flag, n),
		"null_sample_cells": sample.size(),
		"channel_init": channel_init,
		"lake_min_depth": HYDRO_LAKE_MIN_DEPTH_FALLBACK,
	}

	# ── 新版：重建 PF 用于 §3.5 自测（同时也给出 fill，供 M2b）─────────────────
	var t_rebuild := Time.get_ticks_usec()
	var pf_new := _priority_flood_parent(elev_new, nbr, w, h)
	var rebuilt_new: PackedInt32Array = pf_new["parent"]
	var fill_new: PackedFloat32Array = pf_new["fill"]
	var consistency := _parent_consistency(rebuilt_new, hparent_new, n)
	if consistency < _rebuild_min_consistency:
		_rebuild_min_consistency = consistency
	print("[same-caliber] hydro_parent rebuild consistency (new E, seed=%d %dx%d) = %.4f  %s"
			% [seed_v, w, h, consistency, "OK (>=0.99)" if consistency >= CONSISTENCY_MIN else "BELOW 0.99"])
	if consistency < CONSISTENCY_MIN:
		_old_columns_enabled = false
		_skip("T4.2 旧列 seed=%d %dx%d" % [seed_v, w, h],
				"重建 parent 与真实 hydro_parent_arr 一致率 %.4f < %.2f，旧列不可信 ⇒ SKIP"
				% [consistency, CONSISTENCY_MIN])
	row["rebuild_consistency"] = _num(consistency)

	# ── 新版：排水网 / 分水岭 / 河流代理 ────────────────────────────────────────
	var walk_new := _drainage_walk(hparent_new, n)
	var outlet_new: PackedInt32Array = walk_new[0]
	var dist_new: PackedInt32Array = walk_new[1]
	if not _drainage_ok(dist_new, n):
		row["reason"] = "新版 hydro_parent 拓扑退化（dist==0 的格过半）⇒ 指标无意义"
		_skip("seed=%d %dx%d" % [seed_v, w, h], str(row["reason"]))
		return row
	var ws_new := _watershed_flags(outlet_new, nbr, n, land_shared)
	var up_new := _up_count(hparent_new, dist_new, n, land_shared)
	var river_proxy_new := _river_proxy(up_new, land_shared, channel_init, n)
	var new_metrics := _metrics_for_version(true, elev_new, elev_post, hparent_new, river_proxy_new,
			has_river_new, ridge_e0, high_flag, fill_new, land_shared, terr_new, terr_post,
			nbr, w, h, n, channel_init)
	new_metrics["m1"] = _m1prime_of(tops, ws_new, sample)
	new_metrics["consistency"] = _num(consistency)
	row["new"] = new_metrics

	# ── 旧版：冻结数组 + §3.5 重建 ───────────────────────────────────────────────
	var old_metrics := {}
	var old_ok := false
	var old_ms := 0.0
	var t_old := Time.get_ticks_usec()
	if not _old_columns_enabled:
		_skip("旧列 seed=%d %dx%d" % [seed_v, w, h], "前置（E0 确定性 / 重建一致率）未通过，旧列不可比")
	else:
		var tag: String = "seed_%d_%dx%d" % [seed_v, w, h]
		var elev_old := _read_f32("%s/%s_elev.bin" % [BASELINE_DIR, tag], n)
		var terr_old := _read_u8("%s/%s_terr.bin" % [BASELINE_DIR, tag])
		if elev_old.size() != n or terr_old.size() != n:
			_skip("旧列 seed=%d %dx%d" % [seed_v, w, h],
					"冻结数组缺失/尺寸不符（elev=%d terr=%d，期望 %d）"
					% [elev_old.size(), terr_old.size(), n])
		else:
			var land_old := _land_mask_from_terr(terr_old, n)
			var pf_old := _priority_flood_parent(elev_old, nbr, w, h)
			var parent_old: PackedInt32Array = pf_old["parent"]
			var fill_old: PackedFloat32Array = pf_old["fill"]
			var walk_old := _drainage_walk(parent_old, n)
			var outlet_old: PackedInt32Array = walk_old[0]
			var dist_old: PackedInt32Array = walk_old[1]
			if not _drainage_ok(dist_old, n):
				_skip("旧列 seed=%d %dx%d" % [seed_v, w, h],
						"重建的旧 hydro_parent 拓扑退化（dist==0 的格过半）⇒ 旧列不可信")
			else:
				var ws_old := _watershed_flags(outlet_old, nbr, n, land_old)
				var up_old := _up_count(parent_old, dist_old, n, land_old)
				var river_proxy_old := _river_proxy(up_old, land_old, channel_init, n)
				old_metrics = _metrics_for_version(false, elev_old, elev_old, parent_old,
						river_proxy_old, PackedByteArray(), ridge_e0, high_flag, fill_old,
						land_old, terr_old, terr_old, nbr, w, h, n, channel_init)
				old_metrics["m1"] = _m1prime_of(tops, ws_old, sample)
				old_ok = true
	old_ms = float(Time.get_ticks_usec() - t_old) / 1000.0
	row["old"] = old_metrics
	row["old_available"] = old_ok
	row["ok"] = true
	row["old_ms"] = _num(old_ms)
	row["timing"] = {
		"base_ms": _num(float(gen.get("ms", -1.0))),
		"post_ms": _num(float(gen_post.get("ms", -1.0))),
		"rebuild_ms": _num(float(Time.get_ticks_usec() - t_rebuild) / 1000.0),
		"old_ms": _num(old_ms),
		"map_ms": _num(float(Time.get_ticks_usec() - t_map) / 1000.0),
	}
	row["delta"] = _delta_block(row["old"], row["new"])
	return row


# 每版一列指标（同一段代码算两遍 ⇒ 口径强制一致）。
# with_real   : 该版有没有真实 has_river（只新版有）+ post 阶段 E 的诊断
# elev_main   : 主口径 E（两版都是 base 阶段 E）
# elev_alt    : 仅新版有用（post 阶段 E，纯诊断）；旧版传同一个 elev_main
# parent      : 该版 hydro_parent（旧版是 §3.5 重建的）
# river_proxy : 该版代理河流格
# has_river   : 该版真实 has_river（旧版为空数组 ⇒ 跳过代理校验与真实列）
func _metrics_for_version(with_real: bool, elev_main: PackedFloat32Array,
		elev_alt: PackedFloat32Array,
		parent: PackedInt32Array, river_proxy: PackedByteArray, has_river: PackedByteArray,
		ridge_e0: PackedFloat32Array, high_flag: PackedByteArray,
		fill: PackedFloat32Array, land: PackedByteArray,
		terr_main: PackedByteArray, terr_alt: PackedByteArray,
		nbr: PackedInt32Array, w: int, h: int, n: int, channel_init: int) -> Dictionary:
	var conn := _ocean_connected(terr_main, nbr, w, h)
	var m2b := _m2b_metrics(elev_main, fill, parent, land, conn, high_flag, nbr, n,
			HYDRO_LAKE_MIN_DEPTH_FALLBACK)
	var c_proxy := _c_metrics(elev_main, river_proxy, parent, ridge_e0, high_flag, nbr, n, land)
	var out := {
		"m1": {},
		"m2b": m2b,
		"c1": _num(float(c_proxy["c1"])),
		"c1_land": _num(float(c_proxy["c1_land"])),
		"c2": _num(float(c_proxy["c2"])),
		"c3": _num(float(c_proxy["c3"])),
		"c3_both": _num(float(c_proxy["c3_both"])),
		"c3_cell": _num(float(c_proxy["c3_cell"])),
		"segments": int(c_proxy["segments"]),
		"river_cells": int(c_proxy["cells"]),
		"up_count_channel_init": channel_init,
		"proxy_ok": false,
		"dc1_proxy_vs_real": null,
		"has_river_used": false,
	}
	# 真实 has_river 版（只有新版有）：校验代理 + 供 lead 交叉参考
	if with_real and has_river.size() == n:
		var c_real := _c_metrics(elev_main, has_river, parent, ridge_e0, high_flag, nbr, n, land)
		out["has_river_used"] = true
		out["c1_real"] = _num(float(c_real["c1"]))
		out["c1_land_real"] = _num(float(c_real["c1_land"]))
		out["c2_real"] = _num(float(c_real["c2"]))
		out["c3_real"] = _num(float(c_real["c3"]))
		out["segments_real"] = int(c_real["segments"])
		out["river_cells_real"] = int(c_real["cells"])
		var d := absf(float(c_real["c1"]) - float(c_proxy["c1"]))
		if is_nan(float(c_real["c1"])) or is_nan(float(c_proxy["c1"])):
			d = NAN
		out["dc1_proxy_vs_real"] = _num(d)
		out["proxy_ok"] = (not is_nan(d)) and d <= PROXY_C1_TOL
	# post 阶段 E 的 C1/C2（纯诊断：只对"新版"有意义；旧版没有 post 阶段 E）
	if with_real and elev_alt.size() == n and terr_alt.size() == n:
		var c_post := _c_metrics(elev_alt, river_proxy, parent, ridge_e0, high_flag, nbr, n, land)
		out["c1_post_stage"] = _num(float(c_post["c1"]))
		out["c2_post_stage"] = _num(float(c_post["c2"]))
	return out


func _delta_block(old_m: Dictionary, new_m: Dictionary) -> Dictionary:
	var d := {}
	var o1: Dictionary = old_m.get("m1", {})
	var n1: Dictionary = new_m.get("m1", {})
	d["M1"] = null
	if o1.size() > 0 and n1.size() > 0:
		d["M1"] = _diff(o1.get("rate_land", null), n1.get("rate_land", null))
		d["M1_all"] = _diff(o1.get("rate_all", null), n1.get("rate_all", null))
		d["null"] = _diff(o1.get("null_land", null), n1.get("null_land", null))
	d["C1"] = _diff(old_m.get("c1", null), new_m.get("c1", null))
	d["C2"] = _diff(old_m.get("c2", null), new_m.get("c2", null))
	d["C3"] = _diff(old_m.get("c3", null), new_m.get("c3", null))
	var ob: Dictionary = old_m.get("m2b", {})
	var nb: Dictionary = new_m.get("m2b", {})
	d["M2b"] = _diff(ob.get("basins_high", null), nb.get("basins_high", null))
	d["M2b_cells"] = _diff(ob.get("cells_high", null), nb.get("cells_high", null))
	return d


# 差值是 Variant 入参（可能是 null / 已跳过）⇒ 返回 float 或 null，绝不用 := 接收 Variant。
func _diff(a, b) -> Variant:
	if a == null or b == null:
		return null
	var fa := float(a)
	var fb := float(b)
	if is_nan(fa) or is_nan(fb) or not is_finite(fa) or not is_finite(fb):
		return null
	return fb - fa


# ═════════════════════════════════════════════════════════════════════════════
# 公共参照场：land_shared 上的 p75 / 脊顶格 / 高脊带 / 零假设抽样
# ═════════════════════════════════════════════════════════════════════════════

func _shared_ridge_reference(ridge_e0: PackedFloat32Array, land: PackedByteArray,
		nbr: PackedInt32Array, n: int, seed_v: int) -> Dictionary:
	var land_vals := PackedFloat32Array()
	for i in range(n):
		if land[i] != 0:
			land_vals.append(float(ridge_e0[i]))
	if land_vals.size() < MIN_SAMPLE:
		return {"ok": false, "reason": "陆地格 %d < %d，p75/脊顶无意义" % [land_vals.size(), MIN_SAMPLE]}
	land_vals.sort()
	var p75 := _percentile(land_vals, RIDGE_P75)
	var high_flag := PackedByteArray()
	high_flag.resize(n)
	high_flag.fill(0)
	for i in range(n):
		if float(ridge_e0[i]) >= p75:
			high_flag[i] = 1
	# 脊顶格：land 内 ridge_e0 ≥ p75，且是 6 邻局部极大（不弱于全部邻居 + 严格大于至少一个）
	var tops := PackedInt32Array()
	for i in range(n):
		if land[i] == 0:
			continue
		var ri := float(ridge_e0[i])
		if ri <= 0.0 or ri < p75:
			continue
		var base_i := i * 6
		var is_max := true
		var strictly_greater := false
		var nb_valid := 0
		for d in range(6):
			var j := int(nbr[base_i + d])
			if j < 0:
				continue
			nb_valid += 1
			var rj := float(ridge_e0[j])
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
	var sample := _zero_hyp_sample(land, tops.size(), n, seed_v)
	return {
		"ok": true, "p75": p75, "high_flag": high_flag, "tops": tops,
		"sample": sample, "land_cells": land_vals.size(),
	}


# 零假设抽样：固定 RNG（seed × 1000003 + n），从陆地格池里无放回抽 k 个（Fisher-Yates 前缀）。
# 返回空数组 = 抽不出来（k <= 0 或陆地格不足），调用方按 n/a 处理。
func _zero_hyp_sample(land: PackedByteArray, k: int, n: int, seed_v: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if k <= 0:
		return out
	var pool := PackedInt32Array()
	for i in range(n):
		if land[i] != 0:
			pool.append(i)
	if pool.size() < k:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed_v) * ZERO_HYP_SEED_MUL + int(n)
	for t in range(k):
		var j := t + rng.randi_range(0, pool.size() - 1 - t)
		var tmp := int(pool[t])
		pool[t] = pool[j]
		pool[j] = tmp
		out.append(pool[t])
	return out


# M1'(版) = |tops ∩ 分水岭| / |tops|；两种口径（ws_land 主 / ws_all 副）一次算完。
# 零假设用**同一批抽样下标**在本版分水岭掩码上取值 ⇒ 两版差值只来自排水网。
func _m1prime_of(tops: PackedInt32Array, ws_pair: Array, sample: PackedInt32Array) -> Dictionary:
	var ws_all: PackedByteArray = ws_pair[0]
	var ws_land: PackedByteArray = ws_pair[1]
	var hit_land := 0
	var hit_all := 0
	for t in range(tops.size()):
		if ws_land[tops[t]] != 0:
			hit_land += 1
		if ws_all[tops[t]] != 0:
			hit_all += 1
	var rate_land := NAN
	var rate_all := NAN
	if tops.size() > 0:
		rate_land = float(hit_land) / float(tops.size())
		rate_all = float(hit_all) / float(tops.size())
	var null_land := NAN
	var null_all := NAN
	if sample.size() > 0:
		var n_land := 0
		var n_all := 0
		for t in range(sample.size()):
			if ws_land[sample[t]] != 0:
				n_land += 1
			if ws_all[sample[t]] != 0:
				n_all += 1
		null_land = float(n_land) / float(sample.size())
		null_all = float(n_all) / float(sample.size())
	return {
		"rate_land": _num(rate_land), "rate_all": _num(rate_all),
		"null_land": _num(null_land), "null_all": _num(null_all),
		"tops": tops.size(), "sample": sample.size(),
		"hit_land": hit_land, "hit_all": hit_all,
	}


# ═════════════════════════════════════════════════════════════════════════════
# §3.5 重建：Priority-Flood（最小堆填洼）+ parent=关闭者 + fill 面
# 与 world_ext_generate.cpp:902-965 同构：种子 = 南北两行、东西环绕、不加 ε、parent 指向关闭者
# ═════════════════════════════════════════════════════════════════════════════

func _priority_flood_parent(elev: PackedFloat32Array, nbr: PackedInt32Array,
		w: int, h: int) -> Dictionary:
	var n := w * h
	var fill := elev.duplicate()
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var seen := PackedByteArray()
	seen.resize(n)
	seen.fill(0)
	if elev.size() != n:
		return {"fill": PackedFloat32Array(), "parent": PackedInt32Array()}
	_heap = PackedInt64Array()
	_heap.resize(n + 1)
	_heap_n = 0
	# 1) 种子 = row 0 与 row h-1 的全部格（与地形无关；C++ 只看 row，不看地形）
	var rows: Array = [0]
	if h > 1:
		rows.append(h - 1)
	for rr in rows:
		var r0 := int(rr)
		for col in range(w):
			var i := r0 * w + col
			if seen[i] != 0:
				continue
			seen[i] = 1
			_heap_push(_pack(_level_scaled(float(fill[i])), i))
	# 2) 最小堆按 (fill, idx) 字典序弹出
	while _heap_n > 0:
		var key := _heap_pop()
		var cur := key & INDEX_MASK
		var fc := float(fill[cur])
		var base_i := cur * 6
		for d in range(6):
			var ni := int(nbr[base_i + d])
			if ni < 0 or seen[ni] != 0:
				continue
			seen[ni] = 1
			var spill := float(elev[ni])
			if fc > spill:
				spill = fc
			fill[ni] = spill
			parent[ni] = cur
			_heap_push(_pack(_level_scaled(spill), ni))
	return {"fill": fill, "parent": parent}


# 逐格一致率：重建 parent 与真实 hydro_parent_arr 相同的比例（−1 也必须相同）。
func _parent_consistency(rebuilt: PackedInt32Array, real: PackedInt32Array, n: int) -> float:
	if rebuilt.size() != n or real.size() != n:
		return 0.0
	var same := 0
	for i in range(n):
		if rebuilt[i] == real[i]:
			same += 1
	return float(same) / float(n)


# 升序 dist 的下标序（计数排序）。降序遍历它 = 合法"上游先"拓扑序。
func _order_by_dist(dist: PackedInt32Array, n: int) -> PackedInt32Array:
	var max_d := 0
	for i in range(n):
		var dv := int(dist[i])
		if dv > max_d:
			max_d = dv
	var cnt := PackedInt32Array()
	cnt.resize(max_d + 2)
	cnt.fill(0)
	for i in range(n):
		var dv := int(dist[i])
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
		var dv := int(dist[i])
		if dv < 0:
			dv = 0
		order[off[dv]] = i
		off[dv] += 1
	return order


# up_count：**与 world_ext_generate.cpp:1125-1133 同定义** —— 陆地格初值 1、水体 0，
# 沿 parent 向父累加。用 dist 降序（= 出栈逆序遍历的等价拓扑序）保证一遍收敛。
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
		var i := int(order[k])
		if up[i] == 0:
			continue
		var p := int(parent[i])
		if p < 0 or p >= n or p == i:
			continue
		up[p] += up[i]
	return up


# §3.4 的代理河流格：陆地 且 up_count ≥ channel_init（两版同一条规则）。
func _river_proxy(up: PackedInt32Array, land: PackedByteArray, channel_init: int,
		n: int) -> PackedByteArray:
	var riv := PackedByteArray()
	riv.resize(n)
	riv.fill(0)
	for i in range(n):
		if land[i] == 0:
			continue
		if int(up[i]) >= channel_init:
			riv[i] = 1
	return riv


# ═════════════════════════════════════════════════════════════════════════════
# 排水拓扑：trace_outlet（路径压缩）/ 分水岭 / 拓扑自检
# ═════════════════════════════════════════════════════════════════════════════

# 沿 parent 追到 <0（出口）→ [outlet, dist]：
#   outlet[i] = 出口格下标（−1 = 链异常/无出口）
#   dist[i]   = 到出口的步数（出口自己 = 0）
# 路径压缩 + 回填：每个格只会被 append 进 path 一次 ⇒ 总代价 O(n)。
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
			var p := int(parent[cur])
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
			var idx := int(path[k])
			outlet[idx] = o
			dist[idx] = d
	if guard_bad > 0:
		_notes.append("drainage_walk: %d 条链成环，已按 outlet=-1 处理" % guard_bad)
	return [outlet, dist]


# 分水岭格 = 存在邻格 j，其出口与本格不同。返回 [ws_all, ws_land]：
#   ws_all  : 6 邻**全部**参与比较 —— 计划字面口径。
#   ws_land : 只比较**陆地**邻格 —— 去掉"沿海格/相邻海格出口各异"的伪分水岭（主判据）。
# 关键实现点：**扫完 6 邻再落 flag**。上一轮探针在第一个"出口不同"的邻居处就 break，
# 若那个邻居恰是水格，ws_land 永远拿不到同一格上更强的陆地证据（漏判）。
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
		var oi := int(outlet[i])
		var all_hit := false
		var land_hit := false
		for d in range(6):
			var j := int(nbr[base_i + d])
			if j < 0:
				continue
			if int(outlet[j]) == oi:
				continue
			all_hit = true
			if land[j] != 0:
				land_hit = true
			if land_hit:
				break
		if all_hit:
			ws_all[i] = 1
		if land_hit:
			ws_land[i] = 1
	return [ws_all, ws_land]


# 拓扑自检：dist==0 的格 = 出口。若过半格都是自己的出口，说明 parent 基本全是 −1
# （拓扑没导出），此时"分水岭比例"恒 ≈1 —— 指标无意义，要 SKIP 而不是当成结果。
func _drainage_ok(dist: PackedInt32Array, n: int) -> bool:
	var zero := 0
	for i in range(n):
		if int(dist[i]) <= 0:
			zero += 1
	return zero * 2 <= n


# ═════════════════════════════════════════════════════════════════════════════
# M2b：闭合洼地（填洼深度 ≥ min_depth）与溢流口
# ═════════════════════════════════════════════════════════════════════════════

# 海洋连通 BFS：与 world_ext_generate.cpp:907-928 同构。
# 种子 = 南北两行里 terrain ∈ {OCEAN, COAST} 的格；只沿 {OCEAN, COAST} 扩散。
func _ocean_connected(terr: PackedByteArray, nbr: PackedInt32Array,
		w: int, h: int) -> PackedByteArray:
	var n := w * h
	var conn := PackedByteArray()
	conn.resize(n)
	conn.fill(0)
	if terr.size() != n:
		return conn
	var queue := PackedInt32Array()
	var rows: Array = [0]
	if h > 1:
		rows.append(h - 1)
	for rr in rows:
		var r0 := int(rr)
		for col in range(w):
			var i := r0 * w + col
			var t0 := int(terr[i])
			if t0 != 0 and t0 != 1:
				continue
			if conn[i] != 0:
				continue
			conn[i] = 1
			queue.append(i)
	var head := 0
	while head < queue.size():
		var cur := int(queue[head])
		head += 1
		var base_i := cur * 6
		for d in range(6):
			var ni := int(nbr[base_i + d])
			if ni < 0 or conn[ni] != 0:
				continue
			var t := int(terr[ni])
			if t != 0 and t != 1:
				continue
			conn[ni] = 1
			queue.append(ni)
	return conn


# M2b：闭合洼地数（溢流口落高脊带）+ 面积占比 + 旧口径 cell 计数。
# 洼地格 = 陆地 且 connected==0 且 fill−E ≥ min_depth（三条件与 C++ lake_candidate 同源）。
# 溢流口 = 分量内"parent 落在分量外"的格里 fill 最小者（平局取小下标）。
func _m2b_metrics(elev: PackedFloat32Array, fill: PackedFloat32Array,
		parent: PackedInt32Array, land: PackedByteArray, conn: PackedByteArray,
		high_flag: PackedByteArray, nbr: PackedInt32Array, n: int,
		min_depth: float) -> Dictionary:
	var dep := PackedByteArray()
	dep.resize(n)
	dep.fill(0)
	var dep_cells := 0
	for i in range(n):
		if land[i] == 0:
			continue
		if conn[i] != 0:
			continue
		var depth := float(fill[i]) - float(elev[i])
		if depth < min_depth - HYDRO_LAKE_MIN_SECURE:
			continue
		dep[i] = 1
		dep_cells += 1
	var seen := PackedByteArray()
	seen.resize(n)
	seen.fill(0)
	var queue := PackedInt32Array()
	var basins := 0
	var basins_high := 0
	var no_spill := 0
	var cells_in_high_basin := 0
	var largest := 0
	for i in range(n):
		if dep[i] == 0 or seen[i] != 0:
			continue
		queue.resize(0)
		queue.append(i)
		seen[i] = 1
		var head := 0
		var size := 0
		var best_spill := -1
		var best_fill := INF
		while head < queue.size():
			var cur := int(queue[head])
			head += 1
			size += 1
			var p := int(parent[cur])
			var escape := false
			if p < 0:
				escape = true
			elif dep[p] == 0:
				escape = true
			if escape:
				var fc := float(fill[cur])
				if fc < best_fill or (fc == best_fill and (best_spill < 0 or cur < best_spill)):
					best_fill = fc
					best_spill = cur
			var base_i := cur * 6
			for d in range(6):
				var ni := int(nbr[base_i + d])
				if ni < 0 or seen[ni] != 0 or dep[ni] == 0:
					continue
				seen[ni] = 1
				queue.append(ni)
		basins += 1
		if size > largest:
			largest = size
		if best_spill < 0:
			no_spill += 1
		elif high_flag[best_spill] != 0:
			basins_high += 1
			cells_in_high_basin += size
	# 旧口径（上一轮 M2_ridge_pits）：pit 格 且 ridge_e0 ≥ p75 的**格数**，便于对齐旧表
	var cells_high := 0
	var cells_pit := 0
	for i in range(n):
		if land[i] == 0:
			continue
		if float(fill[i]) <= float(elev[i]) + PIT_EPS:
			continue
		cells_pit += 1
		if high_flag[i] != 0:
			cells_high += 1
	var area_frac := NAN
	if dep_cells > 0:
		area_frac = float(cells_in_high_basin) / float(dep_cells)
	return {
		"basins": basins,
		"basins_high": basins_high,
		"no_spill": no_spill,
		"dep_cells": dep_cells,
		"dep_cells_high_basin": cells_in_high_basin,
		"dep_area_frac": _num(area_frac),
		"largest_basin": largest,
		"cells_pit": cells_pit,
		"cells_high": cells_high,
		"min_depth": _num(min_depth),
	}


# ═════════════════════════════════════════════════════════════════════════════
# C1 / C2 / C3（河流格 vs 脊带）
# ═════════════════════════════════════════════════════════════════════════════

func _c_metrics(elev: PackedFloat32Array, river: PackedByteArray, parent: PackedInt32Array,
		ridge_e0: PackedFloat32Array, high_flag: PackedByteArray,
		nbr: PackedInt32Array, n: int, land: PackedByteArray) -> Dictionary:
	var cells := 0
	var c1_pass := 0
	var c1_land_pass := 0
	var c1_land_cells := 0
	var band_cells := 0
	var ridge_vals := PackedFloat32Array()
	for i in range(n):
		if river[i] == 0:
			continue
		cells += 1
		ridge_vals.append(float(ridge_e0[i]))
		if high_flag[i] != 0:
			band_cells += 1
		var med := _median_of_neighbors(elev, nbr, i)
		if not is_nan(med) and float(elev[i]) <= med:
			c1_pass += 1
		var med_land := _median_of_land_neighbors(elev, nbr, i, land)
		if not is_nan(med_land):
			c1_land_cells += 1
			if float(elev[i]) <= med_land:
				c1_land_pass += 1
	# C3：河段 = 沿 parent 的相邻河格对 (i, parent[i])，两端都是河格（每条边只数一次）
	var segments := 0
	var seg_high := 0
	var seg_both := 0
	for i in range(n):
		if river[i] == 0:
			continue
		var p := int(parent[i])
		if p < 0 or p >= n or p == i:
			continue
		if river[p] == 0:
			continue
		segments += 1
		var hi := high_flag[i] != 0
		var hp := high_flag[p] != 0
		if hi or hp:
			seg_high += 1
		if hi and hp:
			seg_both += 1
	ridge_vals.sort()
	var c1 := NAN
	if cells > 0:
		c1 = float(c1_pass) / float(cells)
	var c1_land := NAN
	if c1_land_cells > 0:
		c1_land = float(c1_land_pass) / float(c1_land_cells)
	var c2 := NAN
	if ridge_vals.size() > 0:
		c2 = _percentile(ridge_vals, 0.50)
	var c3 := NAN
	var c3_both := NAN
	if segments > 0:
		c3 = float(seg_high) / float(segments)
		c3_both = float(seg_both) / float(segments)
	var c3_cell := NAN
	if cells > 0:
		c3_cell = float(band_cells) / float(cells)
	return {
		"cells": cells, "c1": c1, "c1_land": c1_land, "c2": c2,
		"c3": c3, "c3_both": c3_both, "c3_cell": c3_cell,
		"segments": segments, "seg_high": seg_high, "seg_both": seg_both,
		"band_cells": band_cells,
	}


# 6 邻高程中位数（numpy 口径：6 邻取第 3/4 两值平均）。无有效邻居返回 NAN。
func _median_of_neighbors(values: PackedFloat32Array, nbr: PackedInt32Array, i: int) -> float:
	var tmp := PackedFloat32Array()
	var base_i := i * 6
	for d in range(6):
		var j := int(nbr[base_i + d])
		if j < 0:
			continue
		tmp.append(float(values[j]))
	if tmp.size() == 0:
		return NAN
	tmp.sort()
	return _percentile(tmp, 0.50)


# 只取陆地邻居的中位数（C1_land 口径）；无陆地邻居返回 NAN。
func _median_of_land_neighbors(values: PackedFloat32Array, nbr: PackedInt32Array, i: int,
		land: PackedByteArray) -> float:
	var tmp := PackedFloat32Array()
	var base_i := i * 6
	for d in range(6):
		var j := int(nbr[base_i + d])
		if j < 0 or land[j] == 0:
			continue
		tmp.append(float(values[j]))
	if tmp.size() == 0:
		return NAN
	tmp.sort()
	return _percentile(tmp, 0.50)


# ═════════════════════════════════════════════════════════════════════════════
# 小工具：分位 / hash / 6 邻表 / 掩码 / 水位阈值
# ═════════════════════════════════════════════════════════════════════════════

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


# D6 邻接表：nbr[i*6+d] = 邻居下标（−1 = 无）。与 world_ext_generate_base.cpp 的
# index_for_qr / DQ / DR 逐字一致（东西 posmod 环绕、南北越界返回 −1）。
func _neighbor_table(w: int, h: int) -> PackedInt32Array:
	var n := w * h
	var nbr := PackedInt32Array()
	nbr.resize(n * 6)
	nbr.fill(-1)
	for r in range(h):
		var half := (r - (r & 1)) / 2
		for col in range(w):
			var q := col - half
			var base_i := (r * w + col) * 6
			for d in range(6):
				var nr := r + int(DR[d])
				if nr < 0 or nr >= h:
					continue
				var ncol := q + int(DQ[d]) + ((nr - (nr & 1)) / 2)
				ncol = ((ncol % w) + w) % w
				nbr[base_i + d] = nr * w + ncol
	return nbr


func _land_mask_from_terr(terr: PackedByteArray, n: int) -> PackedByteArray:
	var land := PackedByteArray()
	land.resize(n)
	land.fill(0)
	for i in range(n):
		if not _is_water_tile(int(terr[i])):
			land[i] = 1
	return land


# 镜像 pk_is_water_terrain（gdext/src/world_ext_internal.h:306）：{0,1,18,19,20,21}
func _is_water_tile(t: int) -> bool:
	return t == 0 or t == 1 or t == 18 or t == 19 or t == 20 or t == 21


func _count_flag(flag: PackedByteArray, n: int) -> int:
	var c := 0
	for i in range(n):
		if flag[i] != 0:
			c += 1
	return c


# 计 value >= thr 的格数（这里只用于「E0 >= sea_level 的格数」这一个交叉参照）
func _count_at_least(values: PackedFloat32Array, thr: float, n: int) -> int:
	var c := 0
	for i in range(n):
		if float(values[i]) >= thr:
			c += 1
	return c


# channel_init = max(2, round(base × max(0.25, n/15000)))，与 world_ext_generate.cpp:615-620 同式
func _channel_init_for(n: int) -> int:
	var scale := maxf(float(n) / RIVER_MAP_REF_CELLS, RIVER_MAP_SCALE_FLOOR)
	return maxi(2, int(round(float(RIVER_CHANNEL_INIT_BASE) * scale)))


func _hash32(values: PackedFloat32Array) -> int:
	var bytes := values.to_byte_array()
	var hsh := 0x811C9DC5
	for i in range(bytes.size()):
		hsh = (hsh ^ int(bytes[i])) * 16777619
		hsh = hsh & 0xFFFFFFFF
	return hsh


# ═════════════════════════════════════════════════════════════════════════════
# 二叉最小堆（int64 单值键，零 lambda）：key = int(level×2^30) × 2^20 + idx
# ═════════════════════════════════════════════════════════════════════════════

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
	var top := int(_heap[0])
	_heap_n -= 1
	var last := int(_heap[_heap_n])
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
# 生成链路：base → post_base（全部走真实原生生成，不造数据）
# ═════════════════════════════════════════════════════════════════════════════

# cfg / profile 与 tests/world/ridge_drainage_metrics_test.gd 的 _cfg() / _profile()
# **同源同值**（contracts §D-1 的代表性 profile）—— 冻结基线就是用这份 profile 导出的，
# 差一个键就不是同口径。本文件只额外加 debug_dump_ridge_e0（纯诊断键，不改任何计算）。
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


func _profile() -> Dictionary:
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
		"debug_dump_ridge_e0": 1,
	}


func _gen_base(seed_v: int, w: int, h: int, profile: Dictionary) -> Dictionary:
	var cfg := _cfg(seed_v, w, h)
	var t0 := Time.get_ticks_usec()
	var base_v = _ext.call("run_native_world_generate_base_pass", seed_v, cfg, profile)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var out := {"ok": false, "reason": "", "base": {}, "cfg": cfg, "ms": ms}
	if typeof(base_v) != TYPE_DICTIONARY:
		out["reason"] = "run_native_world_generate_base_pass 未返回 Dictionary（方法未导出？）"
		return out
	var base: Dictionary = base_v
	out["base"] = base
	if int(base.get("rc", -1)) != 0 or bool(base.get("fallback", true)):
		out["reason"] = "base rc=%s fallback=%s reason=%s" % [
			str(base.get("rc", "?")), str(base.get("fallback", "?")),
			str(base.get("reason", "?"))]
		return out
	out["ok"] = true
	return out


func _gen_post(seed_v: int, w: int, h: int, profile: Dictionary, base: Dictionary) -> Dictionary:
	var cfg := _cfg(seed_v, w, h)
	var t0 := Time.get_ticks_usec()
	var post_v = _ext.call("run_native_world_generate_post_base_pass", seed_v, cfg, profile, base)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var out := {"ok": false, "reason": "", "post": {}, "ms": ms}
	if typeof(post_v) != TYPE_DICTIONARY:
		out["reason"] = "run_native_world_generate_post_base_pass 未返回 Dictionary（方法未导出？）"
		return out
	var post: Dictionary = post_v
	out["post"] = post
	if bool(post.get("fallback", true)):
		out["reason"] = "post fallback reason=%s" % str(post.get("reason", "?"))
		return out
	out["ok"] = true
	return out


# ═════════════════════════════════════════════════════════════════════════════
# 冻结数组 IO（裸字节：Float32 LE / Uint8，无文件头）
# ═════════════════════════════════════════════════════════════════════════════

func _read_bytes(path: String) -> PackedByteArray:
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(abs_path)


# PackedByteArray.to_float32_array() 已在本仓库使用（ridge_drainage_metrics_test.gd:1513）
# ⇒ 不是猜测 API。字节数必须严格 = n×4，否则返回空数组（调用方按 SKIP 处理）。
func _read_f32(path: String, n: int) -> PackedFloat32Array:
	var bytes := _read_bytes(path)
	if bytes.size() != n * 4:
		return PackedFloat32Array()
	return bytes.to_float32_array()


func _read_u8(path: String) -> PackedByteArray:
	return _read_bytes(path)


# ═════════════════════════════════════════════════════════════════════════════
# 落盘 / 打印
# ═════════════════════════════════════════════════════════════════════════════

# result.json 的 schema（lead 填表直接取）：
# {
#   "exp": "same_caliber", "generated_utc": str, "godot": str,
#   "hard_fail": int, "row_count": int, "old_columns_enabled": bool,
#   "meta": { test, plan, checklist, purpose, stage_caliber, profile, sea_level, ridge_p75,
#             old_sources, thresholds{...}, caliber{...}, e0_determinism{ok,seed,w,h,n_cells,
#             e0_hash_a, e0_hash_b, ridge_e0_hash_a, ridge_e0_hash_b, base_ms_a, base_ms_b} },
#   "rebuild_check": { min_consistency, consistency_min, adopt_old_columns,
#                      rows:[{seed,w,h,consistency,adopt}] },
#   "rows": [ { seed, w, h, n_cells, ok, reason, rebuild_consistency, old_ms, timing{...},
#               reference{land_shared_cells, land_post_cells, ridge_p75, ridge_tops,
#                         high_ridge_cells, null_sample_cells, channel_init, lake_min_depth},
#               old/new: { m1{rate_land, rate_all, null_land, null_all, tops, sample,
#                              hit_land, hit_all},
#                          m2b{basins, basins_high, no_spill, dep_cells, dep_cells_high_basin,
#                              dep_area_frac, largest_basin, cells_pit, cells_high, min_depth},
#                          c1, c1_land, c2, c3, c3_both, c3_cell, segments, river_cells,
#                          proxy_ok, dc1_proxy_vs_real,
#                          [new only] has_river_used, c1_real, c1_land_real, c2_real, c3_real,
#                                     segments_real, river_cells_real,
#                                     c1_post_stage, c2_post_stage },
#               delta: {M1, M1_all, null, M2b, M2b_cells, C1, C2, C3} } ],
#   "aggregate": { "60x40"|"200x150"|"all": {maps, <mean of each field>} },
#   "skips": [{tag, reason}], "notes": [str]
# }
# NaN/INF 一律落 null（JSON 不接受 NaN）。
func _write_result(data: Dictionary) -> void:
	var path := "%s/result.json" % _out_dir
	var f := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if f == null:
		push_error("[same-caliber] 无法写入 %s" % path)
		_hard_fail += 1
		return
	f.store_string(JSON.stringify(data, "  ", false))
	f.close()


func _print_row(row: Dictionary) -> void:
	if not bool(row.get("ok", false)):
		print("[same-caliber] seed=%d %dx%d [FAIL] %s"
				% [int(row.get("seed", 0)), int(row.get("w", 0)), int(row.get("h", 0)),
				str(row.get("reason", "?"))])
		return
	var old_m: Dictionary = row.get("old", {})
	var new_m: Dictionary = row.get("new", {})
	var o1: Dictionary = old_m.get("m1", {})
	var n1: Dictionary = new_m.get("m1", {})
	var ob: Dictionary = old_m.get("m2b", {})
	var nb: Dictionary = new_m.get("m2b", {})
	var d: Dictionary = row.get("delta", {})
	print(("[same-caliber] seed=%d %dx%d M1'_old=%s null_old=%s | M1'_new=%s null_new=%s | "
			+ "dM1'=%s | M2b_old=%s M2b_new=%s | C1_old=%s C1_new=%s | C2_old=%s C2_new=%s | "
			+ "C3_old=%s C3_new=%s") % [
		int(row.get("seed", 0)), int(row.get("w", 0)), int(row.get("h", 0)),
		_fmt(o1.get("rate_land", null)), _fmt(o1.get("null_land", null)),
		_fmt(n1.get("rate_land", null)), _fmt(n1.get("null_land", null)),
		_signed_of(d.get("M1", null)),
		_fmt_int(ob.get("basins_high", null)), _fmt_int(nb.get("basins_high", null)),
		_fmt(old_m.get("c1", null)), _fmt(new_m.get("c1", null)),
		_fmt(old_m.get("c2", null)), _fmt(new_m.get("c2", null)),
		_fmt(old_m.get("c3", null)), _fmt(new_m.get("c3", null)),
	])
	print(("[same-caliber]   all6: M1'_old=%s null_old=%s | M1'_new=%s null_new=%s | "
			+ "high_ridge_dep_area_old=%s new=%s | proxy C1_real=%s dC1=%s %s")
			% [
		_fmt(o1.get("rate_all", null)), _fmt(o1.get("null_all", null)),
		_fmt(n1.get("rate_all", null)), _fmt(n1.get("null_all", null)),
		_fmt(ob.get("dep_area_frac", null)), _fmt(nb.get("dep_area_frac", null)),
		_fmt(new_m.get("c1_real", null)), _fmt(new_m.get("dc1_proxy_vs_real", null)),
		"[代理可信]" if bool(new_m.get("proxy_ok", false)) else "[代理不可信]",
	])
	print("[same-caliber]   verdict: %s" % _verdict_dm1(d.get("M1", null)))


func _print_summary(aggregate: Dictionary, rows: Array) -> void:
	var a_all: Dictionary = aggregate.get("all", {})
	var a_s: Dictionary = aggregate.get("60x40", {})
	var a_l: Dictionary = aggregate.get("200x150", {})
	print(("[same-caliber/summary] maps=%d | mean M1'_old=%s null_old=%s | M1'_new=%s "
			+ "null_new=%s | dM1'=%s | M2b_old=%s M2b_new=%s | C1_old=%s C1_new=%s | "
			+ "C2_old=%s C2_new=%s | C3_old=%s C3_new=%s") % [
		int(a_all.get("maps", 0)),
		_fmt(a_all.get("M1_old", null)), _fmt(a_all.get("null_old", null)),
		_fmt(a_all.get("M1_new", null)), _fmt(a_all.get("null_new", null)),
		_signed_of(a_all.get("dM1", null)),
		_fmt(a_all.get("M2b_old", null)), _fmt(a_all.get("M2b_new", null)),
		_fmt(a_all.get("C1_old", null)), _fmt(a_all.get("C1_new", null)),
		_fmt(a_all.get("C2_old", null)), _fmt(a_all.get("C2_new", null)),
		_fmt(a_all.get("C3_old", null)), _fmt(a_all.get("C3_new", null)),
	])
	print("[same-caliber/summary] 60x40 maps=%d dM1'=%s | 200x150 maps=%d dM1'=%s"
			% [int(a_s.get("maps", 0)), _signed_of(a_s.get("dM1", null)),
			int(a_l.get("maps", 0)), _signed_of(a_l.get("dM1", null))])
	print("[same-caliber/summary] verdict(all)=%s | E0 det=%s | rebuild min consistency=%.4f"
			% [_verdict_dm1(a_all.get("dM1", null)),
			"OK" if _e0_determinism_ok else "FAIL",
			_rebuild_min_consistency])
	var proxy_bad := 0
	for r in rows:
		var nm: Dictionary = r.get("new", {})
		if nm.size() > 0 and not bool(nm.get("proxy_ok", false)):
			proxy_bad += 1
	if proxy_bad > 0:
		print("[same-caliber/summary] WARN %d 张图的 C1 代理与真实 has_river 差 > %.2f ⇒ 代理列带 [代理不可信] 标记"
				% [proxy_bad, PROXY_C1_TOL])


# §3.2 判读表（写进打印，lead 直接抄）
func _verdict_dm1(v) -> String:
	if v == null:
		return "n/a（旧列缺失/已 SKIP）"
	var d := float(v)
	if is_nan(d) or not is_finite(d):
		return "n/a（旧列缺失/已 SKIP）"
	if d >= M1_BAND:
		return "新−旧=%+.4f ≥ +%.2f ⇒ 脊抬升确实把分水岭拉向脊（幅度见数值）" % [d, M1_BAND]
	if d <= -M1_BAND:
		return "新−旧=%+.4f ≤ −%.2f ⇒ 退步，需排查（§2.3）" % [d, M1_BAND]
	return "新−旧=%+.4f，|d| < %.2f ⇒ 脊抬升对分水岭位置基本无作用" % [d, M1_BAND]


func _aggregate(rows: Array, w: int) -> Dictionary:
	var sub: Array = []
	for r in rows:
		if not bool(r.get("ok", false)):
			continue
		if w != 0 and int(r.get("w", 0)) != w:
			continue
		sub.append(r)
	var out := {"maps": sub.size()}
	var fields := [
		["M1_old", "old.m1.rate_land"], ["null_old", "old.m1.null_land"],
		["M1_new", "new.m1.rate_land"], ["null_new", "new.m1.null_land"],
		["M1_all_old", "old.m1.rate_all"], ["M1_all_new", "new.m1.rate_all"],
		["M2b_old", "old.m2b.basins_high"], ["M2b_new", "new.m2b.basins_high"],
		["M2b_cells_old", "old.m2b.cells_high"], ["M2b_cells_new", "new.m2b.cells_high"],
		["dep_area_old", "old.m2b.dep_area_frac"], ["dep_area_new", "new.m2b.dep_area_frac"],
		["C1_old", "old.c1"], ["C1_new", "new.c1"],
		["C2_old", "old.c2"], ["C2_new", "new.c2"],
		["C3_old", "old.c3"], ["C3_new", "new.c3"],
		["C1_real_new", "new.c1_real"],
		["dM1", "delta.M1"], ["null_delta", "delta.null"],
		["C1_delta", "delta.C1"], ["C2_delta", "delta.C2"], ["C3_delta", "delta.C3"],
	]
	for pair in fields:
		var key := str(pair[0])
		var path := str(pair[1])
		out[key] = _mean_path(sub, path)
	out["maps_old_ok"] = _count_path_non_null(sub, "old.m1.rate_land")
	return out


func _mean_path(rows: Array, path: String) -> Variant:
	var s := 0.0
	var c := 0
	for r in rows:
		var v = _dig(r, path)
		if v == null:
			continue
		var f := float(v)
		if is_nan(f) or not is_finite(f):
			continue
		s += f
		c += 1
	if c == 0:
		return null
	return s / float(c)


func _count_path_non_null(rows: Array, path: String) -> int:
	var c := 0
	for r in rows:
		var v = _dig(r, path)
		if v != null:
			c += 1
	return c


# "a.b.c" 逐层取 Dict（Variant 返回；用裸 = 接收，不用 :=）
func _dig(root, path: String) -> Variant:
	var cur = root
	for part in path.split("."):
		if typeof(cur) != TYPE_DICTIONARY:
			return null
		if not (cur as Dictionary).has(str(part)):
			return null
		cur = (cur as Dictionary).get(str(part))
	return cur


func _rebuild_check_block(rows: Array) -> Dictionary:
	var out: Array = []
	var min_c := 1.0
	var adopt := true
	var checked := 0
	for r in rows:
		if not bool(r.get("ok", false)):
			continue
		var v = r.get("rebuild_consistency", null)
		var ok := false
		var cons := NAN
		if v != null:
			cons = float(v)
			ok = cons >= CONSISTENCY_MIN
			checked += 1
			if cons < min_c:
				min_c = cons
			if not ok:
				adopt = false
		else:
			adopt = false
		out.append({
			"seed": int(r.get("seed", 0)), "w": int(r.get("w", 0)), "h": int(r.get("h", 0)),
			"consistency": _num(cons), "adopt": ok,
		})
	return {
		"min_consistency": _num(min_c) if checked > 0 else null,
		"consistency_min": CONSISTENCY_MIN,
		"maps_checked": checked,
		"adopt_old_columns": adopt and _old_columns_enabled,
		"rows": out,
	}


func _skip(tag: String, reason: String) -> void:
	_skips.append({"tag": tag, "reason": reason})
	print("[same-caliber] %s: [SKIP] %s" % [tag, reason])


func _note(msg: String) -> void:
	_notes.append(msg)
	print("[same-caliber] note: %s" % msg)


func _num(v: float) -> Variant:
	# JSON 里 NaN/INF 不是合法值：统一落 null。
	if is_nan(v) or not is_finite(v):
		return null
	return v


func _fmt(v) -> String:
	if v == null:
		return "n/a"
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return "%.4f" % float(v)
	return str(v)


func _fmt_int(v) -> String:
	if v == null:
		return "n/a"
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return "%d" % int(v)
	return str(v)


func _signed_of(v) -> String:
	if v == null:
		return "n/a"
	var f := float(v)
	if is_nan(f) or not is_finite(f):
		return "n/a"
	var s := "%.4f" % f
	if f < 0.0:
		return s
	return "+" + s
