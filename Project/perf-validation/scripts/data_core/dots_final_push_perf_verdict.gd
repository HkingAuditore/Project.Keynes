extends RefCounted
class_name DCDotsFinalPushPerfVerdict

## DataCore — DOTS-Final-Push 终端稳态指标校验器（task-item.md 任务 10）
##
## 对接现有 perf 采集机制（不引入新框架）：
##   - SUS scheduler `_stats[job_id]`：每个 SUS Job 的滚动窗口 samples / max_ms / skipped
##     （sus_scheduler.gd line 339+；report_last_tick 仅最后一 tick，本类用 evaluate
##     需要 caller 自己累积 N tick 的 fast_tick total_ms 数组）
##   - main.gd `_fast_tick_count` / `_fast_tick_warn_last_frame`：fast tick 总数与
##     最近一次 WARN 触发位置；caller 在 200 tick 验收循环中自行喂入 total_ms 数组
##
## 与既有 hex_renderer 30s sampler / dots_soak_ab_runner 的关系：
##   - hex_renderer sampler：30s 滑窗 → 用于运行时 HUD 显示
##   - dots_soak_ab_runner：30 tick A/B 数值漂移（任务 8 验收，看 numeric drift）
##   - 本类：N tick fast tick 集成稳态门槛（任务 10 验收，看时延门槛）
##   三者互补，分别对应"实时 / 数值正确 / 终端时延"三个独立验收目标。
##
## 验收门槛（与 plan/dots-final-push/requirements.md §6 一致）：
##   - WARN_RATIO_2400  : 2400 cells 200 tick 中 fast tick WARN 占比 ≤ 0.5%（≤ 1 次）
##   - TOTAL_P95_2400   : total_ms p95 ≤ 12ms
##   - TOTAL_P99_2400   : total_ms p99 ≤ 20ms
##   - SUS_JOB_P95      : 任一 SUS job p95 ≤ 8ms（豁免初始化类 job）
##   - WARN_RATIO_6400  : 6400 cells 大地图 200 tick 中 WARN 占比 ≤ 5%
const WARN_RATIO_THRESHOLD_2400: float = 0.005   # 6.1
const TOTAL_P95_THRESHOLD_MS: float = 12.0       # 6.2
const TOTAL_P99_THRESHOLD_MS: float = 20.0       # 6.2
const SUS_JOB_P95_THRESHOLD_MS: float = 8.0      # 6.3
const WARN_RATIO_THRESHOLD_6400: float = 0.05    # 6.4

## 豁免清单：初始化期可能拖长尾的 Job，不计入 SUS_JOB_P95 验收（需求 6.3）。
## 这些 Job 在玩法稳态下平均 < 1ms，但首次或 cache miss 时可能 spike，
## 与本计划的稳态目标无关。
##
## 注意：GDScript 4.x 的 `const` 只接受字面量初始化器，不能用 `PackedStringArray([...])`
## 这种运行时构造（会报 "Assigned value for constant"）。直接用 Array 字面量即可，
## 后续 `job_id_str in _SUS_JOB_EXEMPT` 的语义与 PackedStringArray 等价。
const _SUS_JOB_EXEMPT: Array = [
	"enum_atlas_upload",      # GPU upload 主线程同步，仍出于稳健给 spike 留余量
]


## 计算分位数（线性插值）。samples 必须为 Array[float]，可乱序。
static func _percentile(samples: Array, q: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted: Array = samples.duplicate()
	sorted.sort()
	if sorted.size() == 1:
		return float(sorted[0])
	var pos: float = clampf(q, 0.0, 1.0) * float(sorted.size() - 1)
	var lo: int = int(floor(pos))
	var hi: int = int(ceil(pos))
	if lo == hi:
		return float(sorted[lo])
	var frac: float = pos - float(lo)
	return float(sorted[lo]) * (1.0 - frac) + float(sorted[hi]) * frac


## 验收主入口：根据 N tick 采集到的 total_ms 数组 + SUS scheduler 的 _stats，
## 给出每个门槛的 PASS / FAIL 与次高瓶颈。
##
## 入参：
##   total_ms_samples : Array[float]   — N 个 fast tick 的 total_ms（caller 在 200
##                                       tick 循环中累积；建议 N ≥ 200）
##   warn_count       : int           — 同 N tick 内 fast_tick WARN 触发次数
##                                      （main.gd 的 _fast_tick_warn_last_frame 推算
##                                      或直接计数 trigger_warn 命中数）
##   sus_job_stats    : Dictionary    — sus_scheduler._stats（按 job_id 的滚动窗口）
##                                      schema: {job_id -> {samples, max_ms, skipped, ...}}
##   cell_count       : int           — 当前地图 cell 数（决定走 2400 还是 6400 阈值）
##
## 返回：Dictionary
##   {
##     overall: bool,                          # 全部硬门槛是否通过
##     cell_count: int,
##     n_ticks: int,
##     warn_count: int,
##     warn_ratio: float,
##     total_avg_ms: float, total_p50/p95/p99_ms: float,
##     warn_ratio_threshold: float,
##     warn_ratio_pass: bool,
##     total_p95_pass: bool,
##     total_p99_pass: bool,
##     sus_job_worst: { job_id: String, p95_ms: float, exempted: bool, pass: bool },
##     sus_job_p95_table: Array[ {job_id, p95_ms, exempted, pass} ],
##     next_bottleneck: { job_id: String, p95_ms: float },  # 用于下一轮 plan 输入
##     fail_reasons: Array[String],
##   }
static func evaluate(total_ms_samples: Array, warn_count: int,
		sus_job_stats: Dictionary, cell_count: int) -> Dictionary:
	var n_ticks: int = total_ms_samples.size()
	var warn_ratio: float = 0.0
	if n_ticks > 0:
		warn_ratio = float(warn_count) / float(n_ticks)

	var total_avg_ms: float = 0.0
	if n_ticks > 0:
		var sum: float = 0.0
		for v in total_ms_samples:
			sum += float(v)
		total_avg_ms = sum / float(n_ticks)
	var total_p50_ms: float = _percentile(total_ms_samples, 0.50)
	var total_p95_ms: float = _percentile(total_ms_samples, 0.95)
	var total_p99_ms: float = _percentile(total_ms_samples, 0.99)

	# 选择 warn ratio 阈值：cell_count 大于 4000 视为大地图（需求 6.4）
	var is_large_map: bool = cell_count >= 4000
	var warn_ratio_threshold: float = (
		WARN_RATIO_THRESHOLD_6400 if is_large_map else WARN_RATIO_THRESHOLD_2400
	)
	var warn_ratio_pass: bool = warn_ratio <= warn_ratio_threshold

	# total p95 / p99 门槛仅对小地图基线（2400 cells）严格生效；大地图作为软门槛
	# （需求 6.4 仅约束 warn 占比），不参与 overall 硬门槛。
	var total_p95_pass: bool = (not is_large_map) or total_p95_ms <= TOTAL_P95_THRESHOLD_MS
	var total_p99_pass: bool = (not is_large_map) or total_p99_ms <= TOTAL_P99_THRESHOLD_MS
	if not is_large_map:
		total_p95_pass = total_p95_ms <= TOTAL_P95_THRESHOLD_MS
		total_p99_pass = total_p99_ms <= TOTAL_P99_THRESHOLD_MS

	# SUS 各 Job p95（豁免初始化类）。按 p95 排序找次高瓶颈。
	var p95_rows: Array = []
	for job_id in sus_job_stats.keys():
		var s: Dictionary = sus_job_stats[job_id]
		var samples: Array = s.get("samples", [])
		if samples.is_empty():
			continue
		var p95_ms: float = _percentile(samples, 0.95)
		var job_id_str: String = String(job_id)
		var exempted: bool = job_id_str in _SUS_JOB_EXEMPT
		var passed: bool = exempted or p95_ms <= SUS_JOB_P95_THRESHOLD_MS
		p95_rows.append({
			"job_id": job_id_str,
			"p95_ms": p95_ms,
			"exempted": exempted,
			"pass": passed,
		})
	# 按 p95 倒序，取首个非豁免作为 worst（用于 verdict）；首个豁免也记录为 next_bottleneck
	p95_rows.sort_custom(func(a, b): return float(a["p95_ms"]) > float(b["p95_ms"]))
	var sus_job_worst: Dictionary = {}
	var next_bottleneck: Dictionary = {}
	for r in p95_rows:
		if not bool(r.get("exempted", false)) and sus_job_worst.is_empty():
			sus_job_worst = r
		# next_bottleneck = 第二高（用于下一轮 plan 输入；可能等于 worst 之后那个）
		if next_bottleneck.is_empty() and r != sus_job_worst:
			next_bottleneck = r
	if sus_job_worst.is_empty() and not p95_rows.is_empty():
		# 全部豁免的极端情况，把第一个作为 worst（但仍 pass=true）
		sus_job_worst = p95_rows[0]

	var sus_job_p95_pass: bool = bool(sus_job_worst.get("pass", true)) if not sus_job_worst.is_empty() else true

	var fail_reasons: Array = []
	if not warn_ratio_pass:
		fail_reasons.append("[6.%d] fast tick WARN ratio %.2f%% > threshold %.2f%% (n=%d, warn=%d)" % [
			(4 if is_large_map else 1),
			warn_ratio * 100.0, warn_ratio_threshold * 100.0, n_ticks, warn_count,
		])
	if not total_p95_pass:
		fail_reasons.append("[6.2] total p95 %.2fms > threshold %.2fms" % [
			total_p95_ms, TOTAL_P95_THRESHOLD_MS,
		])
	if not total_p99_pass:
		fail_reasons.append("[6.2] total p99 %.2fms > threshold %.2fms" % [
			total_p99_ms, TOTAL_P99_THRESHOLD_MS,
		])
	if not sus_job_p95_pass and not sus_job_worst.is_empty():
		fail_reasons.append("[6.3] SUS job '%s' p95 %.2fms > threshold %.2fms" % [
			String(sus_job_worst["job_id"]),
			float(sus_job_worst["p95_ms"]),
			SUS_JOB_P95_THRESHOLD_MS,
		])

	var overall: bool = warn_ratio_pass and total_p95_pass and total_p99_pass and sus_job_p95_pass

	return {
		"overall": overall,
		"cell_count": cell_count,
		"is_large_map": is_large_map,
		"n_ticks": n_ticks,
		"warn_count": warn_count,
		"warn_ratio": warn_ratio,
		"warn_ratio_threshold": warn_ratio_threshold,
		"warn_ratio_pass": warn_ratio_pass,
		"total_avg_ms": total_avg_ms,
		"total_p50_ms": total_p50_ms,
		"total_p95_ms": total_p95_ms,
		"total_p99_ms": total_p99_ms,
		"total_p95_pass": total_p95_pass,
		"total_p99_pass": total_p99_pass,
		"sus_job_worst": sus_job_worst,
		"sus_job_p95_table": p95_rows,
		"sus_job_p95_pass": sus_job_p95_pass,
		"next_bottleneck": next_bottleneck,
		"fail_reasons": fail_reasons,
	}


## 把 evaluate() 的 verdict Dictionary 格式化为人读日志（控制台 + perf-report 用）。
##
## 用法：
##   var verdict := DCDotsFinalPushPerfVerdict.evaluate(...)
##   for line in DCDotsFinalPushPerfVerdict.format_verdict_lines(verdict):
##       print(line)
static func format_verdict_lines(verdict: Dictionary) -> Array:
	var lines: Array = []
	var overall: bool = bool(verdict.get("overall", false))
	var n_ticks: int = int(verdict.get("n_ticks", 0))
	var cell_count: int = int(verdict.get("cell_count", 0))
	var is_large_map: bool = bool(verdict.get("is_large_map", false))
	var label: String = "PASS" if overall else "FAIL"
	var map_label: String = "6400+ (large)" if is_large_map else "2400 (baseline)"
	lines.append("[DOTS-Final-Push/perf] verdict = %s   (cells=%s, n=%d ticks)" % [
		label, map_label, n_ticks,
	])
	lines.append("[DOTS-Final-Push/perf]   warn_ratio = %.2f%% (count=%d, threshold=%.2f%%) → %s" % [
		float(verdict.get("warn_ratio", 0.0)) * 100.0,
		int(verdict.get("warn_count", 0)),
		float(verdict.get("warn_ratio_threshold", 0.0)) * 100.0,
		"PASS" if bool(verdict.get("warn_ratio_pass", false)) else "FAIL",
	])
	lines.append("[DOTS-Final-Push/perf]   total avg=%.2fms  p50=%.2fms  p95=%.2fms (≤ %.1fms %s)  p99=%.2fms (≤ %.1fms %s)" % [
		float(verdict.get("total_avg_ms", 0.0)),
		float(verdict.get("total_p50_ms", 0.0)),
		float(verdict.get("total_p95_ms", 0.0)),
		TOTAL_P95_THRESHOLD_MS,
		"PASS" if bool(verdict.get("total_p95_pass", false)) else "FAIL",
		float(verdict.get("total_p99_ms", 0.0)),
		TOTAL_P99_THRESHOLD_MS,
		"PASS" if bool(verdict.get("total_p99_pass", false)) else "FAIL",
	])
	var rows: Array = verdict.get("sus_job_p95_table", [])
	lines.append("[DOTS-Final-Push/perf]   SUS jobs (top by p95, threshold=%.1fms; * = exempt):" % SUS_JOB_P95_THRESHOLD_MS)
	var shown: int = 0
	for r in rows:
		if shown >= 6:
			break
		var marker: String = "*" if bool(r.get("exempted", false)) else " "
		var pass_str: String = "PASS" if bool(r.get("pass", true)) else "FAIL"
		lines.append("[DOTS-Final-Push/perf]     %s %-28s p95=%.2fms %s" % [
			marker,
			String(r.get("job_id", "?")),
			float(r.get("p95_ms", 0.0)),
			pass_str,
		])
		shown += 1
	var nb: Dictionary = verdict.get("next_bottleneck", {})
	if not nb.is_empty():
		lines.append("[DOTS-Final-Push/perf]   next bottleneck = '%s' p95=%.2fms (input for next plan)" % [
			String(nb.get("job_id", "?")),
			float(nb.get("p95_ms", 0.0)),
		])
	var reasons: Array = verdict.get("fail_reasons", [])
	for fr in reasons:
		lines.append("[DOTS-Final-Push/perf]   FAIL → %s" % String(fr))
	return lines


# ─── plan/dirty-push-atlas-encode 阶段 G：baker atlas section 4 档对照 verdict ─

## 4 档对照场景（caller 预先把每档跑 N tick 收集到 baker 段时延采样）：
##   - "legacy"       : dirty_push_enabled=false 全图扫 + sig 比对（基线）
##   - "mask_gd"      : dirty_push_enabled=true + cpp 关 → GDScript dirty 路径（阶段 D+E）
##   - "mask_gd_full" : 同上但 stride 拉到极端（200 tick 全部 dirty）模拟最差工况
##   - "mask_cpp"     : cpp_atlas_encode_enabled=true，DCWorldExt encode_* 启用（阶段 F）
##
## 验收门槛（plan/dirty-push-atlas-encode §性能预期）：
##   - mask_gd p95 < legacy p95 × 0.5（至少减半）
##   - mask_cpp p95 < mask_gd p95 × 0.5（再减半）
##   - 任一档 p95 都不能 > legacy p95 × 1.10（防回归 10% 容差）
##
## 入参：
##   section_samples : Dictionary
##                     {
##                       "legacy":       Array[float],  # baker 段总 ms（4 phase 累加）
##                       "mask_gd":      Array[float],
##                       "mask_gd_full": Array[float],  # optional，缺省时跳过该档比对
##                       "mask_cpp":     Array[float],  # optional，缺省时跳过 cpp 验收
##                     }
##
## 返回：Dictionary
##   {
##     overall: bool,                                  # 4 档对照硬门槛是否全部通过
##     by_label: { label -> { n, avg, p50, p95, p99 } },
##     legacy_p95: float,
##     reductions: { "mask_gd": float, "mask_cpp": float },  # p95 相对 legacy 的比例
##     fail_reasons: Array[String],
##   }
const _BAKER_REGRESSION_TOLERANCE: float = 1.10   # 任一档不能比 legacy 慢 10% 以上
const _BAKER_MASK_GD_TARGET: float = 0.50          # mask_gd 应至少减半
const _BAKER_MASK_CPP_TARGET: float = 0.50         # mask_cpp 应在 mask_gd 基础上再减半

static func evaluate_baker_atlas_section(section_samples: Dictionary) -> Dictionary:
	var by_label: Dictionary = {}
	for label in section_samples.keys():
		var samples: Array = section_samples[label]
		if samples == null or samples.is_empty():
			continue
		var n: int = samples.size()
		var sum: float = 0.0
		for v in samples:
			sum += float(v)
		by_label[label] = {
			"n": n,
			"avg": sum / float(n),
			"p50": _percentile(samples, 0.50),
			"p95": _percentile(samples, 0.95),
			"p99": _percentile(samples, 0.99),
		}
	var fail_reasons: Array = []
	# legacy 必须存在（基线）
	if not by_label.has("legacy"):
		fail_reasons.append("legacy baseline samples missing — cannot evaluate")
		return {
			"overall": false,
			"by_label": by_label,
			"legacy_p95": 0.0,
			"reductions": {},
			"fail_reasons": fail_reasons,
		}
	var legacy_p95: float = float(by_label["legacy"].get("p95", 0.0))
	var reductions: Dictionary = {}
	# mask_gd 验收
	if by_label.has("mask_gd"):
		var mg_p95: float = float(by_label["mask_gd"].get("p95", 0.0))
		reductions["mask_gd"] = mg_p95 / legacy_p95 if legacy_p95 > 0.0 else 1.0
		if mg_p95 > legacy_p95 * _BAKER_REGRESSION_TOLERANCE:
			fail_reasons.append("mask_gd p95 (%.2fms) regresses vs legacy (%.2fms × %.0f%%)"
				% [mg_p95, legacy_p95, _BAKER_REGRESSION_TOLERANCE * 100.0])
		elif mg_p95 > legacy_p95 * _BAKER_MASK_GD_TARGET:
			fail_reasons.append("mask_gd p95 (%.2fms) does not meet target ≤ legacy × %.0f%% (%.2fms)"
				% [mg_p95, _BAKER_MASK_GD_TARGET * 100.0, legacy_p95 * _BAKER_MASK_GD_TARGET])
	# mask_gd_full 仅做防回归（最坏工况下不能比 legacy 慢 10% 以上）
	if by_label.has("mask_gd_full"):
		var mgf_p95: float = float(by_label["mask_gd_full"].get("p95", 0.0))
		if mgf_p95 > legacy_p95 * _BAKER_REGRESSION_TOLERANCE:
			fail_reasons.append("mask_gd_full p95 (%.2fms) regresses vs legacy (%.2fms × %.0f%%)"
				% [mgf_p95, legacy_p95, _BAKER_REGRESSION_TOLERANCE * 100.0])
	# mask_cpp 验收（在 mask_gd 基础上再减半）
	if by_label.has("mask_cpp") and by_label.has("mask_gd"):
		var mc_p95: float = float(by_label["mask_cpp"].get("p95", 0.0))
		var mg_p95_2: float = float(by_label["mask_gd"].get("p95", 0.0))
		reductions["mask_cpp"] = mc_p95 / legacy_p95 if legacy_p95 > 0.0 else 1.0
		if mg_p95_2 > 0.0 and mc_p95 > mg_p95_2 * _BAKER_MASK_CPP_TARGET:
			fail_reasons.append("mask_cpp p95 (%.2fms) does not meet target ≤ mask_gd × %.0f%% (%.2fms)"
				% [mc_p95, _BAKER_MASK_CPP_TARGET * 100.0, mg_p95_2 * _BAKER_MASK_CPP_TARGET])
	return {
		"overall": fail_reasons.is_empty(),
		"by_label": by_label,
		"legacy_p95": legacy_p95,
		"reductions": reductions,
		"fail_reasons": fail_reasons,
	}


## 把 evaluate_baker_atlas_section 输出格式化为可读行，配 print_rich 直接打。
static func format_baker_atlas_section_lines(verdict: Dictionary) -> Array:
	var lines: Array = []
	var overall: bool = bool(verdict.get("overall", false))
	var status: String = "PASS" if overall else "FAIL"
	lines.append("[plan/dirty-push-atlas-encode/perf] baker atlas section verdict: %s" % status)
	var by_label: Dictionary = verdict.get("by_label", {})
	for label in by_label.keys():
		var s: Dictionary = by_label[label]
		lines.append("[plan/dirty-push-atlas-encode/perf]   %-13s n=%-4d avg=%6.2fms p50=%6.2fms p95=%6.2fms p99=%6.2fms"
				% [String(label), int(s.get("n", 0)),
				   float(s.get("avg", 0.0)), float(s.get("p50", 0.0)),
				   float(s.get("p95", 0.0)), float(s.get("p99", 0.0))])
	var reductions: Dictionary = verdict.get("reductions", {})
	for k in reductions.keys():
		lines.append("[plan/dirty-push-atlas-encode/perf]   reduction(%s) = %.1f%% of legacy"
				% [String(k), float(reductions[k]) * 100.0])
	var reasons: Array = verdict.get("fail_reasons", [])
	for r in reasons:
		lines.append("[plan/dirty-push-atlas-encode/perf]   FAIL → %s" % String(r))
	return lines
