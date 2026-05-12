extends RefCounted
class_name SlicedUpdateScheduler

## Sliced Update Scheduler (SUS) — central orchestrator for periodic
## simulation jobs.
##
## Lifecycle:
##   1. main.gd / MapGenerator creates an instance (RefCounted; no scene tree
##      attachment needed).
##   2. Each subsystem registers its SusJob via register_job().
##   3. main.gd._on_day_changed (or _on_season_changed / _on_year_changed) calls
##      tick(ctx) once per dispatch, passing a freshly-built SusTickContext.
##   4. SUS sorts jobs by priority, gates by policy.should_run() and depends_on,
##      then drives run_slice() repeatedly until either:
##        a. The job reports done = true.
##        b. frame_budget_ms is exhausted (next slices roll over to next tick).
##
## Thread model: single-threaded. All work runs on the main thread; SUS only
## redistributes work *across ticks*, never *across threads*.

## Soft total budget per tick (ms). When exceeded, SUS stops *starting* new
## jobs but does not interrupt the slice currently in flight (avoids leaving
## half-baked state).
var frame_budget_ms: float = 12.0

## Print a `[SUS] last N ticks: <job_id> avg=Xms p95=Yms slices=Z` line every
## this many ticks. 0 disables periodic logging.
var log_interval_ticks: int = 30

## Internal job registry — kept sorted by priority ascending after each
## register_job().
var _jobs: Array[SusJob] = []

## Last-tick report keyed by job id → { elapsed_ms, slices_run, progress_ratio,
## skipped_reason }.
var _last_report: Dictionary = {}

## Rolling per-job stats for periodic logging.
##   _stats[id] = { samples: Array[float], slices_total: int,
##                  skipped: { policy_gated, dep_pending, frame_budget_exhausted, ... },
##                  max_ms: float }
## Perf instrumentation (daily-sim breakdown):
##   - samples 用于 avg / p95
##   - max_ms  跟踪窗口内最大单次耗时（"瞬时峰值"）
##   - skipped 按原因聚合"跳过次数"，便于看出某 Job 到底是被节流还是真没跑
var _stats: Dictionary = {}

## Whole-tick timing of the last tick() call. Filled at the end of tick();
## consumed by main.gd 的 fast-tick 段拆打点 / WARN 触发详细打印。
##   { tick_index, source, total_ms, jobs_ran, jobs_skipped, slices_total }
var _last_tick_summary: Dictionary = {}

## Number of ticks dispatched since reset.
var _tick_counter: int = 0

## DataCore World 引用（2026-05-11，dots-foundation-and-weather-migration）。
## main.gd 在 World 初始化完成后调用 bind_world(w)；SUS 把它注入到每个已注册
## 与未来注册的 job._world，让 job 可以直接 _world.query()...for_each_index。
## 默认 null —— 与 ClimateProfile.use_data_core=false 一致，job 走 legacy 路径。
var world = null    # DCWorld


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

## 注入 DataCore World 引用。已注册的 job 立刻 bind；之后 register_job 的也会自动 bind。
func bind_world(w) -> void:
	world = w
	for j in _jobs:
		j.bind_world(w)


func register_job(job: SusJob) -> void:
	if job == null:
		push_error("[SUS] register_job: nil job")
		return
	if job.id == &"":
		push_error("[SUS] register_job: job has empty id")
		return
	for existing in _jobs:
		if existing.id == job.id:
			push_error("[SUS] register_job: duplicate id %s" % str(job.id))
			return
	if job.policy == null:
		job.policy = SusPolicy.AlwaysPolicy.new()
	_jobs.append(job)
	_jobs.sort_custom(func(a, b): return a.priority < b.priority)
	if world != null:
		job.bind_world(world)


func unregister_job(job_id: StringName) -> void:
	for i in range(_jobs.size()):
		if _jobs[i].id == job_id:
			_jobs.remove_at(i)
			return


func get_job(job_id: StringName) -> SusJob:
	for j in _jobs:
		if j.id == job_id:
			return j
	return null


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

func tick(ctx: SusTickContext) -> void:
	if ctx == null:
		push_error("[SUS] tick: nil context")
		return
	_tick_counter += 1
	_last_report.clear()

	var tick_start_us: int = Time.get_ticks_usec()
	var budget_us: int = int(frame_budget_ms * 1000.0)

	# Track which jobs finished this tick (for depends_on resolution within
	# the tick) and which jobs still have slices pending across ticks.
	var completed_this_tick: Dictionary = {}
	var in_flight_after_tick: Dictionary = {}
	# Perf instrumentation: 本 tick 跨所有 Job 的总切片数 / 实际跑了 / 被跳过的 Job 数。
	var jobs_ran: int = 0
	var jobs_skipped: int = 0
	var slices_total_this_tick: int = 0

	for job in _jobs:
		var report: Dictionary = {
			"id": job.id,
			"elapsed_ms": 0.0,
			"slices_run": 0,
			"progress_ratio": 0.0,
			"skipped_reason": "",
			# Perf instrumentation: 让上层日志能直接看到 tick 上下文，不必再传 ctx
			"tick_index": ctx.tick_index,
			"source": ctx.source,
		}

		# Budget exhausted: skip starting any new job (already-started slices
		# in earlier loop iterations have already finished this tick — we don't
		# preempt mid-slice).
		# Daily-sim perf bugfix：must_run=true 的 Job 绕过此守卫——避免
		# refresh_climate_daily 单 Job 超预算 → weather/ocean_currents 被全部
		# frame_budget_exhausted 掉 → 天气/洋流冻结的硬故障。
		# Starvation 防护（2026-05-11）：连续被 frame_budget_exhausted 跳过
		# starvation_threshold 次的 Job，本 tick 强制绕过 budget 跑一次，避免
		# sea_ice_atlas_upload / ocean_currents 这类低优先级 Job 长期饿死。
		var elapsed_us_now: int = Time.get_ticks_usec() - tick_start_us
		var starving: bool = job.starvation_threshold > 0 \
				and job._starvation_count >= job.starvation_threshold
		if elapsed_us_now >= budget_us and not bool(job.must_run) and not starving:
			report["skipped_reason"] = "frame_budget_exhausted"
			_last_report[job.id] = report
			_record_skipped(job.id, "frame_budget_exhausted")
			job._starvation_count += 1
			jobs_skipped += 1
			continue

		# Policy gate.
		if not job.should_run(ctx):
			report["skipped_reason"] = "policy_gated"
			_last_report[job.id] = report
			_record_skipped(job.id, "policy_gated")
			jobs_skipped += 1
			continue

		# Dependency gate: any unfinished dep blocks this tick.
		var blocked_by: StringName = &""
		for dep_id in job.depends_on:
			if in_flight_after_tick.has(dep_id) and bool(in_flight_after_tick[dep_id]):
				blocked_by = dep_id
				break
		if blocked_by != &"":
			report["skipped_reason"] = "dep_pending:" + str(blocked_by)
			_last_report[job.id] = report
			_record_skipped(job.id, "dep_pending")
			jobs_skipped += 1
			continue

		# Drive run_slice() until done or local/global budget hits.
		var job_start_us: int = Time.get_ticks_usec()
		var slice_budget_us: int = int(job.slice_budget_ms * 1000.0)
		var done: bool = false
		var slices_run: int = 0
		var work_done_total: int = 0
		var last_progress_ratio: float = 0.0
		job._in_flight = true

		while true:
			# Check global budget before *starting* another slice.
			# Daily-sim perf bugfix：must_run Job 不被 frame_budget 中途打断，
			# 避免 weather 推进半截留下不一致状态。
			# Starvation 防护：饥饿 Job 只允许跑 1 slice 让步（确保推进 + 不雪崩 budget）。
			elapsed_us_now = Time.get_ticks_usec() - tick_start_us
			if slices_run > 0 and elapsed_us_now >= budget_us and not bool(job.must_run):
				break
			if starving and slices_run >= 1:
				break

			var slice_result: Dictionary = job.run_slice(ctx)
			slices_run += 1

			# Defensive read — Job impls should always return a Dictionary,
			# but if a bug ships we don't want SUS to crash the whole loop.
			if typeof(slice_result) != TYPE_DICTIONARY:
				push_error("[SUS] job %s.run_slice did not return Dictionary" % str(job.id))
				done = true
				break

			done = bool(slice_result.get("done", true))
			work_done_total += int(slice_result.get("work_done", 0))
			last_progress_ratio = float(slice_result.get("progress_ratio", 0.0))
			if done:
				break

			# Local slice budget cutoff: one slice already exceeded its quota,
			# yield back to other jobs.
			var job_elapsed_us: int = Time.get_ticks_usec() - job_start_us
			if job_elapsed_us >= slice_budget_us:
				break

		var job_elapsed_ms: float = (Time.get_ticks_usec() - job_start_us) / 1000.0
		report["elapsed_ms"] = job_elapsed_ms
		report["slices_run"] = slices_run
		report["progress_ratio"] = last_progress_ratio
		_last_report[job.id] = report
		_record_stats(job.id, job_elapsed_ms, slices_run)

		jobs_ran += 1
		slices_total_this_tick += slices_run
		# Starvation 防护：实际跑过即清零计数；下一次还会从 0 开始累计。
		job._starvation_count = 0

		if done:
			job._in_flight = false
			completed_this_tick[job.id] = true
			in_flight_after_tick[job.id] = false
			if job.policy != null:
				job.policy.on_job_completed(job, ctx)
		else:
			in_flight_after_tick[job.id] = true

	# Perf instrumentation: 单次 tick 摘要，便于 main.gd 取来打印或触发 WARN。
	var total_ms: float = (Time.get_ticks_usec() - tick_start_us) / 1000.0
	_last_tick_summary = {
		"tick_index": ctx.tick_index,
		"source": ctx.source,
		"total_ms": total_ms,
		"jobs_ran": jobs_ran,
		"jobs_skipped": jobs_skipped,
		"slices_total": slices_total_this_tick,
	}

	if log_interval_ticks > 0 and (_tick_counter % log_interval_ticks) == 0:
		_emit_periodic_log()


# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------

func reset_all_progress() -> void:
	for j in _jobs:
		j.reset_progress()
	_last_report.clear()
	_last_tick_summary.clear()
	_stats.clear()
	_tick_counter = 0


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

func report_last_tick() -> Dictionary:
	return _last_report.duplicate(true)


## Perf instrumentation: 上一 tick 的整体摘要（耗时 / 跑/跳数 / 切片总数）。
## main.gd 用它来：
##   1. 把 SUS 那段耗时与 fast tick 总耗时对比
##   2. 触发 > 12ms WARN 时附带打印
func report_last_tick_summary() -> Dictionary:
	return _last_tick_summary.duplicate(true)


## Perf instrumentation: 滚动窗口内的 skipped_reason 累计 + max_ms。
## 用于诊断"某 Job 长期被节流"等慢性问题。
func report_skipped_summary() -> Dictionary:
	var out: Dictionary = {}
	for job_id in _stats.keys():
		var s: Dictionary = _stats[job_id]
		out[job_id] = {
			"skipped": (s.get("skipped", {}) as Dictionary).duplicate(),
			"max_ms": float(s.get("max_ms", 0.0)),
		}
	return out


func _record_stats(job_id: StringName, elapsed_ms: float, slices_run: int) -> void:
	if not _stats.has(job_id):
		_stats[job_id] = {
			"samples": [],
			"slices_total": 0,
			"skipped": {},
			"max_ms": 0.0,
		}
	var s: Dictionary = _stats[job_id]
	(s["samples"] as Array).append(elapsed_ms)
	s["slices_total"] = int(s["slices_total"]) + slices_run
	if elapsed_ms > float(s.get("max_ms", 0.0)):
		s["max_ms"] = elapsed_ms


func _record_skipped(job_id: StringName, reason: String) -> void:
	if not _stats.has(job_id):
		_stats[job_id] = {
			"samples": [],
			"slices_total": 0,
			"skipped": {},
			"max_ms": 0.0,
		}
	var s: Dictionary = _stats[job_id]
	var skipped: Dictionary = s.get("skipped", {})
	skipped[reason] = int(skipped.get(reason, 0)) + 1
	s["skipped"] = skipped


func _emit_periodic_log() -> void:
	for job_id in _stats.keys():
		var s: Dictionary = _stats[job_id]
		var samples: Array = s["samples"]
		if samples.is_empty() and (s.get("skipped", {}) as Dictionary).is_empty():
			continue
		var avg_ms: float = 0.0
		var p95_ms: float = 0.0
		var max_ms: float = float(s.get("max_ms", 0.0))
		if not samples.is_empty():
			var sum_ms: float = 0.0
			for v in samples:
				sum_ms += float(v)
			avg_ms = sum_ms / float(samples.size())
			var sorted: Array = samples.duplicate()
			sorted.sort()
			var p95_idx: int = clampi(int(ceil(sorted.size() * 0.95)) - 1, 0, sorted.size() - 1)
			p95_ms = float(sorted[p95_idx])
		# Perf instrumentation: 把 skipped 各原因压进同一行，看个分布
		var skipped: Dictionary = s.get("skipped", {})
		var skipped_str: String = ""
		if not skipped.is_empty():
			var parts: PackedStringArray = []
			for k in skipped.keys():
				parts.append("%s=%d" % [str(k), int(skipped[k])])
			skipped_str = " skipped[" + ",".join(parts) + "]"
		print("[SUS] last %d ticks: %s ran=%d avg=%.2fms p95=%.2fms max=%.2fms slices=%d%s"
			% [log_interval_ticks, str(job_id), samples.size(), avg_ms, p95_ms, max_ms,
				int(s["slices_total"]), skipped_str])
		# Reset rolling window.
		s["samples"] = []
		s["slices_total"] = 0
		s["skipped"] = {}
		s["max_ms"] = 0.0
	# DataCore 状态尾巴一行（dots-foundation-and-weather-migration 任务 10）。
	# 仅在已 bind World 时打印；未 bind 时（默认 legacy）保持静默以减少 log 噪声。
	if world != null:
		var bound: bool = world.has_method("is_bound") and world.is_bound()
		if bound:
			var ent_n: int = int(world.entity_count()) if world.has_method("entity_count") else 0
			var comp_n: int = int(world.component_count()) if world.has_method("component_count") else 0
			var pool_n: int = int(world.pool_count()) if world.has_method("pool_count") else 0
			print("[SUS] world: bound=true entities=%d components=%d pools=%d" % [ent_n, comp_n, pool_n])