extends SceneTree

# ─────────────────────────────────────────────────────────────────────────────
# ridge_drainage_metrics_test.gd — 脊抬升重构 P5 的结构指标 M1–M5 + 确定性门禁
#
# 规格（逐条对应）：
#   docs/plans/terrain-ridge-uplift-contracts.md §C（M1–M5 定义）、§D-1（种子/cfg/profile 契约）
#   docs/plans/terrain-ridge-uplift-plan.md       §6.2（阈值）、§6.3（分布回归带）
#
# ── 门禁分级（2026-11-18 起：**逐项声明**，不再是 P5_STRICT 一个全局开关）──────────────
# 来源：docs/plans/terrain-followup-verification-plan.md §2.3（拆分门禁）+ 2026-11-18 实测值。
#   硬门禁（判据有效 / 不变量）：
#     · M2   闭合洼地总数（陆地 pit 格数合计）≤ 2026-11-18 实测 × 1.2 的回归线
#     · M3   Hack 指数 ∈ [0.5, 0.65]（只有 M3_points >= 100 的图参与判定）
#     · T3-1 原生成功（rc=0、无 fallback）、T3-2 同种子两次逐位一致
#   硬门禁（回归线 = 2026-11-18 实测 × 1.2，只防「进一步恶化」）：
#     · M2b  降幅 ≥ 实测降幅 × 1.2（实测 −700% ⇒ 回归线 −840%；**负值 = 恶化**，取绝对值放宽）
#     · M4   流路直线度 ≥ 实测 / 1.2（实测 1.2145 ⇒ 回归线 1.0121；**越高越好**，故向下放宽）
#   只记录（打印 [RECORD-ONLY]，计入 targets_hit/missed，**不影响退出码**）：
#     · M1   Spearman(ridge_add, log10 A)（计划 §5.1 要换成 M1'）
#     · M5   平顶率（字面阈值恒空集；计划 §5.5 要换成 M5a/M5b）
# 背景不变：2026-11-18 实测 M1 / M2b / M3 未达成、M5 阈值不可达，用户已接受「部分达标」
# （详见 docs/plans/terrain-ridge-uplift-checklist.md 附 A/附 B）。上一轮（F10）把 M1–M5
# **整体**降级为「只记录」被判定为约束力过度削弱，故这次按上表逐项拆分而不是一刀切。
# ⚠ 已知后果：M3 实测 0.6931 已超出 0.65 ⇒ M3 是硬门禁时本测试会 FAIL —— 那是 200×150
#   assert 种子的真实结论，不是门禁坏了；要等计划 §6 的重标定落地才可能转绿。
#
# 跑法（root 统一编译 + 执行；本文件**不**自行启动 Godot / scons）：
#   # 门禁（缺省 assert 模式）
#   godot --headless -s res://tests/world/ridge_drainage_metrics_test.gd
#   # 采集：32 种子 × 60×40 + 8 种子 × 200×150，落盘给 lead 与基线比对
#   $env:P5_MODE="capture"; $env:P5_LABEL="after_p5_2"
#   godot --headless -s res://tests/world/ridge_drainage_metrics_test.gd
#   # 用**同一份指标实现**给冻结的 P5-0 基线重算指标（纯离线，不碰 DLL）
#   $env:P5_MODE="baseline"
#   godot --headless -s res://tests/world/ridge_drainage_metrics_test.gd
#
# 三种模式（`P5_MODE`；也接受 `-- capture` 这样的用户参数）：
#   · assert（缺省）：4 种子 × 60×40 + 1 种子 × 200×150，按 §6.2 门禁 M1–M5，
#     并断言「同 seed 两次 elevation_arr 逐位一致」。判不了的条目打 SKIP（见下面 SKIP 清单）。
#   · capture：contracts §D-1 的完整集合（32 × 60×40 + 8 × 200×150），**不做断言**，
#     把每个种子的 M1–M5 + 分布统计写进 `res://tmp/p5_calib/<P5_LABEL>/metrics.json`；
#     同时按 `_p5_freeze_baseline.gd` 的同款布局写 `index.json` + 四个 `.bin`
#     （elev / ridge / terr / land），让 lead 的 `tmp/p5_calib/metrics.py` 能直接吃这份输出做交叉校验。
#   · baseline：只读 `res://tmp/p5_calib/baseline/` 里冻结的 `.bin`，用**同一份**指标实现
#     重算 M1–M5，写 `metrics_gd.json` 并与 lead 的 `metrics_py.json` 逐项对照。
#
# ── 与契约 §C 的三处口径裁决（都有实测证据，详见对应代码注释）─────────────────────────
#   1) **M3 的 L 取「上游最长汇流路径」`l_up`，不是「到出口步数」`l_down`。**
#      §C 用同一个 L 同时定义 M3（Hack 律）与 M4（流路直线度），但 Hack 律的 L 必须随 A 单调增，
#      而「到出口步数」随 A 单调减 —— P5-0 冻结基线实测 M3(l_down) = −2.51 / −6.27 / −0.28 /
#      +0.21 / −0.10（60×40 多为 NaN，样本 < 8），永远进不了 §6.2 要求的 [0.5, 0.65]；
#      改用 l_up 后同一批基线是 +0.569 / +0.645 / +0.611 / +0.601 → 正是 [0.5, 0.65] 的口径。
#      故 M3 用 l_up；`M3_down` 仍按 §C 字面同时落盘（只作诊断、不设阈值），两个数都可见。
#   2) **M2(b) 的 p75 是「陆地格 ridge_add 的 p75」**（numpy percentile 线性插值口径，与
#      `tmp/p5_calib/metrics.py` 一致），不是全图 p75。
#   3) **M5 在其字面阈值下恒为空集**：`land_h = elevation − sea_level > 0.6` 要求 elevation > 1.24，
#      而 P5-0 基线 40 个种子实测 land_h 最大 0.3384（D-2 的 land_elev_cap ≈ 0.978），候选格恒为 0。
#      因此 M5 字面值恒 0.0、无从判定 → 打 SKIP 并附证据；另给 `M5_p90`（陆地 land_h ≥ p90 的格里
#      局地起伏 < 0.02 的比例）作为**可用信号**，只落盘/打印，**不作门禁**（非契约条目）。
#   4) **M1 的 Spearman 用平均秩（并列取平均位次），不用 `argsort(argsort())` 的序号秩。**
#      序号秩会在大量并列（log10 A 在 A=1…3 上成堆）时按数组顺序硬编号 —— 实测同一批基线
#      M1 会因并列顺序摆动 ±0.03…0.14，跨实现无法比对；平均秩是 Spearman 的标准定义、
#      与并列顺序无关，且已与 numpy 平均秩 Pearson 逐个种子验证到 |Δ| = 0。
#      **M1 的现状**（平均秩，P5-0 全量基线）：60×40 均值 −0.286（单图 −0.148…−0.380）、
#      200×150 均值 −0.349。即 §6.2 的「≤ −0.3」在基线上**已经基本达成**（60×40 差 0.014），
#      作为 P5-1 的「改善证据」几乎没有余量 —— 若标定后仍想证明改善，建议改成
#      「相对基线再降 ΔM1 ≥ 0.05」。本文件把 M1 列为**只记录**（计划 §2.3），T_M1 只当参考线
#      打印（`P5_T_M1` 可覆盖），输出里同时打印基线均值与 Δ，便于 lead 换判据。
#
# ── 阈值（具名常量，来源 = 2026-11-18 实测 + 计划 §2.3；**不要凭空改数**）──────────────
#   M2   ≤ MEASURED_M2_PITS × GATE_SLACK        = 425 × 1.2 = 510（实测 425，基线 614）
#   M2b  降幅 ≥ MEASURED_M2B_DROP × GATE_SLACK   = −700% × 1.2 = −840%（实测 6 → 48）
#   M3   ∈ [T_M3_LO, T_M3_HI]                    = [0.5, 0.65]（§6.2 原阈值；实测 0.6931）
#   M4   ≥ MEASURED_M4 / GATE_SLACK              = 1.2145 / 1.2 = 1.0121（基线 1.1194）
#   M1   只记录：T_M1 仅作参考线打印（§6.2 原目标，不参与退出码）
# 环境变量覆盖：P5_T_M3_LO / P5_T_M3_HI / P5_T_M1 仍可用（调参不改代码）；
# M2 / M2b / M4 的回归线不允许用环境变量放宽 —— 它们就是「不许再恶化」的下限。
#
# ── 基线来源（M2/M2b/M4 的对照打印、M5 的较基线判定需要它）────────────────────────
#   按顺序尝试：`P5_BASELINE`（JSON 路径）→ `tmp/p5_calib/baseline/metrics_gd.json`
#   （本脚本 baseline 模式产出）→ `tmp/p5_calib/baseline/metrics_py.json`（lead 的 python 版）。
#   都读不到时退回文件内的 `BASELINE_FALLBACK` 常量 —— 那是 2026-11-18 由
#   `_p5_freeze_baseline.gd` 冻结、`tmp/p5_calib/metrics.py` 算出的**全量种子均值**
#   （60×40 32 个种子 / 200×150 8 个种子），与 assert 模式的 4+1 个种子不是同一集合，
#   只作量级参照（打印时明确标注 fallback）。**基线一旦重冻结，请优先用上面两个 JSON 路径。**
#   硬门禁 M2 / M4 用**绝对回归线**判定，没有基线也能判（不因缺基线 SKIP）。
#
# ── SKIP 清单（不假装通过；每条都打印 `<tag>: SKIP reason=...` 并计入 _skips）──────────
#   · ridge_add_arr 缺失（DLL 未含 P5-0.1 诊断输出）→ M1 / M2(b) 全 SKIP
#   · M2(b) 基线合计为 0 → 「较基线降幅」无定义 → SKIP
#   · M5 无基线可用 → SKIP
#   · M5 候选格 = 0（字面阈值恒空集）→ SKIP
#   · M3：样本 < 8（A ≥ 100 的格太少）→ 该图 M3 落 null；样本 < 100 → 只作参考不判定；
#     没有一张图达到 100 → 整体 SKIP
#   · base pass fallback / rc != 0 → 该行指标不可信：T3-1 直接 FAIL（合法输入不该 fallback）
#   （注：M4 不再因缺基线 SKIP —— 它的门禁是绝对回归线）
#
# ── 实现要点 ───────────────────────────────────────────────────────────────────
#   · 排水网：D6 邻接与 `gdext/src/world_ext_generate_base.cpp` 的 `index_for_qr` 逐字一致
#     （`col = q + (r − (r&1))/2`、经度 posmod 环绕、南北越界返回 −1）。
#   · Priority-Flood（Barnes 2014）：种子 = 南北两行（东西环绕，故没有东西边界），
#     `filled[nb] = max(elev[nb], filled[cur])`，**不加 ε、不抖动**，与 metrics.py 同构；
#     手写二叉堆，键 = `int(filled × 2^30) × 2^20 + idx`（int64 单值排序 ⇒ 平局按 idx 定序，
#     与 Python heapq 的 (level, idx) 元组序一致，O(log n)、零 lambda）。
#   · 受体：`rcv[i] = argmax_d(filled[i] − filled[nb_d])`，只接受**严格更低**，平局取 d 小者，
#     无则 −1（= 出口）。与 plan §3.4 / metrics.py 一致。
#   · 汇水面积 A：初值 1，沿 proc 逆序（上游先）累加到受体，O(n)。
#   · `l_down / outlet`：沿 proc 正序（父先于子）递推，O(n)；
#     `l_up`：沿 proc 逆序把 `l_up[i]+1` 推给受体取 max（= 最长上游路径），O(n)。
#     （metrics.py 的 `area_and_lengths` 走记忆化链，且 `rcv<0` 链的 L 有多 +1 偏移 ——
#      基线 seed=20260718@200×150：py 版 M4=1.4990 vs 本文 1.2798；只影响绝对值，不影响 A/B 方向。）
#   · Spearman：平均秩（并列取平均位次）—— 把「值量化 × m + 局部下标」打包成 int64 后
#     `PackedInt64Array.sort()` 一次原生排序，再线性走等值区段取平均位次回填；O(m log m)、
#     零 lambda、零逐元素比较排序（30k 元素上比 sort_custom 快一个数量级）。
#   · M3 的判定样本下限：只在 `M3_points >= 100` 的图上判（实际就是 200×150）。60×40 上
#     A ≥ 100 的格只有 3–13 个，同一批基线实测 M3 在 0.29…1.40 之间乱跳 —— 那是采样误差，
#     不是地形的 Hack 指数；这些图仍然落盘/打印，只是不参与断言。
#   · 确定性：所有数值累积只按**固定下标序 / proc 序 / 排序后的键序**推进，
#     不读 Dictionary 的遍历序、不用随机数（直方图统计完再按下标升序转 dict 输出）。
# ─────────────────────────────────────────────────────────────────────────────

const SEED_BASE := 20260718
const W_SMALL := 60
const H_SMALL := 40
const W_LARGE := 200
const H_LARGE := 150
const N_SMALL_CAPTURE := 32
const N_LARGE_CAPTURE := 8
const N_SMALL_ASSERT := 4
const N_LARGE_ASSERT := 1

const OUT_ROOT := "res://tmp/p5_calib"
const BASELINE_DIR := "res://tmp/p5_calib/baseline"

const SEA_FALLBACK := 0.64          # cfg.sea_level（与 _p5_freeze_baseline.gd / contracts §D-1 同值）
const PIT_EPS := 1.0e-6             # 契约 §C：填洼面 > 原面 + 1e-6 判为 pit
const PLATEAU_RELIEF := 0.02        # 契约 §C M5：自身+6 邻 max−min < 0.02
const M5_MIN_LAND_H := 0.6          # 契约 §C M5：elevation − sea_level > 0.6（见文件头裁决 3）
const STEM_MIN_AREA := 100.0        # 契约 §C M3/M4：A >= 100
const MIN_SAMPLE := 8               # 与 metrics.py 同：样本 < 8 不下结论
const M3_JUDGE_MIN_POINTS := 100    # M3 只在样本足够的图上判定（见 _check_m3 注释）

# ── 门禁阈值：具名常量（来源 2026-11-18 实测 + 计划 §2.3，见文件头「阈值」）──────────────
const GATE_SLACK := 1.2            # 计划 §2.3：回归线 = 2026-11-18 实测值 × 1.2
const MEASURED_M2_PITS := 425.0    # 实测：assert 集（4×60×40 + 1×200×150）陆地 pit 格数合计
const MEASURED_M2B_DROP := -7.0    # 实测：ridge>=p75 的 pit 合计 6 → 48，降幅 −700% = −7.0
const MEASURED_M4 := 1.2145        # 实测：assert 集配对均值（基线 1.1194）

const T_M1 := -0.3                 # 只记录的参考线（§6.2 原目标；不参与退出码）
const T_M3_LO := 0.5               # 硬门禁：§6.2 的 Hack 指数区间
const T_M3_HI := 0.65

# 逐项门禁声明（计划 §2.3，取代原 P5_STRICT 全局开关）：item → hard / record
const GATE_HARD := "hard"
const GATE_RECORD := "record"
const GATES := {
	"M1": GATE_RECORD,      # 判据待计划 §5.1 修订（M1'），修订后转硬
	"M2": GATE_HARD,        # 判据有效，且是 P5 主收益
	"M2b": GATE_HARD,       # 硬，回归线 = 实测 × 1.2（只防更差；§4 会修工序）
	"M3": GATE_HARD,        # 判据有效
	"M4": GATE_HARD,        # 硬，回归线 = 实测 / 1.2
	"M5": GATE_RECORD,      # 判据待计划 §5.5 修订（M5a/M5b），修订后转硬
}

# 量纲：高度 0..1。LEVEL_* 只用于堆键排序，RANK_SCALE 只用于秩排序，都不参与指标数值。
const LEVEL_SCALE := 1073741824.0    # 2^30
const LEVEL_SHIFT := 1048576         # 2^20：下标占低 20 位（n <= 30000 < 2^20）
const INDEX_MASK := 1048575          # 2^20 − 1
const RANK_SCALE := 1099511627776.0  # 2^40

# D6 邻接：与 world_ext_generate_base.cpp 的 DQ/DR 逐字一致。
const DQ := [1, 1, 0, -1, -1, 0]
const DR := [0, -1, -1, 0, 1, 1]

# 2026-11-18 冻结基线的**全量种子均值**（来源：tmp/p5_calib/baseline/ 的冻结 .bin，
# 按**本文**的指标口径重算：M1 平均秩、M3 用 l_up、M4 用 l_down 无 +1 偏移）。
# 只在「找不到任何基线 JSON」时用于量级参照；与 assert 的 4+1 个种子不是同一集合。
# 对照：lead 的 metrics.py（序号秩 + l_down + L 的 +1 偏移）给出 M1 −0.232 / −0.297、M4 1.372 / 1.422。
const BASELINE_FALLBACK := {
	"60x40": {"seeds": 32, "M1": -0.2863, "M2_pits": 34.625,
		"M2_ridge_pits": 0.03125, "M3": 0.7665, "M4": 1.0837, "M5": 0.0, "M5_p90": 0.0},
	"200x150": {"seeds": 8, "M1": -0.3485, "M2_pits": 674.0,
		"M2_ridge_pits": 5.0, "M3": 0.5976, "M4": 1.1802, "M5": 0.0, "M5_p90": 0.0016},
}

var _checks := 0
var _failures := 0
var _skips := 0
# 只记录项（M1 / M5）的达成度计数：默认不影响退出码，见 _gate 与文件头「门禁分级」。
var _targets_hit := 0
var _targets_missed := 0
var _mode := "assert"
var _label := "run"
var _sea_level := SEA_FALLBACK
var _ext: Object = null
var _baseline: Dictionary = {}        # "seed|w|h" -> 基线行
var _baseline_src := ""
var _heap: PackedInt64Array = PackedInt64Array()
var _heap_n := 0


func _init() -> void:
	_mode = _resolve_mode()
	_label = _sanitize_label(OS.get_environment("P5_LABEL"))
	print("[ridge-metrics] mode=%s label=%s sea_level=%.4f godot=%s"
			% [_mode, _label, _sea_level, str(Engine.get_version_info().get("string", "?"))])
	match _mode:
		"capture":
			_run_capture()
		"baseline":
			_run_baseline()
		_:
			_run_assert()
	print("[ridge-metrics] checks=%d failures=%d skips=%d targets_hit=%d targets_missed=%d"
			% [_checks, _failures, _skips, _targets_hit, _targets_missed])
	quit(0 if _failures == 0 else 1)


func _resolve_mode() -> String:
	var m := OS.get_environment("P5_MODE").strip_edges().to_lower()
	if m == "":
		for arg in OS.get_cmdline_user_args():
			var a := str(arg).strip_edges().to_lower()
			if a == "capture" or a == "baseline" or a == "assert":
				m = a
				break
	if m == "capture" or m == "baseline":
		return m
	return "assert"


func _sanitize_label(raw: String) -> String:
	var s := raw.strip_edges()
	if s == "":
		return "run"
	s = s.replace("/", "_").replace("\\", "_").replace("..", "_").replace(":", "_")
	return s


# ═════════════════════════════════════════════════════════════════════════════
# assert 模式：4 种子 × 60×40 + 1 种子 × 200×150，按 §6.2 门禁
# ═════════════════════════════════════════════════════════════════════════════

func _run_assert() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect(false, "T3-0: DCWorldExt 可用（DLL 未编入？）")
		return
	_ext = ClassDB.instantiate("DCWorldExt")
	if _ext == null:
		_expect(false, "T3-0: DCWorldExt 可实例化")
		return
	_load_baseline()

	var rows: Array = []
	var maps: Array = []                 # 完整测量结果（含原始数组，供确定性比对；不落盘）
	var gen_ok := true
	for i in range(N_SMALL_ASSERT):
		var m := _measure(SEED_BASE + i, W_SMALL, H_SMALL)
		maps.append(m)
		rows.append(m["row"])
		gen_ok = gen_ok and bool(m["ok"])
	for i in range(N_LARGE_ASSERT):
		var m := _measure(SEED_BASE + i, W_LARGE, H_LARGE)
		maps.append(m)
		rows.append(m["row"])
		gen_ok = gen_ok and bool(m["ok"])
	_expect(gen_ok, "T3-1: base pass 原生成功（rc=0、无 fallback）")

	# 确定性：同 seed 再跑一次，逐位比对（§6.1 T3「同种子两次逐位一致」）
	var det_ok := true
	for dims in [Vector2i(W_SMALL, H_SMALL), Vector2i(W_LARGE, H_LARGE)]:
		var seed_v := SEED_BASE
		var cfg := _cfg(seed_v, dims.x, dims.y)
		var profile := _profile()
		var again: Dictionary = _ext.call("run_native_world_generate_base_pass", seed_v, cfg, profile)
		var first := {"elev": PackedFloat32Array(), "ridge": PackedFloat32Array()}
		for m in maps:
			var r: Dictionary = m["row"]
			if int(r.get("seed", -1)) == seed_v and int(r.get("w", -1)) == dims.x:
				first = m
		var ok_run := int(again.get("rc", -1)) == 0 and not bool(again.get("fallback", true))
		var a: PackedFloat32Array = again.get("elevation_arr", PackedFloat32Array())
		var b: PackedFloat32Array = first["elev"]
		var ra: PackedFloat32Array = again.get("ridge_add_arr", PackedFloat32Array())
		var rb: PackedFloat32Array = first["ridge"]
		var elev_same := a.size() > 0 and a.size() == b.size() and a == b
		var ridge_same := ra.size() == rb.size() and ra == rb
		print("[ridge-metrics/det] %dx%d elev_same=%s ridge_same=%s hash=%08x/%08x"
				% [dims.x, dims.y, elev_same, ridge_same, _hash32(a), _hash32(b)])
		det_ok = det_ok and ok_run and elev_same and ridge_same
	_expect(det_ok, "T3-2: 同 seed 两次 elevation_arr / ridge_add_arr 逐位一致")

	# 门禁声明提示（2026-11-18 更新，取代原 P5_STRICT 全局开关）：M1–M5 逐项声明 hard / record，
	# 见文件头「门禁分级」与 GATES 表。M2 / M2b / M3 / M4 是硬门禁（失败计退出码），
	# M1 / M5 只记录（判据待计划 §5 修订）。T3-1 / T3-2 是不变量，始终硬门禁。
	print("[ridge-metrics] 说明：逐项门禁 hard=%s record=%s（计划 §2.3）。"
			% [_items_with_gate(GATE_HARD), _items_with_gate(GATE_RECORD)])

	# M1 / M2(b) 前置：ridge_add_arr 必须存在（P5-0.1 的 opt-in 诊断）
	var ridge_ok := true
	for r in rows:
		ridge_ok = ridge_ok and bool(r.get("ridge_ok", false))
	if not ridge_ok:
		_skip("M1", "ridge_add_arr 缺失（DLL 未含 P5-0.1 诊断输出？profile.ridge_debug_dump=1 未生效）")
		_skip("M2b", "ridge_add_arr 缺失，p75 口径无从计算")
	else:
		_check_m1(rows)
		_check_m2(rows)
	_check_m3(rows)
	_check_m4(rows)
	_check_m5(rows)
	_print_table(rows)


func _check_m1(rows: Array) -> void:
	var acc := 0.0
	var n := 0
	var line := ""
	for r in rows:
		var v = r.get("M1", null)
		if v == null:
			line += "%d×%d=n/a " % [int(r["seed"]), int(r["w"])]
			continue
		acc += float(v)
		n += 1
		line += "%d×%d=%.4f " % [int(r["seed"]), int(r["w"]), float(v)]
	if n == 0:
		_skip("M1", "所有种子 M1 样本 < %d（ridge_add>0 且 A>=1 的陆地格不足）" % MIN_SAMPLE)
		return
	var mean := acc / float(n)
	var thr := _env_float("P5_T_M1", T_M1)
	var pair := _paired_mean(rows, "M1")
	var delta := "Δ=n/a"
	if int(pair[2]) > 0:
		delta = "Δ=%+.4f(基线 %.4f, 配对图 %d)" % [float(pair[0]) - float(pair[1]),
				float(pair[1]), int(pair[2])]
	print("[ridge-metrics/M1] per-seed %smean=%.4f n=%d thr<=%.3f %s"
			% [line, mean, n, thr, delta])
	# M1 只记录（计划 §2.3）：thr 只是 §6.2 原目标的参考线，不影响退出码。
	_gate("M1", mean <= thr, "M1: 陆地 Spearman(ridge_add, log10 A) 均值 %.4f <= %.3f" % [mean, thr])


func _check_m2(rows: Array) -> void:
	var pit_new := 0
	var rid_new := 0
	for r in rows:
		pit_new += int(r.get("M2_pits", 0))
		rid_new += int(r.get("M2_ridge_pits", 0))
	var pair_pit := _paired_sum(rows, "M2_pits")
	var pair_rid := _paired_sum(rows, "M2_ridge_pits")
	# M2 硬门禁（计划 §2.3）：闭合洼地总数不得超过 2026-11-18 实测 × 1.2 的回归线。
	# 方向：越少越好 ⇒ 只设上限；基线只用于打印对照（无基线也能判，少一个 SKIP）。
	var m2_limit := MEASURED_M2_PITS * GATE_SLACK
	print("[ridge-metrics/M2a] 陆地 pit 格数 新=%d 基线=%s 配对图=%d 回归线<=%.0f（M2 硬门禁）"
			% [pit_new, _fmt_sum(float(pair_pit[1])), int(pair_pit[2]), m2_limit])
	_gate("M2", float(pit_new) <= m2_limit,
			"M2: 闭合洼地总数 %d <= %.0f（2026-11-18 实测 %.0f × %.1f 回归线）"
			% [pit_new, m2_limit, MEASURED_M2_PITS, GATE_SLACK])
	if int(pair_rid[2]) == 0:
		_skip("M2b", "无基线行可对齐（先跑 P5_MODE=baseline，或用 P5_BASELINE 指定 JSON）")
		return
	var rid_base := float(pair_rid[1])
	var rid_paired := int(round(float(pair_rid[0])))
	if rid_base <= 0.0:
		_skip("M2b", "基线 ridge 高分位 pit 合计=0，「较基线降幅」无定义；新值=%d" % rid_new)
		return
	var drop := (rid_base - float(rid_paired)) / rid_base
	# M2b 硬门禁（计划 §2.3）：降幅不得低于「2026-11-18 实测降幅 × 1.2」。
	# drop 为负 = 相比基线恶化（实测 −700%）；取绝对值放宽 1.2 倍 ⇒ 回归线 −840%，
	# 即 new <= 基线 × (1 + 8.4) 才过；再差就 FAIL。
	var drop_limit := MEASURED_M2B_DROP * GATE_SLACK
	print("[ridge-metrics/M2b] ridge>=p75 的 pit 合计 基线=%.2f 新=%d（同图集合计；全图集新值=%d）降幅=%.1f%% 回归线>=%.0f%% 来源=%s"
			% [rid_base, rid_paired, rid_new, drop * 100.0, drop_limit * 100.0, _baseline_src])
	_gate("M2b", drop >= drop_limit,
			"M2b: ridge>=p75 的 pit 格数较基线降 %.1f%% >= %.0f%%（2026-11-18 实测 %.0f%% × %.1f）"
			% [drop * 100.0, drop_limit * 100.0, MEASURED_M2B_DROP * 100.0, GATE_SLACK])


func _check_m3(rows: Array) -> void:
	var lo := _env_float("P5_T_M3_LO", T_M3_LO)
	var hi := _env_float("P5_T_M3_HI", T_M3_HI)
	var judged := 0
	var bad := ""
	var line := ""
	for r in rows:
		var v = r.get("M3", null)
		var n := int(r.get("M3_points", 0))
		if v == null or n < M3_JUDGE_MIN_POINTS:
			line += "%d×%d=参考(n=%d) " % [int(r["seed"]), int(r["w"]), n]
			continue
		judged += 1
		line += "%d×%d=%.4f(n=%d) " % [int(r["seed"]), int(r["w"]), float(v), n]
		if float(v) < lo or float(v) > hi:
			bad += "%d×%d=%.4f " % [int(r["seed"]), int(r["w"]), float(v)]
	print("[ridge-metrics/M3] 口径=斜率 log10(l_up)~log10(A)（文件头裁决 1）%s" % line)
	print("[ridge-metrics/M3] M3_down（§C 字面 l_down 口径，仅诊断）%s" % _fmt_list(rows, "M3_down"))
	if judged == 0:
		_skip("M3", "没有 M3_points>=%d 的图（60×40 上 A>=%.0f 的样本只有 3–13 个，斜率标准误 ±0.1~0.4，不构成判定）"
				% [M3_JUDGE_MIN_POINTS, STEM_MIN_AREA])
		return
	_gate("M3", bad == "", "M3: Hack 指数 ∈ [%.2f, %.2f]（越界: %s）" % [lo, hi, bad])


func _check_m4(rows: Array) -> void:
	var new_mean := _rows_mean(rows, "M4")
	if is_nan(new_mean):
		_skip("M4", "所有种子 M4 样本 < %d" % MIN_SAMPLE)
		return
	var pair := _paired_mean(rows, "M4")
	# M4 硬门禁（计划 §2.3）：不得低于「2026-11-18 实测 / 1.2」的回归线。
	# 方向：流路直线度**越高越好** ⇒ 1.2 倍放宽要向下用（实测 1.2145 ⇒ 回归线 1.0121）；
	# 基线均值只用于打印 Δ，不再作为判定依据（无基线也能判，少一个 SKIP）。
	var m4_limit := MEASURED_M4 / GATE_SLACK
	if int(pair[2]) > 0:
		print("[ridge-metrics/M4] 流路直线度 基线=%.4f 新=%.4f Δ=%+.4f 配对图=%d 回归线>=%.4f 来源=%s"
				% [float(pair[1]), float(pair[0]), float(pair[0]) - float(pair[1]),
				int(pair[2]), m4_limit, _baseline_src])
	else:
		print("[ridge-metrics/M4] 流路直线度 新均值=%.4f（无基线可比，按绝对回归线判定）回归线>=%.4f"
				% [new_mean, m4_limit])
	_gate("M4", new_mean >= m4_limit,
			"M4: 流路直线度均值 %.4f >= %.4f（2026-11-18 实测 %.4f / %.1f）"
			% [new_mean, m4_limit, MEASURED_M4, GATE_SLACK])


func _check_m5(rows: Array) -> void:
	var cand := 0
	var aux := 0.0
	var aux_n := 0
	var hmax := 0.0
	for r in rows:
		cand += int(r.get("M5_cand", 0))
		hmax = maxf(hmax, float(r.get("land_h_max", 0.0)))
		var v = r.get("M5_p90", null)
		if v != null:
			aux += float(v)
			aux_n += 1
	if aux_n > 0:
		aux = aux / float(aux_n)
	print("[ridge-metrics/M5] 字面候选格(land_h>%.2f)=%d land_h_max=%.4f；AUX M5_p90=%.4f（非契约，不作门禁）"
			% [M5_MIN_LAND_H, cand, hmax, aux])
	if cand == 0:
		_skip("M5", "字面阈值 land_h>%.2f 在现有高度预算下恒为空集（land_h_max=%.4f）→ 无从判定；见文件头裁决 3"
				% [M5_MIN_LAND_H, hmax])
		return
	var new_mean := _rows_mean(rows, "M5")
	var pair := _paired_mean(rows, "M5")
	if is_nan(new_mean) or int(pair[2]) == 0:
		_skip("M5", "无基线平顶率可对齐")
		return
	var base_mean := float(pair[1])
	print("[ridge-metrics/M5] 平顶率 基线=%.4f 新=%.4f Δ=%+.4f 配对图=%d"
			% [base_mean, float(pair[0]), float(pair[0]) - base_mean, int(pair[2])])
	# M5 只记录（计划 §2.3）：判据待 §5.5 换成 M5a/M5b 后再转硬门禁。
	_gate("M5", float(pair[0]) < base_mean - 1.0e-9, "M5: 平顶率较基线下降（%.4f < %.4f）"
			% [float(pair[0]), base_mean])


func _print_table(rows: Array) -> void:
	for r in rows:
		print("[ridge-metrics/row] %d %dx%d M1=%s M2=(%d,%d) M3=%s M3_down=%s M4=%s M5=%s M5_p90=%s land=%d base_ms=%.2f"
				% [int(r["seed"]), int(r["w"]), int(r["h"]),
				_fmt_v(r.get("M1", null)), int(r.get("M2_pits", -1)),
				int(r.get("M2_ridge_pits", -1)), _fmt_v(r.get("M3", null)),
				_fmt_v(r.get("M3_down", null)), _fmt_v(r.get("M4", null)),
				_fmt_v(r.get("M5", null)), _fmt_v(r.get("M5_p90", null)),
				int(r.get("land_cells", -1)), float(r.get("base_ms", -1.0))])


# ═════════════════════════════════════════════════════════════════════════════
# capture 模式：contracts §D-1 全量集合，只落盘不判定
# ═════════════════════════════════════════════════════════════════════════════

func _run_capture() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[ridge-metrics] DCWorldExt 不可用：capture 中止")
		_failures += 1
		return
	_ext = ClassDB.instantiate("DCWorldExt")
	var dir := "%s/%s" % [OUT_ROOT, _label]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var t_all := Time.get_ticks_msec()
	var rows: Array = []
	var index_rows: Array = []
	for i in range(N_SMALL_CAPTURE):
		var m := _measure(SEED_BASE + i, W_SMALL, H_SMALL)
		rows.append(m["row"])
		index_rows.append(_index_row(m))
		_write_bins(dir, SEED_BASE + i, W_SMALL, H_SMALL, m)
	for i in range(N_LARGE_CAPTURE):
		var m := _measure(SEED_BASE + i, W_LARGE, H_LARGE)
		rows.append(m["row"])
		index_rows.append(_index_row(m))
		_write_bins(dir, SEED_BASE + i, W_LARGE, H_LARGE, m)
	var meta := {
		"label": _label,
		"mode": "capture",
		"captured_utc": Time.get_datetime_string_from_system(true),
		"godot": str(Engine.get_version_info().get("string", "?")),
		"metric_version": "p5-m1m5-gd-1",
		"sea_level": _sea_level,
		"cfg": _cfg(SEED_BASE, W_SMALL, H_SMALL),
		"profile": _profile(),
		"seeds_60x40": _seeds(N_SMALL_CAPTURE),
		"seeds_200x150": _seeds(N_LARGE_CAPTURE),
		"m3_definition": "regress log10(l_up) ~ log10(area), land & area>=100 & l_up>0",
		"m3_down_definition": "regress log10(l_down) ~ log10(area)：§C 字面口径，仅诊断",
		"m5_definition": "land & land_h>0.6 & (max-min of self+6nb) < 0.02：现状恒空集，见文件头裁决 3",
		"nan_encoding": "JSON null",
		"notes": [
			"index.json 的行与 tmp/p5_calib/metrics.py 的期望同构：可直接 python tmp/p5_calib/metrics.py <label>",
			"M3 用 l_up（上游最长路径），M3_down 是 §C 字面 l_down 口径，两者都落盘",
			"M5_p90 是非契约辅助量（land_h >= p90 的格里局地起伏 < 0.02 的比例）",
		],
	}
	var out := {
		"meta": meta,
		"rows": rows,
		"aggregate": {
			"60x40": _aggregate(rows, W_SMALL),
			"200x150": _aggregate(rows, W_LARGE),
		},
	}
	_write_text(dir + "/metrics.json", JSON.stringify(out, "  ", true, false))
	_write_text(dir + "/index.json",
			JSON.stringify({"meta": meta, "rows": index_rows}, "  ", true, false))
	print("[ridge-metrics/capture] rows=%d wall=%dms -> %s/metrics.json"
			% [rows.size(), Time.get_ticks_msec() - t_all, dir])
	print("[ridge-metrics/capture] aggregate 60x40=%s"
			% JSON.stringify(out["aggregate"]["60x40"], "", true, false))
	print("[ridge-metrics/capture] aggregate 200x150=%s"
			% JSON.stringify(out["aggregate"]["200x150"], "", true, false))


# index.json 的行只用 metrics.py 认得的键（它按 seed/w/h/ok/... 读）外加少量诊断。
func _index_row(m: Dictionary) -> Dictionary:
	var r: Dictionary = m["row"]
	return {
		"seed": int(r.get("seed", 0)), "w": int(r.get("w", 0)), "h": int(r.get("h", 0)),
		"ok": bool(m["ok"]),
		"base_ms": float(r.get("base_ms", -1.0)),
		"water_count": int(r.get("water_count", -1)),
		"land_count": int(r.get("land_count", -1)),
		"lake_count": int(r.get("lake_count", -1)),
		"river_count": int(r.get("river_count", -1)),
		"highland_river_count": int(r.get("highland_river_count", -1)),
		"stage_counts": r.get("stage_counts", {}),
	}


func _write_bins(dir: String, seed_v: int, w: int, h: int, m: Dictionary) -> void:
	var tag := "seed_%d_%dx%d" % [seed_v, w, h]
	var elev: PackedFloat32Array = m["elev"]
	var ridge: PackedFloat32Array = m["ridge"]
	var terr: PackedByteArray = m["terr"]
	var lf: PackedByteArray = m["lf"]
	_write_bytes("%s/%s_elev.bin" % [dir, tag], elev.to_byte_array())
	if ridge.size() == elev.size() and ridge.size() > 0:
		_write_bytes("%s/%s_ridge.bin" % [dir, tag], ridge.to_byte_array())
	else:
		# 不写 0 字节的 ridge.bin：metrics.py 会把它当空数组读出而不是报缺失，容易误判。
		print("[ridge-metrics] WARN %s: ridge_add_arr 缺失，跳过 ridge.bin（M1/M2b 将 SKIP）" % tag)
	_write_bytes("%s/%s_terr.bin" % [dir, tag], terr)
	_write_bytes("%s/%s_land.bin" % [dir, tag], lf)


# ═════════════════════════════════════════════════════════════════════════════
# baseline 模式：读冻结数组，用同一份指标实现重算（不碰 DLL）
# ═════════════════════════════════════════════════════════════════════════════

func _run_baseline() -> void:
	var index_path := BASELINE_DIR + "/index.json"
	if not FileAccess.file_exists(ProjectSettings.globalize_path(index_path)):
		push_error("[ridge-metrics] 缺 %s：先跑 tests/world/_p5_freeze_baseline.gd" % index_path)
		_failures += 1
		return
	var parsed = JSON.parse_string(_read_text(index_path))
	if not (parsed is Dictionary):
		push_error("[ridge-metrics] %s 解析失败" % index_path)
		_failures += 1
		return
	var src_rows: Array = (parsed as Dictionary).get("rows", [])
	var rows: Array = []
	for g in src_rows:
		if not (g is Dictionary):
			continue
		if not bool((g as Dictionary).get("ok", false)):
			continue
		var seed_v := int(g.get("seed", 0))
		var w := int(g.get("w", 0))
		var h := int(g.get("h", 0))
		var tag := "seed_%d_%dx%d" % [seed_v, w, h]
		var elev := _read_f32("%s/%s_elev.bin" % [BASELINE_DIR, tag], w * h)
		if elev.size() != w * h:
			print("[ridge-metrics/baseline] 缺数组 %s_elev.bin，跳过" % tag)
			continue
		var ridge := _read_f32("%s/%s_ridge.bin" % [BASELINE_DIR, tag], w * h)
		var terr := _read_u8("%s/%s_terr.bin" % [BASELINE_DIR, tag])
		var lf := _read_u8("%s/%s_land.bin" % [BASELINE_DIR, tag])
		var row := _metrics(elev, ridge, w, h, 0.0, terr, lf)
		row["seed"] = seed_v
		row["w"] = w
		row["h"] = h
		row["ok"] = true
		row["ridge_ok"] = ridge.size() == w * h
		row["lake_count"] = int(g.get("lake_count", -1))
		row["river_count"] = int(g.get("river_count", -1))
		row["highland_river_count"] = int(g.get("highland_river_count", -1))
		row["base_ms"] = float(g.get("base_ms", -1.0))
		row["stage_counts"] = g.get("stage_counts", {})
		rows.append(row)
		print("[ridge-metrics/baseline] %d %dx%d M1=%s M2=(%d,%d) M3=%s M3_down=%s M4=%s M5_p90=%s"
				% [seed_v, w, h, _fmt_v(row.get("M1", null)), int(row["M2_pits"]),
				int(row["M2_ridge_pits"]), _fmt_v(row.get("M3", null)),
				_fmt_v(row.get("M3_down", null)), _fmt_v(row.get("M4", null)),
				_fmt_v(row.get("M5_p90", null))])
	var out := {
		"meta": {
			"label": "baseline",
			"mode": "baseline",
			"source": BASELINE_DIR,
			"computed_utc": Time.get_datetime_string_from_system(true),
			"metric_version": "p5-m1m5-gd-1",
			"sea_level": _sea_level,
			"m3_definition": "regress log10(l_up) ~ log10(area), land & area>=100 & l_up>0",
			"nan_encoding": "JSON null",
		},
		"rows": rows,
		"aggregate": {
			"60x40": _aggregate(rows, W_SMALL),
			"200x150": _aggregate(rows, W_LARGE),
		},
	}
	var dest := BASELINE_DIR + "/metrics_gd.json"
	_write_text(dest, JSON.stringify(out, "  ", true, false))
	print("[ridge-metrics/baseline] rows=%d -> %s" % [rows.size(), dest])
	print("[ridge-metrics/baseline] aggregate 60x40=%s"
			% JSON.stringify(out["aggregate"]["60x40"], "", true, false))
	print("[ridge-metrics/baseline] aggregate 200x150=%s"
			% JSON.stringify(out["aggregate"]["200x150"], "", true, false))
	_cross_check(rows)


# 与 lead 的 python 版逐项对照（同名字段直接比；口径不同的字段单独标注）。
func _cross_check(rows: Array) -> void:
	var py_path := BASELINE_DIR + "/metrics_py.json"
	if not FileAccess.file_exists(ProjectSettings.globalize_path(py_path)):
		print("[ridge-metrics/xcheck] 无 %s，跳过交叉校验" % py_path)
		return
	var parsed = JSON.parse_string(_read_text(py_path))
	if not (parsed is Dictionary):
		print("[ridge-metrics/xcheck] %s 解析失败，跳过" % py_path)
		return
	var py_rows: Array = (parsed as Dictionary).get("rows", [])
	var py_by_key := {}
	for p in py_rows:
		if p is Dictionary:
			py_by_key["%d|%d|%d" % [int(p.get("seed", 0)), int(p.get("w", 0)),
					int(p.get("h", 0))]] = p
	var worst_m1 := 0.0
	var worst_pits := 0
	var worst_ridge_pits := 0
	var worst_m4 := 0.0
	var worst_m3 := 0.0
	var matched := 0
	for r in rows:
		var key := "%d|%d|%d" % [int(r["seed"]), int(r["w"]), int(r["h"])]
		if not py_by_key.has(key):
			continue
		matched += 1
		var p: Dictionary = py_by_key[key]
		if r.get("M1", null) != null and p.get("M1", null) != null:
			worst_m1 = maxf(worst_m1, absf(float(r["M1"]) - float(p["M1"])))
		if r.get("M2_pits", null) != null and p.get("M2_pits", null) != null:
			worst_pits = maxi(worst_pits, absi(int(r["M2_pits"]) - int(p["M2_pits"])))
		if r.get("M2_ridge_pits", null) != null and p.get("M2_ridge_pits", null) != null:
			worst_ridge_pits = maxi(worst_ridge_pits,
					absi(int(r["M2_ridge_pits"]) - int(p["M2_ridge_pits"])))
		if r.get("M4", null) != null and p.get("M4", null) != null:
			worst_m4 = maxf(worst_m4, absf(float(r["M4"]) - float(p["M4"])))
		if r.get("M3_down", null) != null and p.get("M3", null) != null:
			worst_m3 = maxf(worst_m3, absf(float(r["M3_down"]) - float(p["M3"])))
	print("[ridge-metrics/xcheck] matched_rows=%d max|Δ| M1=%.2e M2_pits=%d M2_ridge_pits=%d"
			% [matched, worst_m1, worst_pits, worst_ridge_pits])
	print("[ridge-metrics/xcheck] 已知口径差（非错误）：M3_down vs py.M3 max|Δ|=%.4f（py 用 l_down 且有 +1 偏移）、M4 max|Δ|=%.4f"
			% [worst_m3, worst_m4])


# ═════════════════════════════════════════════════════════════════════════════
# 生成 + 单行测量（三种模式的公共入口）
# ═════════════════════════════════════════════════════════════════════════════

# 返回 {"row": 指标行（JSON 安全）, "ok": bool, "elev"/"ridge"/"terr"/"lf": 原始数组}
func _measure(seed_v: int, w: int, h: int) -> Dictionary:
	var cfg := _cfg(seed_v, w, h)
	var profile := _profile()
	var t0 := Time.get_ticks_usec()
	var base: Dictionary = _ext.call("run_native_world_generate_base_pass", seed_v, cfg, profile)
	var base_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	var ok := int(base.get("rc", -1)) == 0 and not bool(base.get("fallback", true))
	if not ok:
		print("[ridge-metrics] base FAIL seed=%d %dx%d reason=%s"
				% [seed_v, w, h, str(base.get("reason", "?"))])
		var bad := _metrics(PackedFloat32Array(), PackedFloat32Array(), w, h, base_ms,
				PackedByteArray(), PackedByteArray())
		bad["seed"] = seed_v
		bad["w"] = w
		bad["h"] = h
		bad["ok"] = false
		bad["ridge_ok"] = false
		return {"row": bad, "ok": false, "elev": PackedFloat32Array(),
			"ridge": PackedFloat32Array(), "terr": PackedByteArray(), "lf": PackedByteArray()}
	var elev: PackedFloat32Array = base.get("elevation_arr", PackedFloat32Array())
	var ridge: PackedFloat32Array = base.get("ridge_add_arr", PackedFloat32Array())
	var terr: PackedByteArray = base.get("terrain_arr", PackedByteArray())
	var lf: PackedByteArray = base.get("landform_arr", PackedByteArray())
	var ridge_ok := ridge.size() == w * h
	if not ridge_ok:
		ridge = PackedFloat32Array()
	var t1 := Time.get_ticks_usec()
	var row := _metrics(elev, ridge, w, h, base_ms, terr, lf)
	var metrics_ms := float(Time.get_ticks_usec() - t1) / 1000.0
	var post: Dictionary = _ext.call("run_native_world_generate_post_base_pass",
			seed_v, cfg, profile, base)
	row["seed"] = seed_v
	row["w"] = w
	row["h"] = h
	row["ok"] = elev.size() == w * h
	row["ridge_ok"] = ridge_ok
	row["base_ms"] = base_ms
	row["base_reported_ms"] = float(base.get("elapsed_ms", -1.0))
	row["metrics_ms"] = metrics_ms
	row["post_fallback"] = bool(post.get("fallback", true))
	row["lake_count"] = int(post.get("lake_count", -1))
	row["river_count"] = int(post.get("river_count", -1))
	row["highland_river_count"] = int(post.get("highland_river_count", -1))
	row["stage_counts"] = post.get("stage_counts", {})
	row["water_count"] = int(base.get("water_count", -1))
	row["land_count"] = int(base.get("land_count", -1))
	print("[ridge-metrics/gen] seed=%d %dx%d base=%.2fms metrics=%.2fms M1=%s M2=(%d,%d) M3=%s M4=%s land=%d"
			% [seed_v, w, h, base_ms, metrics_ms, _fmt_v(row.get("M1", null)),
			int(row.get("M2_pits", -1)), int(row.get("M2_ridge_pits", -1)),
			_fmt_v(row.get("M3", null)), _fmt_v(row.get("M4", null)),
			int(row.get("land_cells", -1))])
	return {"row": row, "ok": bool(row["ok"]),
		"elev": elev, "ridge": ridge, "terr": terr, "lf": lf}


func _cfg(seed_v: int, w: int, h: int) -> Dictionary:
	# contracts §D-1：与 _p5_freeze_baseline.gd 的 _cfg() 逐字一致（宽度/高度/种子按行填）。
	return {
		"num_continents": 3,
		"continent_size": 0.9,
		"sea_level": SEA_FALLBACK,
		"river_count": 12,
		"width": w,
		"height": h,
		"seed": seed_v,
	}


# contracts §D-1「代表性 profile」：与 _p5_freeze_baseline.gd 的 _profile() 逐字一致。
# 保留即将删除的 erosion_* 键 —— C++ 忽略未知键，但「与基线同一份 profile」优先；
# ridge_debug_dump=1 是本测试 M1/M2(b) 的前置（P5-0.1 的 opt-in 诊断输出）。
func _profile() -> Dictionary:
	return {
		"native_generation_mode": 2,
		"ridge_boost_amp": 0.60,
		"spl_iters": 14,
		"spl_erodibility": 1.2,
		"spl_area_exp": 0.45,
		# [P5 标定 2026-11-18] spl_uplift_rate 0.10 -> 0.08：新增的脊抬升叠加在原有 relief0 抬升项上
		# 会整体抬高陆地高度，这一步把它拉回基线分布（见 checklist §B-1）。三个新键显式列出，
		# 使本测试不依赖 C++ 缺省值（缺省与这里同值，但显式写出来才能自证「测的是哪个配置」）。
		"spl_uplift_rate": 0.08,
		"spl_ridge_uplift": 0.03,
		"spl_hillslope_diffusion": 0.08,
		"ridge_residual_frac": 0.15,
		"ridge_debug_dump": 1,
	}


func _seeds(count: int) -> Array:
	var out: Array = []
	for i in range(count):
		out.append(SEED_BASE + i)
	return out


# ═════════════════════════════════════════════════════════════════════════════
# 指标引擎（capture / baseline / assert 三种模式共用这一份，绝不写第二份）
# ═════════════════════════════════════════════════════════════════════════════

# 返回契约 §C 的 M1–M5 + 分布统计。ridge 为空表示诊断数组缺失（M1/M2b 落 null）。
func _metrics(elev: PackedFloat32Array, ridge: PackedFloat32Array,
		w: int, h: int, base_ms: float, terr: PackedByteArray, lf: PackedByteArray) -> Dictionary:
	var n := w * h
	var out := {
		"M1": null, "M1_points": 0, "M2_pits": -1, "M2_ridge_pits": -1,
		"M3": null, "M3_down": null, "M3_points": 0, "M4": null, "M4_points": 0,
		"M5": null, "M5_cand": 0, "M5_p90": null, "M5_p90_cand": 0, "land_h_max": 0.0,
		"land_cells": 0, "water_cells": 0, "land_p50": null, "land_p90": null, "land_p99": null,
		"ridge_cells_positive": 0, "land_pits_filled": 0,
		"terrain_hist": {}, "landform_hist": {}, "n_cells": n, "base_ms": base_ms,
		"pf_ms": 0.0, "build_ms": 0.0,
	}
	if elev.size() != n:
		return out
	var t0 := Time.get_ticks_usec()
	var sea := _sea_level
	# 邻接表：一次构建，PF / 受体 / M5 共用（6n 个 int32；30k 格 = 720KB）。
	var nbr := _neighbor_table(w, h)
	# 1) Priority-Flood 填洼面 + 出栈序 proc
	var filled := elev.duplicate()
	var proc := _priority_flood(filled, nbr, w, h)
	# 2) 最陡下降受体（严格更低、平局取 d 小者、无则 −1）
	var rcv := PackedInt32Array()
	rcv.resize(n)
	rcv.fill(-1)
	for i in range(n):
		var base_i := i * 6
		var li := float(filled[i])
		var best := 0.0
		var best_i := -1
		for d in range(6):
			var ni := nbr[base_i + d]
			if ni < 0:
				continue
			var dz := li - float(filled[ni])
			if dz > best:
				best = dz
				best_i = ni
		rcv[i] = best_i
	# 3) A（逆 proc：上游先）、l_down/outlet（正 proc：父先于子）、l_up（逆 proc 取最长上游路径）
	var area := PackedFloat64Array()
	area.resize(n)
	area.fill(1.0)
	var l_down := PackedFloat64Array()
	l_down.resize(n)
	var outlet := PackedInt32Array()
	outlet.resize(n)
	var l_up := PackedFloat64Array()
	l_up.resize(n)
	for k in range(proc.size() - 1, -1, -1):
		var i := proc[k]
		var d := rcv[i]
		if d >= 0:
			area[d] = area[d] + area[i]
	for k in range(proc.size()):
		var i := proc[k]
		var d := rcv[i]
		if d < 0:
			l_down[i] = 0.0
			outlet[i] = i
		else:
			l_down[i] = l_down[d] + 1.0
			outlet[i] = outlet[d]
	for k in range(proc.size() - 1, -1, -1):
		var i := proc[k]
		var d := rcv[i]
		if d >= 0:
			var v := l_up[i] + 1.0
			if v > l_up[d]:
				l_up[d] = v
	# 出口格自身 L=0 / outlet=self（与 metrics.py 收尾段同义）
	for i in range(n):
		if rcv[i] < 0:
			l_down[i] = 0.0
			outlet[i] = i
	var build_ms := float(Time.get_ticks_usec() - t0) / 1000.0

	# 4) 陆地掩码 + land_h 分布
	var land_h_values := PackedFloat32Array()
	var land_cells := 0
	var water_cells := 0
	var land_h_max := 0.0
	for i in range(n):
		if float(elev[i]) >= sea:
			land_cells += 1
			var hh := float(elev[i]) - sea
			land_h_values.append(hh)
			land_h_max = maxf(land_h_max, hh)
		else:
			water_cells += 1
	out["land_cells"] = land_cells
	out["water_cells"] = water_cells
	out["land_h_max"] = land_h_max
	land_h_values.sort()
	out["land_p50"] = _num(_percentile(land_h_values, 0.50))
	out["land_p90"] = _num(_percentile(land_h_values, 0.90))
	out["land_p99"] = _num(_percentile(land_h_values, 0.99))
	var p90_land_h := _percentile(land_h_values, 0.90)

	# 5) M2(a)：陆地 pit 格（填洼面 > 原面 + 1e−6）；M2(b) 再要求 ridge ≥ 陆地 p75
	var pit := PackedByteArray()
	pit.resize(n)
	var m2_pits := 0
	for i in range(n):
		if float(elev[i]) >= sea and float(filled[i]) > float(elev[i]) + PIT_EPS:
			pit[i] = 1
			m2_pits += 1
	out["M2_pits"] = m2_pits
	out["land_pits_filled"] = m2_pits
	if ridge.size() == n:
		var land_ridge := PackedFloat32Array()
		for i in range(n):
			if float(elev[i]) >= sea:
				land_ridge.append(ridge[i])
		land_ridge.sort()
		if land_ridge.size() >= MIN_SAMPLE:
			var p75 := _percentile(land_ridge, 0.75)
			var m2_ridge := 0
			for i in range(n):
				if pit[i] != 0 and float(ridge[i]) >= p75:
					m2_ridge += 1
			out["M2_ridge_pits"] = m2_ridge
			out["ridge_p75"] = _num(p75)
		# 6) M1：陆地 Spearman(ridge_add, log10 A)，条件 ridge_add > 0 且 A >= 1
		var rx_values := PackedFloat64Array()
		var ry_values := PackedFloat64Array()
		var pos_cells := 0
		for i in range(n):
			if float(elev[i]) >= sea and float(ridge[i]) > 0.0 and area[i] >= 1.0:
				rx_values.append(float(ridge[i]))
				ry_values.append(log(area[i]) / log(10.0))
				pos_cells += 1
		out["ridge_cells_positive"] = pos_cells
		out["M1_points"] = pos_cells
		if pos_cells >= MIN_SAMPLE:
			out["M1"] = _num(_spearman(rx_values, ry_values))

	# 7) M3 / M4：陆地 & A >= 100
	#    注意 M3(l_up) 与 M4(l_down) 的样本集**不同**（A>=100 的洼地格 l_down=0 但 l_up>0），
	#    两条回归各带自己的 x 数组 —— 共用同一个 xs 会因长度不一致静默退化成 NaN。
	var xs_up := PackedFloat64Array()    # log10(A)，配 l_up
	var ys_up := PackedFloat64Array()    # log10(l_up)
	var xs_down := PackedFloat64Array()  # log10(A)，配 l_down
	var ys_down := PackedFloat64Array()  # log10(l_down)
	var ratio_sum := 0.0
	var ratio_n := 0
	for i in range(n):
		if float(elev[i]) < sea or area[i] < STEM_MIN_AREA:
			continue
		var la := log(area[i]) / log(10.0)
		if l_up[i] > 0.0:
			xs_up.append(la)
			ys_up.append(log(l_up[i]) / log(10.0))
		if l_down[i] > 0.0:
			xs_down.append(la)
			ys_down.append(log(l_down[i]) / log(10.0))
			var row_i := i / w
			var col_i := i % w
			var o := outlet[i]
			var row_o := o / w
			var col_o := o % w
			var dcol := absi(col_i - col_o)
			dcol = mini(dcol, w - dcol)          # 经度最短环绕
			var drow := row_i - row_o
			var dist := sqrt(float(dcol * dcol) + float(drow * drow))
			if dist > 1.0e-9:
				ratio_sum += l_down[i] / dist
				ratio_n += 1
	out["M3_points"] = xs_up.size()
	out["M4_points"] = ratio_n
	if xs_up.size() >= MIN_SAMPLE:
		out["M3"] = _num(_regress_slope(xs_up, ys_up))
	if xs_down.size() >= MIN_SAMPLE:
		out["M3_down"] = _num(_regress_slope(xs_down, ys_down))
	if ratio_n >= MIN_SAMPLE:
		out["M4"] = _num(ratio_sum / float(ratio_n))

	# 8) M5 字面口径（现状恒空集）+ M5_p90 辅助口径
	var m5_total := 0
	var m5_flat := 0
	var p90_total := 0
	var p90_flat := 0
	for i in range(n):
		if float(elev[i]) < sea:
			continue
		var land_h := float(elev[i]) - sea
		var need_p90 := land_h >= p90_land_h
		var need_literal := land_h > M5_MIN_LAND_H
		if not need_p90 and not need_literal:
			continue
		var lo := float(elev[i])
		var hi := lo
		var base_i := i * 6
		for d in range(6):
			var ni := nbr[base_i + d]
			if ni < 0:
				continue
			var v := float(elev[ni])
			lo = minf(lo, v)
			hi = maxf(hi, v)
		var flat := (hi - lo) < PLATEAU_RELIEF
		if need_literal:
			m5_total += 1
			if flat:
				m5_flat += 1
		if need_p90:
			p90_total += 1
			if flat:
				p90_flat += 1
	out["M5_cand"] = m5_total
	out["M5"] = _num(float(m5_flat) / float(m5_total) if m5_total > 0 else 0.0)
	out["M5_p90"] = _num(float(p90_flat) / float(p90_total) if p90_total > 0 else 0.0)
	out["M5_p90_cand"] = p90_total

	# 9) 分布统计（terrain / landform 直方图；只输出非零桶，键按下标升序 ⇒ 确定性）
	out["terrain_hist"] = _histogram(terr)
	out["landform_hist"] = _histogram(lf)
	out["pf_ms"] = float(Time.get_ticks_usec() - t0) / 1000.0
	out["build_ms"] = build_ms
	return out


# D6 邻接表：nbr[i*6+d] = 邻居下标（−1 = 无）。与 index_for_qr 逐字一致。
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


# Barnes Priority-Flood（2014）：种子 = 南北两行；不填 ε；平局按 idx 定序。
# filled 原地填洼，返回出栈序 proc（下游先）。
func _priority_flood(filled: PackedFloat32Array, nbr: PackedInt32Array,
		w: int, h: int) -> PackedInt32Array:
	var n := w * h
	var seen := PackedByteArray()
	seen.resize(n)
	var proc := PackedInt32Array()
	proc.resize(n)
	var cnt := 0
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
			_heap_push(_pack(_level_scaled(filled[i]), i))
	while _heap_n > 0:
		var key := _heap_pop()
		var cur := key & INDEX_MASK
		proc[cnt] = cur
		cnt += 1
		var fc := float(filled[cur])
		var base_i := cur * 6
		for d in range(6):
			var ni := nbr[base_i + d]
			if ni < 0 or seen[ni] != 0:
				continue
			seen[ni] = 1
			if float(filled[ni]) < fc:
				filled[ni] = fc
			_heap_push(_pack(_level_scaled(filled[ni]), ni))
	if cnt < n:
		proc.resize(cnt)
	return proc


# 只影响堆序（不参与任何指标数值）：2^30 量化远超 float32 在 [0,1] 的最小间隔，
# 故不会把两个不同的 float32 高度并列到同一键位；即便并列，filled 的值也与出栈序无关。
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


# 直方图：u8 数组 → {下标字符串: 计数}，只输出非零桶。
func _histogram(values: PackedByteArray) -> Dictionary:
	var out := {}
	if values.size() == 0:
		return out
	var counts := PackedInt32Array()
	counts.resize(256)
	for i in range(values.size()):
		counts[int(values[i])] += 1
	for k in range(256):
		if counts[k] > 0:
			out[str(k)] = counts[k]
	return out


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


# Spearman：**平均秩**（并列取平均位次 = 标准定义），与 numpy/scipy 的 tie 修正一致。
# 做法：把「值量化 × m + 局部下标」打包成 int64 → 一次原生 sort() → 再线性走等值区段，
# 把区段内的序号平均后回填。O(m log m) 而且零 lambda、零逐元素比较排序。
# 为什么不用 `np.argsort(np.argsort(x))` 那种「序号秩」：并列会被按数组顺序硬编号，
# 而 log10(A) 在 A=1…3 上有大量并列 —— 实测同一批基线 M1 会因并列顺序摆动 ±0.03…0.14
# （seed 20260718@60×40：序号秩 −0.2880 / −0.2525 两种并列序 vs 平均秩 −0.2883；
#  40 种子均值：序号秩 −0.257 vs 平均秩 −0.286）。平均秩与并列顺序无关，才可跨实现比对。
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
			v = 0.0           # 掩码已保证非负；兜底避免负键破坏排序
		if v > 100.0:
			v = 100.0         # 值域上界（log10 A <= ~4.5、ridge <= 1）：钳住以免 int64 溢出
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


# log10(y) ~ log10(x) 的最小二乘斜率（中心化两点式，避免大数相减抵消）。
func _regress_slope(x: PackedFloat64Array, y: PackedFloat64Array) -> float:
	var m := x.size()
	if m < MIN_SAMPLE or y.size() != m:
		return NAN
	var mx := 0.0
	var my := 0.0
	for i in range(m):
		mx += x[i]
		my += y[i]
	mx /= float(m)
	my /= float(m)
	var sxx := 0.0
	var sxy := 0.0
	for i in range(m):
		var dx := x[i] - mx
		sxx += dx * dx
		sxy += dx * (y[i] - my)
	if sxx <= 1.0e-20:
		return NAN
	return sxy / sxx


# ═════════════════════════════════════════════════════════════════════════════
# 基线加载 / 聚合
# ═════════════════════════════════════════════════════════════════════════════

func _load_baseline() -> void:
	var paths: Array = []
	var env_path := OS.get_environment("P5_BASELINE").strip_edges()
	if env_path != "":
		paths.append(env_path)
	paths.append(BASELINE_DIR + "/metrics_gd.json")
	paths.append(BASELINE_DIR + "/metrics_py.json")
	for p in paths:
		var path := str(p)
		if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
			continue
		var parsed = JSON.parse_string(_read_text(path))
		if not (parsed is Dictionary):
			# metrics_py.json 里带 Python 的 `NaN` 字面量，Godot 的 JSON 解析器可能整篇拒收。
			print("[ridge-metrics] 基线 JSON 解析失败，试下一个候选：%s" % path)
			continue
		var rows: Array = (parsed as Dictionary).get("rows", [])
		for r in rows:
			if r is Dictionary:
				_baseline["%d|%d|%d" % [int(r.get("seed", 0)), int(r.get("w", 0)),
						int(r.get("h", 0))]] = r
		_baseline_src = path
		print("[ridge-metrics] baseline loaded: %s rows=%d" % [path, _baseline.size()])
		return
	print("[ridge-metrics] baseline JSON 未找到（试过 %s）→ 退回常量 BASELINE_FALLBACK（全量种子均值）"
			% str(paths))
	_baseline_src = "constant"


func _baseline_row(seed_v: int, w: int, h: int) -> Dictionary:
	var key := "%d|%d|%d" % [seed_v, w, h]
	if _baseline.has(key):
		return _baseline[key]
	return {}


# assert 集合上的基线/新版**成对**均值：按 (seed,w,h) 对齐，**任一侧为 null 的行跳过**
# （60×40 上 A≥100 的样本常常不足 → M3/M4 合法地是 null；不能因为某一行缺值就让整条指标 SKIP）。
# 返回 [新版均值, 基线均值, 配对数]。完全没有基线 JSON 时退回 BASELINE_FALLBACK 常量（量级参照）。
func _paired_mean(rows: Array, field: String) -> Array:
	var new_acc := 0.0
	var base_acc := 0.0
	var n := 0
	for r in rows:
		var v = r.get(field, null)
		if v == null:
			continue
		var b := _baseline_row(int(r["seed"]), int(r["w"]), int(r["h"]))
		if b.is_empty():
			continue
		var bv = b.get(field, null)
		if bv == null:
			continue
		new_acc += float(v)
		base_acc += float(bv)
		n += 1
	if n > 0:
		return [new_acc / float(n), base_acc / float(n), n]
	if _baseline_src == "constant":
		var m := _rows_mean(rows, field)
		var size_acc := 0.0
		var size_n := 0
		for r in rows:
			var block: Dictionary = BASELINE_FALLBACK.get(
					"%dx%d" % [int(r["w"]), int(r["h"])], {})
			var bv2 = block.get(field, null)
			if bv2 == null:
				continue
			size_acc += float(bv2)
			size_n += 1
		if size_n > 0 and not is_nan(m):
			return [m, size_acc / float(size_n), size_n]
	return [NAN, NAN, 0]


# 计数型指标的成对合计（M2(a)/M2(b)）。返回 [新版合计, 基线合计, 配对数]。
func _paired_sum(rows: Array, field: String) -> Array:
	var new_sum := 0.0
	var base_sum := 0.0
	var n := 0
	for r in rows:
		var v = r.get(field, null)
		if v == null:
			continue
		var b := _baseline_row(int(r["seed"]), int(r["w"]), int(r["h"]))
		if b.is_empty():
			continue
		var bv = b.get(field, null)
		if bv == null:
			continue
		new_sum += float(v)
		base_sum += float(bv)
		n += 1
	if n > 0:
		return [new_sum, base_sum, n]
	if _baseline_src == "constant":
		var size_acc := 0.0
		var size_n := 0
		for r in rows:
			var block: Dictionary = BASELINE_FALLBACK.get(
					"%dx%d" % [int(r["w"]), int(r["h"])], {})
			var bv2 = block.get(field, null)
			if bv2 == null:
				continue
			size_acc += float(bv2)
			size_n += 1
		if size_n > 0:
			var new_acc2 := 0.0
			for r in rows:
				new_acc2 += float(r.get(field, 0))
			return [new_acc2, size_acc, size_n]
	return [NAN, NAN, 0]


func _aggregate(rows: Array, w: int) -> Dictionary:
	var sel: Array = []
	for r in rows:
		if int(r.get("w", -1)) == w:
			sel.append(r)
	var out := {"seeds": sel.size()}
	for f in ["M1", "M3", "M3_down", "M4", "M5", "M5_p90", "land_p50", "land_p90", "land_p99"]:
		out[f + "_mean"] = _num(_rows_mean(sel, f))
	for f in ["M2_pits", "M2_ridge_pits", "M5_cand", "M5_p90_cand", "land_cells"]:
		var sum := 0
		var acc := 0.0
		for r in sel:
			sum += int(r.get(f, 0))
			acc += float(r.get(f, 0))
		out[f + "_sum"] = sum
		if sel.size() > 0:
			out[f + "_mean"] = _num(acc / float(sel.size()))
	var base_ms_acc := 0.0
	var cnt := 0
	for r in sel:
		base_ms_acc += float(r.get("base_ms", 0.0))
		cnt += 1
	if cnt > 0:
		out["base_ms_mean"] = _num(base_ms_acc / float(cnt))
	return out


func _rows_mean(rows: Array, field: String) -> float:
	var acc := 0.0
	var n := 0
	for r in rows:
		var v = r.get(field, null)
		if v == null:
			continue
		acc += float(v)
		n += 1
	if n == 0:
		return NAN
	return acc / float(n)


# ═════════════════════════════════════════════════════════════════════════════
# 断言 / 跳过 / 小工具
# ═════════════════════════════════════════════════════════════════════════════

func _expect(ok: bool, label: String) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("  [FAIL] %s" % label)


# 按项查表（GATES）决定 hard / record —— 取代原来的全局 P5_STRICT 开关（计划 §2.3）。
#   hard   → 走 _expect：失败计入 _failures / 影响退出码
#   record → 打印 [RECORD-ONLY]，只累计 targets_hit / targets_missed，**不影响退出码**
# 「确定性 / 原生成功 / 指标可算」是**不变量**，不在这张表里，始终走 _expect（见 T3-1/T3-2）。
func _gate(item: String, ok: bool, label: String) -> void:
	if String(GATES.get(item, GATE_RECORD)) == GATE_HARD:
		_expect(ok, label)
		return
	if ok:
		_targets_hit += 1
		print("  [RECORD-ONLY] hit  %s（只记录，不计失败）" % label)
	else:
		_targets_missed += 1
		print("  [RECORD-ONLY] miss %s（只记录，不计失败；判据待计划 §5 修订）" % label)


# 打印门禁表用：按 GATES 的声明顺序列出属于某一档的指标。
func _items_with_gate(kind: String) -> String:
	var names := ""
	for key in GATES.keys():
		if String(GATES[key]) == kind:
			names += "%s " % String(key)
	return names.strip_edges()


func _skip(tag: String, reason: String) -> void:
	_checks += 1
	_skips += 1
	print("%s: SKIP reason=%s" % [tag, reason])


func _env_float(name: String, fallback: float) -> float:
	var raw := OS.get_environment(name).strip_edges()
	if raw == "":
		return fallback
	if not raw.is_valid_float():
		return fallback
	return raw.to_float()


func _fmt_v(v) -> String:
	if v == null:
		return "n/a"
	return "%.4f" % float(v)


func _fmt_sum(v: float) -> String:
	if is_nan(v):
		return "n/a"
	return "%.2f" % v


func _fmt_list(rows: Array, field: String) -> String:
	var s := ""
	for r in rows:
		s += "%d×%d=%s " % [int(r["seed"]), int(r["w"]), _fmt_v(r.get(field, null))]
	return s


func _num(v: float) -> Variant:
	if is_nan(v) or not is_finite(v):
		return null
	return v


func _read_text(path: String) -> String:
	var f := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if f == null:
		push_error("[ridge-metrics] 无法写入 %s" % path)
		_failures += 1
		return
	f.store_string(text)
	f.close()


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	if f == null:
		push_error("[ridge-metrics] 无法写入 %s" % path)
		_failures += 1
		return
	f.store_buffer(bytes)
	f.close()


func _read_bytes(path: String) -> PackedByteArray:
	if not FileAccess.file_exists(ProjectSettings.globalize_path(path)):
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(path))


func _read_f32(path: String, n: int) -> PackedFloat32Array:
	var bytes := _read_bytes(path)
	if bytes.size() != n * 4:
		return PackedFloat32Array()
	return bytes.to_float32_array()


func _read_u8(path: String) -> PackedByteArray:
	return _read_bytes(path)


func _hash32(values: PackedFloat32Array) -> int:
	var bytes := values.to_byte_array()
	var hsh := 0x811C9DC5
	for i in range(bytes.size()):
		hsh = (hsh ^ int(bytes[i])) * 16777619
		hsh = hsh & 0xFFFFFFFF
	return hsh
