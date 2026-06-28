extends RefCounted
class_name DCDotsTotalCppPerfVerdict

## DataCore — DOTS-Total-CPP 终端稳态指标校验器
## （plan/dots-total-cpp/requirements.md §9.1 + task-item.md 任务 9）
##
## 与 DCDotsFinalPushPerfVerdict 完全独立的验收脚本：
##   - final_push 阈值：p95 ≤ 12ms / p99 ≤ 20ms / sus_job p95 ≤ 8ms
##   - total_cpp 阈值（本脚本）：p95 ≤ 10ms / p99 ≤ 16ms / sus_job p95 ≤ 6ms
##
## 这是 dots-total-cpp 计划完成后的"最终状态"门槛。一旦本脚本 PASS：
##   - season_refresh stage 0 已 C++ 化（剩余 stage 等价于 GDScript fallback）
##   - ocean_currents 一次性 round 已生效（rasterize 走 C++）
##   - ocean_water 同 tick 复用已减少冗余
##   - weather_refresh wrapper 已限频
##
## 与既有 hex_renderer 30s sampler / dots_soak_ab_runner 关系同 final_push verdict。
##
## 验收门槛（与 plan/dots-total-cpp/requirements.md §9.1 一致）：
##   - WARN_RATIO_2400_TARGET   : 2400 cells 200 tick 中 fast tick WARN 占比 ≤ 0.3%
##   - TOTAL_P95_2400_TARGET    : total_ms p95 ≤ 10ms
##   - TOTAL_P99_2400_TARGET    : total_ms p99 ≤ 16ms
##   - SUS_JOB_P95_TARGET       : 任一 SUS job p95 ≤ 6ms（豁免初始化类）
##   - WARN_RATIO_6400_TARGET   : 6400 cells 200 tick 中 WARN 占比 ≤ 3%
const WARN_RATIO_THRESHOLD_2400: float = 0.003   # 9.1
const TOTAL_P95_THRESHOLD_MS: float = 10.0       # 9.1
const TOTAL_P99_THRESHOLD_MS: float = 16.0       # 9.1
const SUS_JOB_P95_THRESHOLD_MS: float = 6.0      # 9.1
const WARN_RATIO_THRESHOLD_6400: float = 0.03    # 9.1

## 豁免清单：与 final_push 一致——初始化期可能拖长尾的 Job 不计入 SUS_JOB_P95。
const _SUS_JOB_EXEMPT: Array = [
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


## 验收主入口。入参 / 返回 schema 与 DCDotsFinalPushPerfVerdict.evaluate 完全一致，
## 仅阈值常量不同。caller 可直接换名调用获得更严格的 verdict。
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

	var is_large_map: bool = cell_count >= 4000
	var warn_ratio_threshold: float = (
		WARN_RATIO_THRESHOLD_6400 if is_large_map else WARN_RATIO_THRESHOLD_2400
	)
	var warn_ratio_pass: bool = warn_ratio <= warn_ratio_threshold

	var total_p95_pass: bool = (not is_large_map) or total_p95_ms <= TOTAL_P95_THRESHOLD_MS
	var total_p99_pass: bool = (not is_large_map) or total_p99_ms <= TOTAL_P99_THRESHOLD_MS
	if not is_large_map:
		total_p95_pass = total_p95_ms <= TOTAL_P95_THRESHOLD_MS
		total_p99_pass = total_p99_ms <= TOTAL_P99_THRESHOLD_MS

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

	var fail_reasons: Array = []
	if not warn_ratio_pass:
		fail_reasons.append("[9.1] fast tick WARN ratio %.2f%% > threshold %.2f%% (n=%d, warn=%d)" % [
			warn_ratio * 100.0, warn_ratio_threshold * 100.0, n_ticks, warn_count,
		])
	if not total_p95_pass:
		fail_reasons.append("[9.1] total p95 %.2fms > threshold %.2fms" % [
			total_p95_ms, TOTAL_P95_THRESHOLD_MS,
		])
	if not total_p99_pass:
		fail_reasons.append("[9.1] total p99 %.2fms > threshold %.2fms" % [
			total_p99_ms, TOTAL_P99_THRESHOLD_MS,
		])
	if not sus_job_p95_pass and not sus_job_worst.is_empty():
		fail_reasons.append("[9.1] SUS job '%s' p95 %.2fms > threshold %.2fms" % [
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


## 把 evaluate() 的 verdict Dictionary 格式化为人读日志。
static func format_verdict_lines(verdict: Dictionary) -> Array:
	var lines: Array = []
	var overall: bool = bool(verdict.get("overall", false))
	var n_ticks: int = int(verdict.get("n_ticks", 0))
	var cell_count: int = int(verdict.get("cell_count", 0))
	var is_large_map: bool = bool(verdict.get("is_large_map", false))
	var label: String = "PASS" if overall else "FAIL"
	var map_label: String = "6400+ (large)" if is_large_map else "2400 (baseline)"
	lines.append("[DOTS-Total-CPP/perf] verdict = %s   (cells=%s, n=%d ticks)" % [
		label, map_label, n_ticks,
	])
	lines.append("[DOTS-Total-CPP/perf]   warn_ratio = %.2f%% (count=%d, threshold=%.2f%%) → %s" % [
		float(verdict.get("warn_ratio", 0.0)) * 100.0,
		int(verdict.get("warn_count", 0)),
		float(verdict.get("warn_ratio_threshold", 0.0)) * 100.0,
		"PASS" if bool(verdict.get("warn_ratio_pass", false)) else "FAIL",
	])
	lines.append("[DOTS-Total-CPP/perf]   total avg=%.2fms  p50=%.2fms  p95=%.2fms (≤ %.1fms %s)  p99=%.2fms (≤ %.1fms %s)" % [
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
	lines.append("[DOTS-Total-CPP/perf]   SUS jobs (top by p95, threshold=%.1fms; * = exempt):" % SUS_JOB_P95_THRESHOLD_MS)
	var shown: int = 0
	for r in rows:
		if shown >= 6:
			break
		var marker: String = "*" if bool(r.get("exempted", false)) else " "
		var pass_str: String = "PASS" if bool(r.get("pass", true)) else "FAIL"
		lines.append("[DOTS-Total-CPP/perf]     %s %-28s p95=%.2fms %s" % [
			marker,
			String(r.get("job_id", "?")),
			float(r.get("p95_ms", 0.0)),
			pass_str,
		])
		shown += 1
	var nb: Dictionary = verdict.get("next_bottleneck", {})
	if not nb.is_empty():
		lines.append("[DOTS-Total-CPP/perf]   next bottleneck = '%s' p95=%.2fms" % [
			String(nb.get("job_id", "?")),
			float(nb.get("p95_ms", 0.0)),
		])
	var reasons: Array = verdict.get("fail_reasons", [])
	for fr in reasons:
		lines.append("[DOTS-Total-CPP/perf]   FAIL → %s" % String(fr))
	return lines
