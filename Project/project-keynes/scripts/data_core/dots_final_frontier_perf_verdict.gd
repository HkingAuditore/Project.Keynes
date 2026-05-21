extends RefCounted
class_name DCDotsFinalFrontierPerfVerdict

## DataCore — DOTS-Final-Frontier Phase B+ 终端稳态指标校验器
##
## 与 DCDotsFinalPushPerfVerdict / DCDotsTotalCppPerfVerdict 完全独立的验收脚本，
## 是 Phase B+（season_refresh full-round single-call）落地后的"最终状态"门槛：
##
##   - final_push 阈值：p95 ≤ 12ms / p99 ≤ 20ms / sus_job p95 ≤ 8ms
##   - total_cpp 阈值： p95 ≤ 10ms / p99 ≤ 16ms / sus_job p95 ≤ 6ms
##   - **frontier 阈值（本脚本）**：p95 ≤ 5ms / p99 ≤ 10ms / sus_job p95 ≤ 4ms
##
## 一旦本脚本 PASS：
##   - season_refresh 12-stage round 调度层已下沉到 C++（B+ 路径）
##   - GDScript→C++ 跨界 12 次/round → 3 次/round
##   - facade sync + history push 由 8 次/round 收敛为 1 次/round
##   - season_refresh_job p95 ≤ 4ms（占 SUS budget < 30%）
##   - fast_ms p95 ≤ 5ms（用户最初目标）
##
## 入参与 DCDotsTotalCppPerfVerdict.evaluate() 完全同 schema，但额外接受 B+ 专属指标
## season_round_stats（见下方文档），用于评 B+ 路径自身健康度。
##
## 验收门槛（与 plan/dots-final-frontier B+ 章节一致）：
##   - WARN_RATIO_2400_TARGET   : 2400 cells 200 tick 中 fast tick WARN 占比 ≤ 0.2%（更严）
##   - TOTAL_P95_2400_TARGET    : total_ms p95 ≤ 5ms
##   - TOTAL_P99_2400_TARGET    : total_ms p99 ≤ 10ms
##   - SUS_JOB_P95_TARGET       : 任一 SUS job p95 ≤ 4ms（豁免初始化类）
##   - WARN_RATIO_6400_TARGET   : 6400 cells 200 tick 中 WARN 占比 ≤ 1.5%
##   - B_PLUS_FALLBACK_RATIO    : B+ 路径 fallback 比例 ≤ 0.5%（理想 0%）
##   - B_PLUS_SLICES_PER_ROUND  : 平均 slices_used ≤ 14（12 stage + 余量）
##   - B_PLUS_NATIVE_MS_RATIO   : C++ 内 native_ms 占总 round time ≥ 90%
##
## 关于 B+ 行为变更（用户已确认）：
##   - history push 8→1：本验收**不**校验 history 长度变化，但写到说明里供 QA 知情
##   - facade sync 8→1：理论上每 round 视觉刷新更"齐整"，A/B bit-equal 由
##     dots_soak_ab_runner.start_season_round_batch 单独负责
const WARN_RATIO_THRESHOLD_2400: float = 0.002   # 2400 cells, 1.5x 严于 total_cpp
const WARN_RATIO_THRESHOLD_6400: float = 0.015   # 6400 cells, 2x 严于 total_cpp
const TOTAL_P95_THRESHOLD_MS: float = 5.0        # 用户原始目标 ≤5ms
const TOTAL_P99_THRESHOLD_MS: float = 10.0       # p99 给 spike 留 2x 余量
const SUS_JOB_P95_THRESHOLD_MS: float = 4.0      # 任一 SUS job ≤ 4ms（含 season_refresh）
const B_PLUS_FALLBACK_RATIO_THRESHOLD: float = 0.005  # 0.5%
const B_PLUS_SLICES_PER_ROUND_MAX: float = 14.0       # 12 + 2 余量
const B_PLUS_NATIVE_MS_RATIO_MIN: float = 0.90        # native 占比 ≥ 90%

## 豁免清单：与 total_cpp 一致 + GPU upload 类。
const _SUS_JOB_EXEMPT: Array = [
	"sea_ice_atlas_upload",   # GPU upload 主线程同步
	"enum_atlas_upload",      # ≤ 3ms 但仍给 spike 留余量
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


## 验收主入口。
##   total_ms_samples : Array[float]      — 每 fast tick 实际耗时（ms）
##   warn_count       : int               — fast tick WARN 计数（超 SUS budget）
##   sus_job_stats    : Dict[String, Dict]
##                                        — { job_id -> { samples: Array[float] } }
##   cell_count       : int               — 当前 map 大小
##   season_round_stats : Dictionary      — B+ 专属指标（可为空，不会 FAIL，只 INFO）
##     {
##       "rounds_total":         int   — 跑过的 round 总数
##       "rounds_b_plus":        int   — 实际走了 B+ 路径的 round 数
##       "rounds_fallback":      int   — B+ start 失败 / 中途 fallback 的 round 数
##       "slices_used_samples":  Array[int]  — 每 round 实际 slice 数
##       "stages_done_samples":  Array[int]  — 每 round 完成的 stage 数（应 == 12）
##       "native_ms_samples":    Array[float]  — 每 round C++ 内累计 ms
##       "wall_ms_samples":      Array[float]  — 每 round 上层挂钟 ms（包括跨界 + GDScript）
##     }
static func evaluate(total_ms_samples: Array, warn_count: int,
		sus_job_stats: Dictionary, cell_count: int,
		season_round_stats: Dictionary = {}) -> Dictionary:
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

	var is_large_map: bool = cell_count >= 4000
	var warn_ratio_threshold: float = (
		WARN_RATIO_THRESHOLD_6400 if is_large_map else WARN_RATIO_THRESHOLD_2400
	)
	var warn_ratio_pass: bool = warn_ratio <= warn_ratio_threshold
	var total_p95_pass: bool = total_p95_ms <= TOTAL_P95_THRESHOLD_MS
	var total_p99_pass: bool = total_p99_ms <= TOTAL_P99_THRESHOLD_MS

	# SUS jobs：复刻 total_cpp / final_push 同款表
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
	p95_rows.sort_custom(func(a, b): return float(a["p95_ms"]) > float(b["p95_ms"]))
	var sus_job_worst: Dictionary = {}
	var next_bottleneck: Dictionary = {}
	for r in p95_rows:
		if not bool(r.get("exempted", false)) and sus_job_worst.is_empty():
			sus_job_worst = r
		if next_bottleneck.is_empty() and r != sus_job_worst:
			next_bottleneck = r
	if sus_job_worst.is_empty() and not p95_rows.is_empty():
		sus_job_worst = p95_rows[0]
	var sus_job_p95_pass: bool = bool(sus_job_worst.get("pass", true)) if not sus_job_worst.is_empty() else true

	# B+ 专属指标
	var rounds_total: int = int(season_round_stats.get("rounds_total", 0))
	var rounds_b_plus: int = int(season_round_stats.get("rounds_b_plus", 0))
	var rounds_fallback: int = int(season_round_stats.get("rounds_fallback", 0))
	var fallback_ratio: float = 0.0
	if rounds_total > 0:
		fallback_ratio = float(rounds_fallback) / float(rounds_total)
	var fallback_pass: bool = (rounds_total == 0) or (fallback_ratio <= B_PLUS_FALLBACK_RATIO_THRESHOLD)
	var slices_used_samples: Array = season_round_stats.get("slices_used_samples", [])
	var slices_avg: float = 0.0
	if not slices_used_samples.is_empty():
		var ssum: float = 0.0
		for v in slices_used_samples:
			ssum += float(v)
		slices_avg = ssum / float(slices_used_samples.size())
	var slices_pass: bool = slices_used_samples.is_empty() or slices_avg <= B_PLUS_SLICES_PER_ROUND_MAX
	var native_ms_samples: Array = season_round_stats.get("native_ms_samples", [])
	var wall_ms_samples: Array = season_round_stats.get("wall_ms_samples", [])
	var native_ms_total: float = 0.0
	for v in native_ms_samples:
		native_ms_total += float(v)
	var wall_ms_total: float = 0.0
	for v in wall_ms_samples:
		wall_ms_total += float(v)
	var native_ratio: float = 0.0
	if wall_ms_total > 0.0:
		native_ratio = native_ms_total / wall_ms_total
	var native_ratio_pass: bool = (wall_ms_total <= 0.0) or (native_ratio >= B_PLUS_NATIVE_MS_RATIO_MIN)
	var stages_done_samples: Array = season_round_stats.get("stages_done_samples", [])
	var stages_full_round_count: int = 0
	for v in stages_done_samples:
		if int(v) >= 12:
			stages_full_round_count += 1
	var stages_full_ratio: float = 0.0
	if not stages_done_samples.is_empty():
		stages_full_ratio = float(stages_full_round_count) / float(stages_done_samples.size())

	var fail_reasons: Array = []
	if not warn_ratio_pass:
		fail_reasons.append("[B+] fast tick WARN ratio %.2f%% > threshold %.2f%% (n=%d, warn=%d)" % [
			warn_ratio * 100.0, warn_ratio_threshold * 100.0, n_ticks, warn_count,
		])
	if not total_p95_pass:
		fail_reasons.append("[B+] total p95 %.2fms > threshold %.2fms" % [
			total_p95_ms, TOTAL_P95_THRESHOLD_MS,
		])
	if not total_p99_pass:
		fail_reasons.append("[B+] total p99 %.2fms > threshold %.2fms" % [
			total_p99_ms, TOTAL_P99_THRESHOLD_MS,
		])
	if not sus_job_p95_pass and not sus_job_worst.is_empty():
		fail_reasons.append("[B+] SUS job '%s' p95 %.2fms > threshold %.2fms" % [
			String(sus_job_worst["job_id"]),
			float(sus_job_worst["p95_ms"]),
			SUS_JOB_P95_THRESHOLD_MS,
		])
	if rounds_total > 0 and not fallback_pass:
		fail_reasons.append("[B+] season_round fallback ratio %.2f%% > threshold %.2f%% (total=%d, fallback=%d)" % [
			fallback_ratio * 100.0, B_PLUS_FALLBACK_RATIO_THRESHOLD * 100.0, rounds_total, rounds_fallback,
		])
	if not slices_used_samples.is_empty() and not slices_pass:
		fail_reasons.append("[B+] season_round slices/round avg %.2f > max %.1f (b1 切片可能未及时退出，stage 7 候选 b2 升级)" % [
			slices_avg, B_PLUS_SLICES_PER_ROUND_MAX,
		])
	if wall_ms_total > 0.0 and not native_ratio_pass:
		fail_reasons.append("[B+] native_ms / wall_ms = %.1f%% < threshold %.1f%%（C++ 占比偏低，跨界仍为热点）" % [
			native_ratio * 100.0, B_PLUS_NATIVE_MS_RATIO_MIN * 100.0,
		])

	var overall: bool = (
		warn_ratio_pass and total_p95_pass and total_p99_pass and sus_job_p95_pass
		and fallback_pass and slices_pass and native_ratio_pass
	)

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
		# B+ 专属
		"rounds_total": rounds_total,
		"rounds_b_plus": rounds_b_plus,
		"rounds_fallback": rounds_fallback,
		"fallback_ratio": fallback_ratio,
		"fallback_pass": fallback_pass,
		"slices_avg": slices_avg,
		"slices_pass": slices_pass,
		"native_ms_total": native_ms_total,
		"wall_ms_total": wall_ms_total,
		"native_ratio": native_ratio,
		"native_ratio_pass": native_ratio_pass,
		"stages_full_ratio": stages_full_ratio,
		"fail_reasons": fail_reasons,
	}


## 把 evaluate() 的 verdict Dictionary 格式化为人读日志。
static func format_verdict_lines(verdict: Dictionary) -> Array:
	var lines: Array = []
	var overall: bool = bool(verdict.get("overall", false))
	var n_ticks: int = int(verdict.get("n_ticks", 0))
	var cell_count: int = int(verdict.get("cell_count", 0))
	var is_large_map: bool = bool(verdict.get("is_large_map", false))
	var label: String = "PASS" if overall else "FAIL"
	var map_label: String = "6400+ (large)" if is_large_map else "2400 (baseline)"
	lines.append("[DOTS-Final-Frontier/perf] verdict = %s   (cells=%s, n=%d ticks)" % [
		label, map_label, n_ticks,
	])
	lines.append("[DOTS-Final-Frontier/perf]   warn_ratio = %.2f%% (count=%d, threshold=%.2f%%) → %s" % [
		float(verdict.get("warn_ratio", 0.0)) * 100.0,
		int(verdict.get("warn_count", 0)),
		float(verdict.get("warn_ratio_threshold", 0.0)) * 100.0,
		"PASS" if bool(verdict.get("warn_ratio_pass", false)) else "FAIL",
	])
	lines.append("[DOTS-Final-Frontier/perf]   total avg=%.2fms  p50=%.2fms  p95=%.2fms (≤ %.1fms %s)  p99=%.2fms (≤ %.1fms %s)" % [
		float(verdict.get("total_avg_ms", 0.0)),
		float(verdict.get("total_p50_ms", 0.0)),
		float(verdict.get("total_p95_ms", 0.0)),
		TOTAL_P95_THRESHOLD_MS,
		"PASS" if bool(verdict.get("total_p95_pass", false)) else "FAIL",
		float(verdict.get("total_p99_ms", 0.0)),
		TOTAL_P99_THRESHOLD_MS,
		"PASS" if bool(verdict.get("total_p99_pass", false)) else "FAIL",
	])
	# SUS jobs Top-6
	var rows: Array = verdict.get("sus_job_p95_table", [])
	lines.append("[DOTS-Final-Frontier/perf]   SUS jobs (top by p95, threshold=%.1fms; * = exempt):" % SUS_JOB_P95_THRESHOLD_MS)
	var shown: int = 0
	for r in rows:
		if shown >= 6:
			break
		var marker: String = "*" if bool(r.get("exempted", false)) else " "
		var pass_str: String = "PASS" if bool(r.get("pass", true)) else "FAIL"
		lines.append("[DOTS-Final-Frontier/perf]     %s %-28s p95=%.2fms %s" % [
			marker,
			String(r.get("job_id", "?")),
			float(r.get("p95_ms", 0.0)),
			pass_str,
		])
		shown += 1
	var nb: Dictionary = verdict.get("next_bottleneck", {})
	if not nb.is_empty():
		lines.append("[DOTS-Final-Frontier/perf]   next bottleneck = '%s' p95=%.2fms" % [
			String(nb.get("job_id", "?")),
			float(nb.get("p95_ms", 0.0)),
		])
	# B+ 专属信息
	var rounds_total: int = int(verdict.get("rounds_total", 0))
	if rounds_total > 0:
		lines.append("[DOTS-Final-Frontier/perf]   --- B+ Round Stats ---")
		lines.append("[DOTS-Final-Frontier/perf]     rounds: total=%d  b_plus=%d  fallback=%d  fb_ratio=%.3f%% (≤ %.2f%% %s)" % [
			rounds_total,
			int(verdict.get("rounds_b_plus", 0)),
			int(verdict.get("rounds_fallback", 0)),
			float(verdict.get("fallback_ratio", 0.0)) * 100.0,
			B_PLUS_FALLBACK_RATIO_THRESHOLD * 100.0,
			"PASS" if bool(verdict.get("fallback_pass", false)) else "FAIL",
		])
		lines.append("[DOTS-Final-Frontier/perf]     slices/round avg=%.2f (≤ %.1f %s)   stages_full_ratio=%.1f%%" % [
			float(verdict.get("slices_avg", 0.0)),
			B_PLUS_SLICES_PER_ROUND_MAX,
			"PASS" if bool(verdict.get("slices_pass", false)) else "FAIL",
			float(verdict.get("stages_full_ratio", 0.0)) * 100.0,
		])
		var wall_total: float = float(verdict.get("wall_ms_total", 0.0))
		if wall_total > 0.0:
			lines.append("[DOTS-Final-Frontier/perf]     native_ms=%.1f  wall_ms=%.1f  native/wall=%.1f%% (≥ %.1f%% %s)" % [
				float(verdict.get("native_ms_total", 0.0)),
				wall_total,
				float(verdict.get("native_ratio", 0.0)) * 100.0,
				B_PLUS_NATIVE_MS_RATIO_MIN * 100.0,
				"PASS" if bool(verdict.get("native_ratio_pass", false)) else "FAIL",
			])
	var reasons: Array = verdict.get("fail_reasons", [])
	for fr in reasons:
		lines.append("[DOTS-Final-Frontier/perf]   FAIL → %s" % String(fr))
	# 验收说明（行为变更披露）
	if overall:
		lines.append("[DOTS-Final-Frontier/perf]   note: B+ 路径下 history.push 8→1/round（用户已确认，对应'每季度一次状态快照'语义）")
	return lines
