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
var frame_budget_ms: float = 2.0

## Strict mode is used by the 1ms simulation profile. It prevents a job from
## consuming multiple slices in one tick unless that job explicitly opts out
## with max_slices_per_tick = 0 and the profile leaves strict mode disabled.
var strict_budget_enabled: bool = false

## Rolling perf gate window for fast-tick simulation budget diagnostics.
var sim_budget_window_size: int = 300
var sim_budget_warn_ms: float = 1.0

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

## Rolling whole-tick samples:
## { total_ms, largest_slice_job, largest_slice_stage, largest_slice_ms }
var _tick_budget_samples: Array = []

## Number of ticks dispatched since reset.
var _tick_counter: int = 0
var _strict_next_job_index: int = 0

## DataCore World 引用（2026-05-11，dots-foundation-and-weather-migration）。
## main.gd 在 World 初始化完成后调用 bind_world(w)；SUS 把它注入到每个已注册
## 与未来注册的 job._world，让 job 可以直接 _world.query()...for_each_index。
## 默认 null —— 与 ClimateProfile.use_data_core=false 一致，job 走 legacy 路径。
var world = null    # DCWorld


# ---------------------------------------------------------------------------
# Phase 1A — sus-cpp-port: native SUS 调度外壳
# ---------------------------------------------------------------------------
## When true, all dispatch / policy / reporting runs through the C++ SusSchedulerExt
## (gdext). Job.run_slice() and Accumulator getter callbacks still cross back into
## GDScript, but the per-job loop / budget / starvation / strict_budget logic is
## entirely native — drops per-tick GD↔native crossings from ~30-40 to ~5-10.
##
## SAME-SOURCE A/B contract: behaviour must be bit-equal vs. the legacy GDScript
## path. Numerical telemetry (elapsed_ms / total_ms) is timing-dependent and only
## required to be within ±20% perf budget.
##
## Wire-up: register_job / unregister_job / bind_world / tick /
## reset_all_progress / report_* all forward to `_ext` when the C++ class is
## available; otherwise transparent fallback to the in-script `_jobs` loop
## (e.g. when running tests outside the gdext build, or when the .dll fails
## to load). The GDScript-side `_jobs` array is always kept in sync so
## legacy callers that introspect the scheduler (e.g. main.gd's WARN
## diagnostics that walk `_jobs`) keep working regardless of branch.
##
## dots-flag-prune-pr1 (2026-05-22): use_gdext_sus_scheduler flag removed —
## native path is the production single path; ext-null fallback is kept as a
## one-sided probe branch (transparent to callers).

## Lazily-instantiated SusSchedulerExt (DCWorldExt sibling class). nil when
## the C++ class is not registered (e.g. editor tests without gdext .dll);
## cached after first ensure call.
var _ext = null


func set_frame_budget_ms(v: float) -> void:
	# Fix #8A (2026-06-15): mobile 上限 4.0ms（log_next.txt 实测 SUS p95=9-15ms 远超
	# 老上限 2.0ms，导致 dynamic_visual_atlas_upload 80% 被饿死）。
	# [2026-06-29] 桌面上限从 2.0 → 16.0：慢机上单 tick sim 5-9ms 远超 2ms，optional
	# 视觉上传（dynamic/enum atlas）每 tick frame_budget_exhausted，只能靠 starvation
	# 零星刷新 → 视觉滞后/卡顿。放宽上限让 ClimateProfile.sim_frame_budget_ms 能真正抬高；
	# 实际值仍由 profile 决定（默认 2.0，earth_like.tres 现设 8.0）。mobile 维持 4.0。
	var max_budget: float = 4.0 if OS.has_feature("mobile") else 16.0
	if OS.has_feature("mobile") and v < max_budget:
		v = max_budget
	frame_budget_ms = clampf(v, 0.25, max_budget)
	if _ext != null:
		_ext.set_frame_budget_ms(frame_budget_ms)


func set_strict_budget_enabled(v: bool) -> void:
	strict_budget_enabled = v
	if _ext != null:
		_ext.set_strict_budget_enabled(strict_budget_enabled)


func set_sim_budget_warn_ms(v: float) -> void:
	var max_budget: float = 4.0 if OS.has_feature("mobile") else 2.0
	if OS.has_feature("mobile") and v < max_budget:
		v = max_budget
	sim_budget_warn_ms = clampf(v, 0.25, max_budget)
	if _ext != null:
		_ext.set_sim_budget_warn_ms(sim_budget_warn_ms)


func _ensure_ext() -> void:
	# Idempotent — called from every register_job / tick / report_* entry.
	# We instantiate lazily so subsystems registered before any tick still
	# get re-registered into the native scheduler via the for-loop below.
	if _ext != null:
		return
	if not ClassDB.class_exists("SusSchedulerExt"):
		# gdext .dll not loaded (e.g. editor tests). Stay on GDScript path.
		return
	_ext = ClassDB.instantiate("SusSchedulerExt")
	if _ext == null:
		push_error("[SUS] failed to instantiate SusSchedulerExt — staying on GDScript path")
		return
	_ext.set_frame_budget_ms(frame_budget_ms)
	_ext.set_strict_budget_enabled(strict_budget_enabled)
	# Fix #11 second pass (2026-06-16) mobile：SUS-cpp report 每 log_interval 打
	# 8-9 行（7 job + 1 budget summary），desktop 30 ticks=0.5s OK，mobile 上每秒
	# ~16 行 SUS-cpp logcat 自身吃 ~80ms/秒。mobile 放到 300 ticks = 5s。
	var effective_log_interval: int = log_interval_ticks
	if OS.has_feature("mobile"):
		effective_log_interval = maxi(log_interval_ticks, 300)
	_ext.set_log_interval_ticks(effective_log_interval)
	_ext.set_sim_budget_window_size(sim_budget_window_size)
	_ext.set_sim_budget_warn_ms(sim_budget_warn_ms)
	if world != null:
		_ext.bind_world(world)
	# Re-register any jobs that were already registered before the ext was
	# spun up (handles the unusual case of flag-flip after registration).
	for j in _jobs:
		_ext.register_job(j, _descriptor_from_job(j))


## Build the policy descriptor Dictionary expected by SusSchedulerExt._build_policy.
## See sus_scheduler_ext.h for the schema. Returns {} for unknown policy types
## (which the C++ side treats as Always — safe default).
func _descriptor_from_policy(p) -> Dictionary:
	if p == null:
		return { "kind": "always" }
	if p is SusPolicy.AlwaysPolicy:
		return { "kind": "always" }
	if p is SusPolicy.StridePolicy:
		return { "kind": "stride", "stride": int(p.stride), "phase": int(p.phase) }
	if p is SusPolicy.AccumulatorPolicy:
		# AccumulatorPolicy fields are name-mangled with leading underscore.
		# C++ accepts the Callable directly via descriptor["getter"/"resetter"].
		return {
			"kind": "accumulator",
			"threshold": float(p.threshold),
			"getter": p._getter,
			"resetter": p._resetter,
		}
	if p is SusPolicy.ContinuousSlicedPolicy:
		# C++ side stores ticks_per_slice in the "stride" slot to keep the
		# PolicyNode struct flat; precompute it here so native gate is one
		# modulo op (matches sus_policy.gd::ContinuousSlicedPolicy.should_run).
		return {
			"kind": "continuous",
			"stride": int(p.ticks_per_slice()),
			"phase": int(p._phase_offset),
		}
	if p is SusPolicy.AndPolicy:
		return {
			"kind": "and",
			"a": _descriptor_from_policy(p.a),
			"b": _descriptor_from_policy(p.b),
		}
	if p is SusPolicy.OrPolicy:
		return {
			"kind": "or",
			"a": _descriptor_from_policy(p.a),
			"b": _descriptor_from_policy(p.b),
		}
	# Unknown subclass → forward as Always so we don't accidentally gate the job
	# off; surface a one-time warning so devs can extend the descriptor builder.
	push_warning("[SUS] unknown policy class %s — descriptor falling back to Always" % p.get_class())
	return { "kind": "always" }


## Build the full job descriptor for SusSchedulerExt.register_job.
func _descriptor_from_job(job: SusJob) -> Dictionary:
	# depends_on is Array[StringName] in GD; pass as plain Array to keep the
	# Variant marshalling simple — C++ side iterates it via Array.size()/[].
	var deps_arr: Array = []
	for d in job.depends_on:
		deps_arr.append(d)
	return {
		"id": job.id,
		"priority": int(job.priority),
		"must_run": bool(job.must_run),
		"use_job_should_run": bool(job.use_job_should_run),
		"starvation_threshold": int(job.starvation_threshold),
		"max_slices_per_tick": int(job.max_slices_per_tick),
		"slice_budget_ms": float(job.slice_budget_ms),
		"depends_on": deps_arr,
		"policy": _descriptor_from_policy(job.policy),
	}


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

## 注入 DataCore World 引用。已注册的 job 立刻 bind；之后 register_job 的也会自动 bind。
func bind_world(w) -> void:
	world = w
	for j in _jobs:
		j.bind_world(w)
	_ensure_ext()
	if _ext != null:
		_ext.bind_world(w)


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
	# Forward to native scheduler. We pass *after* policy default fill-in and
	# bind_world so the C++ side observes the same final job state.
	_ensure_ext()
	if _ext != null:
		_ext.register_job(job, _descriptor_from_job(job))


func unregister_job(job_id: StringName) -> void:
	for i in range(_jobs.size()):
		if _jobs[i].id == job_id:
			_jobs.remove_at(i)
			break
	if _ext != null:
		_ext.unregister_job(job_id)


func refresh_job_descriptor(job_id: StringName) -> void:
	var job := get_job(job_id)
	if job == null or _ext == null:
		return
	_ext.unregister_job(job_id)
	_ext.register_job(job, _descriptor_from_job(job))


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
	# Phase 1A native dispatch: forward the whole tick to SusSchedulerExt. The
	# C++ side runs the priority sort / budget / starvation / depends_on / slice
	# loop / reporting; only Job.run_slice() (and the optional Accumulator
	# getter) cross back into GDScript.
	if _ext != null:
		_ext.tick(ctx)
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
	var optional_jobs_ran: int = 0
	var jobs_skipped: int = 0
	var slices_total_this_tick: int = 0
	var largest_slice_job_tick: StringName = &""
	var largest_slice_stage_tick: String = ""
	var largest_slice_substage_tick: String = ""
	var largest_slice_path_tick: String = ""
	var largest_slice_ms_tick: float = 0.0
	var largest_slice_work_done_tick: int = 0
	var largest_slice_processed_cells_tick: int = 0
	var largest_slice_processed_pixels_tick: int = 0
	var largest_slice_processed_indices_tick: int = 0
	var largest_slice_cursor_start_tick: int = -1
	var largest_slice_cursor_end_tick: int = -1
	var largest_slice_fallback_path_tick: String = ""

	var ordered_jobs: Array[SusJob] = _jobs
	if strict_budget_enabled and _jobs.size() > 1:
		ordered_jobs = []
		var start_idx: int = posmod(_strict_next_job_index, _jobs.size())
		for offset in range(_jobs.size()):
			ordered_jobs.append(_jobs[(start_idx + offset) % _jobs.size()])
	var sim_total_ms_tick: float = 0.0

	for job in ordered_jobs:
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
		# ocean_currents / visual upload 这类低优先级 Job 长期饿死。
		var elapsed_us_now: int = Time.get_ticks_usec() - tick_start_us
		var starving: bool = not strict_budget_enabled \
				and job.starvation_threshold > 0 \
				and job._starvation_count >= job.starvation_threshold
		if strict_budget_enabled and optional_jobs_ran > 0 and not bool(job.must_run):
			report["skipped_reason"] = "strict_budget_one_job"
			_last_report[job.id] = report
			_record_skipped(job.id, "strict_budget_one_job")
			job._starvation_count += 1
			jobs_skipped += 1
			continue
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
			var dep_job: SusJob = get_job(dep_id)
			if dep_job != null and bool(dep_job._in_flight):
				blocked_by = dep_id
				break
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
		var last_slice_stage: String = ""
		var last_slice_substage: String = ""
		var last_slice_path: String = ""
		var last_slice_work_done: int = 0
		var last_slice_processed_cells: int = 0
		var last_slice_processed_pixels: int = 0
		var last_slice_processed_indices: int = 0
		var last_slice_cursor_start: int = -1
		var last_slice_cursor_end: int = -1
		var last_slice_fallback_path: String = ""
		job._in_flight = true

		while true:
			# Check global budget before *starting* another slice.
			# Daily-sim perf bugfix：must_run Job 不被 frame_budget 中途打断，
			# 避免 weather 推进半截留下不一致状态。
			# Starvation 防护：饥饿 Job 只允许跑 1 slice 让步（确保推进 + 不雪崩 budget）。
			elapsed_us_now = Time.get_ticks_usec() - tick_start_us
			if slices_run > 0 and elapsed_us_now >= budget_us and not bool(job.must_run):
				break
			var max_slices_this_tick: int = int(job.max_slices_per_tick)
			if strict_budget_enabled and max_slices_this_tick <= 0:
				max_slices_this_tick = 1
			if max_slices_this_tick > 0 and slices_run >= max_slices_this_tick:
				break
			if starving and slices_run >= 1:
				break

			var slice_start_us: int = Time.get_ticks_usec()
			var slice_result: Dictionary = job.run_slice(ctx)
			var slice_actual_ms: float = (Time.get_ticks_usec() - slice_start_us) / 1000.0
			slices_run += 1

			# Defensive read — Job impls should always return a Dictionary,
			# but if a bug ships we don't want SUS to crash the whole loop.
			if typeof(slice_result) != TYPE_DICTIONARY:
				push_error("[SUS] job %s.run_slice did not return Dictionary" % str(job.id))
				done = true
				break

			var slice_reported_ms: float = float(slice_result.get("elapsed_ms", slice_actual_ms))
			var slice_ms: float = maxf(slice_actual_ms, slice_reported_ms)
			last_slice_stage = _slice_stage_name(slice_result)
			last_slice_substage = _slice_substage_name(slice_result)
			last_slice_path = str(slice_result.get("path", ""))
			last_slice_work_done = int(slice_result.get("work_done", 0))
			last_slice_processed_cells = int(slice_result.get("processed_cells", 0))
			last_slice_processed_pixels = int(slice_result.get("processed_pixels", 0))
			last_slice_processed_indices = int(slice_result.get("processed_indices", 0))
			if last_slice_processed_cells <= 0 and _slice_stage_looks_cell_based(last_slice_stage):
				last_slice_processed_cells = last_slice_work_done
			if last_slice_processed_pixels <= 0 and _slice_stage_looks_pixel_based(last_slice_stage):
				last_slice_processed_pixels = last_slice_work_done
			if last_slice_processed_indices <= 0 and last_slice_processed_cells <= 0 and last_slice_processed_pixels <= 0:
				last_slice_processed_indices = last_slice_work_done
			last_slice_cursor_start = int(slice_result.get("cursor_start", slice_result.get("start_idx", -1)))
			last_slice_cursor_end = int(slice_result.get("cursor_end", slice_result.get("end_idx", -1)))
			last_slice_fallback_path = str(slice_result.get("fallback_path", ""))
			if last_slice_fallback_path == "" and bool(slice_result.get("fallback", false)):
				last_slice_fallback_path = last_slice_path
			if not _is_upload_job(job.id) and slice_ms > largest_slice_ms_tick:
				largest_slice_ms_tick = slice_ms
				largest_slice_job_tick = job.id
				largest_slice_stage_tick = last_slice_stage
				largest_slice_substage_tick = last_slice_substage
				largest_slice_path_tick = last_slice_path
				largest_slice_work_done_tick = last_slice_work_done
				largest_slice_processed_cells_tick = last_slice_processed_cells
				largest_slice_processed_pixels_tick = last_slice_processed_pixels
				largest_slice_processed_indices_tick = last_slice_processed_indices
				largest_slice_cursor_start_tick = last_slice_cursor_start
				largest_slice_cursor_end_tick = last_slice_cursor_end
				largest_slice_fallback_path_tick = last_slice_fallback_path

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
		report["stage"] = last_slice_stage
		report["substage"] = last_slice_substage
		report["path"] = last_slice_path
		report["work_done"] = work_done_total
		report["last_slice_work_done"] = last_slice_work_done
		report["last_slice_processed_cells"] = last_slice_processed_cells
		report["last_slice_processed_pixels"] = last_slice_processed_pixels
		report["last_slice_processed_indices"] = last_slice_processed_indices
		report["last_slice_cursor_start"] = last_slice_cursor_start
		report["last_slice_cursor_end"] = last_slice_cursor_end
		report["last_slice_fallback_path"] = last_slice_fallback_path
		_last_report[job.id] = report
		_record_stats(job.id, job_elapsed_ms, slices_run)
		if not _is_upload_job(job.id):
			sim_total_ms_tick += job_elapsed_ms

		jobs_ran += 1
		if not bool(job.must_run):
			optional_jobs_ran += 1
		if strict_budget_enabled and not bool(job.must_run):
			var original_idx: int = _jobs.find(job)
			if original_idx >= 0:
				_strict_next_job_index = (original_idx + 1) % maxi(1, _jobs.size())
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
	_record_tick_budget_sample(sim_total_ms_tick, largest_slice_job_tick, largest_slice_stage_tick,
		largest_slice_substage_tick, largest_slice_path_tick, largest_slice_ms_tick,
		largest_slice_work_done_tick, largest_slice_processed_cells_tick,
		largest_slice_processed_pixels_tick, largest_slice_processed_indices_tick,
		largest_slice_cursor_start_tick, largest_slice_cursor_end_tick,
		largest_slice_fallback_path_tick)
	var budget_window: Dictionary = _sim_budget_window_dict()
	_last_tick_summary = {
		"tick_index": ctx.tick_index,
		"source": ctx.source,
		"total_ms": total_ms,
		"jobs_ran": jobs_ran,
		"jobs_skipped": jobs_skipped,
		"slices_total": slices_total_this_tick,
		"largest_slice_job": largest_slice_job_tick,
		"largest_slice_stage": largest_slice_stage_tick,
		"largest_slice_substage": largest_slice_substage_tick,
		"largest_slice_path": largest_slice_path_tick,
		"largest_slice_ms": largest_slice_ms_tick,
		"largest_slice_work_done": largest_slice_work_done_tick,
		"largest_slice_processed_cells": largest_slice_processed_cells_tick,
		"largest_slice_processed_pixels": largest_slice_processed_pixels_tick,
		"largest_slice_processed_indices": largest_slice_processed_indices_tick,
		"largest_slice_cursor_start": largest_slice_cursor_start_tick,
		"largest_slice_cursor_end": largest_slice_cursor_end_tick,
		"largest_slice_fallback_path": largest_slice_fallback_path_tick,
		"largest_slice_processed_per_ms": _processed_per_ms(largest_slice_work_done_tick,
			largest_slice_processed_cells_tick, largest_slice_processed_pixels_tick,
			largest_slice_processed_indices_tick, largest_slice_ms_tick),
		"sus_sim_avg_300": float(budget_window.get("sus_sim_avg_300", 0.0)),
		"sim_frame_budget_ms": frame_budget_ms,
		"sim_slice_budget_ms": _max_registered_slice_budget_ms(false),
		"sim_upload_slice_budget_ms": _max_registered_slice_budget_ms(true),
		"sim_strict_budget_enabled": strict_budget_enabled,
		"sim_budget_warn_ms": sim_budget_warn_ms,
		"economy_reserved_budget_ms": maxf(0.0, 16.666 - frame_budget_ms),
		"sus_sim_p95_300": float(budget_window.get("sus_sim_p95_300", 0.0)),
		"sus_sim_max_300": float(budget_window.get("sus_sim_max_300", 0.0)),
		"over_1ms_count_300": int(budget_window.get("over_1ms_count_300", 0)),
	}

	# Fix #11 second pass (2026-06-16) mobile：同 _ext.set_log_interval_ticks 处的 effective_log_interval。
	var effective_log_interval: int = log_interval_ticks
	if OS.has_feature("mobile"):
		effective_log_interval = maxi(log_interval_ticks, 300)
	if effective_log_interval > 0 and (_tick_counter % effective_log_interval) == 0:
		_emit_periodic_log()


# ---------------------------------------------------------------------------
# Reset
# ---------------------------------------------------------------------------

func reset_all_progress() -> void:
	for j in _jobs:
		j.reset_progress()
	_last_report.clear()
	_last_tick_summary.clear()
	_tick_budget_samples.clear()
	_stats.clear()
	_tick_counter = 0
	_strict_next_job_index = 0
	if _ext != null:
		_ext.reset_all_progress()


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

func report_last_tick() -> Dictionary:
	if _ext != null:
		return _ext.report_last_tick()
	return _last_report.duplicate(true)


## Perf instrumentation: 上一 tick 的整体摘要（耗时 / 跑/跳数 / 切片总数）。
## main.gd 用它来：
##   1. 把 SUS 那段耗时与 fast tick 总耗时对比
##   2. 触发 > 12ms WARN 时附带打印
func report_last_tick_summary() -> Dictionary:
	if _ext != null:
		return _ext.report_last_tick_summary()
	return _last_tick_summary.duplicate(true)


func report_sim_budget_window() -> Dictionary:
	if _ext != null:
		return _ext.report_sim_budget_window()
	return _sim_budget_window_dict().duplicate(true)


## Perf instrumentation: 滚动窗口内的 skipped_reason 累计 + max_ms。
## 用于诊断"某 Job 长期被节流"等慢性问题。
func report_skipped_summary() -> Dictionary:
	if _ext != null:
		return _ext.report_skipped_summary()
	var out: Dictionary = {}
	for job_id in _stats.keys():
		var s: Dictionary = _stats[job_id]
		out[job_id] = {
			"skipped": (s.get("skipped", {}) as Dictionary).duplicate(),
			"max_ms": float(s.get("max_ms", 0.0)),
		}
	return out


## DOTS-Final-Push 任务 10：返回 `_stats` 全表的深拷贝，供
## DCDotsFinalPushPerfVerdict.evaluate() 使用。schema 与 _record_stats 一致：
##   { job_id -> { samples: Array[float], slices_total: int,
##                 skipped: Dictionary, max_ms: float } }
## 注意：`samples` 在每次 log_interval_ticks 被清空（line 362），所以读取窗口
## 由 SUS scheduler 的滚动周期决定（默认 30 tick）。caller 若要 200 tick 长
## 窗口，应在 main.gd 自行累积 fast tick total_ms 数组，本表仅供 SUS Job
## p95 比对（30 tick 滚动 p95 已足以判定稳态门槛）。
func report_job_stats() -> Dictionary:
	if _ext != null:
		return _ext.report_job_stats()
	var out: Dictionary = {}
	for job_id in _stats.keys():
		var s: Dictionary = _stats[job_id]
		var samples: Array = s.get("samples", [])
		out[job_id] = {
			"samples": samples.duplicate(),
			"slices_total": int(s.get("slices_total", 0)),
			"skipped": (s.get("skipped", {}) as Dictionary).duplicate(),
			"max_ms": float(s.get("max_ms", 0.0)),
		}
	return out


func _record_tick_budget_sample(total_ms: float, largest_job: StringName, largest_stage: String,
		largest_substage: String, largest_path: String, largest_ms: float,
		largest_work_done: int = 0, largest_processed_cells: int = 0,
		largest_processed_pixels: int = 0, largest_processed_indices: int = 0,
		largest_cursor_start: int = -1, largest_cursor_end: int = -1,
		largest_fallback_path: String = "") -> void:
	_tick_budget_samples.append({
		"total_ms": total_ms,
		"largest_slice_job": largest_job,
		"largest_slice_stage": largest_stage,
		"largest_slice_substage": largest_substage,
		"largest_slice_path": largest_path,
		"largest_slice_ms": largest_ms,
		"largest_slice_work_done": largest_work_done,
		"largest_slice_processed_cells": largest_processed_cells,
		"largest_slice_processed_pixels": largest_processed_pixels,
		"largest_slice_processed_indices": largest_processed_indices,
		"largest_slice_cursor_start": largest_cursor_start,
		"largest_slice_cursor_end": largest_cursor_end,
		"largest_slice_fallback_path": largest_fallback_path,
	})
	while _tick_budget_samples.size() > maxi(1, sim_budget_window_size):
		_tick_budget_samples.remove_at(0)


func _sim_budget_window_dict() -> Dictionary:
	var sample_count: int = _tick_budget_samples.size()
	if sample_count <= 0:
		return {
			"sus_sim_p95_300": 0.0,
			"sus_sim_max_300": 0.0,
			"over_1ms_count_300": 0,
			"largest_slice_job": &"",
			"largest_slice_stage": "",
			"largest_slice_substage": "",
			"largest_slice_path": "",
			"largest_slice_ms": 0.0,
			"largest_slice_work_done": 0,
			"largest_slice_processed_cells": 0,
			"largest_slice_processed_pixels": 0,
			"largest_slice_processed_indices": 0,
			"largest_slice_cursor_start": -1,
			"largest_slice_cursor_end": -1,
			"largest_slice_fallback_path": "",
			"largest_slice_processed_per_ms": 0.0,
			"sus_sim_avg_300": 0.0,
			"sim_frame_budget_ms": frame_budget_ms,
			"sim_slice_budget_ms": _max_registered_slice_budget_ms(false),
			"sim_upload_slice_budget_ms": _max_registered_slice_budget_ms(true),
			"sim_strict_budget_enabled": strict_budget_enabled,
			"sim_budget_warn_ms": sim_budget_warn_ms,
			"economy_reserved_budget_ms": maxf(0.0, 16.666 - frame_budget_ms),
			"sample_count": 0,
		}
	var totals: Array = []
	var sum_total_ms: float = 0.0
	var max_total_ms: float = 0.0
	var over_count: int = 0
	var largest_job: StringName = &""
	var largest_stage: String = ""
	var largest_substage: String = ""
	var largest_path: String = ""
	var largest_ms: float = 0.0
	var largest_work_done: int = 0
	var largest_processed_cells: int = 0
	var largest_processed_pixels: int = 0
	var largest_processed_indices: int = 0
	var largest_cursor_start: int = -1
	var largest_cursor_end: int = -1
	var largest_fallback_path: String = ""
	for sample in _tick_budget_samples:
		var d: Dictionary = sample
		var total_ms: float = float(d.get("total_ms", 0.0))
		totals.append(total_ms)
		sum_total_ms += total_ms
		max_total_ms = maxf(max_total_ms, total_ms)
		if total_ms > sim_budget_warn_ms:
			over_count += 1
		var slice_ms: float = float(d.get("largest_slice_ms", 0.0))
		if slice_ms > largest_ms:
			largest_ms = slice_ms
			largest_job = StringName(str(d.get("largest_slice_job", "")))
			largest_stage = str(d.get("largest_slice_stage", ""))
			largest_substage = str(d.get("largest_slice_substage", ""))
			largest_path = str(d.get("largest_slice_path", ""))
			largest_work_done = int(d.get("largest_slice_work_done", 0))
			largest_processed_cells = int(d.get("largest_slice_processed_cells", 0))
			largest_processed_pixels = int(d.get("largest_slice_processed_pixels", 0))
			largest_processed_indices = int(d.get("largest_slice_processed_indices", 0))
			largest_cursor_start = int(d.get("largest_slice_cursor_start", -1))
			largest_cursor_end = int(d.get("largest_slice_cursor_end", -1))
			largest_fallback_path = str(d.get("largest_slice_fallback_path", ""))
	totals.sort()
	var p95_idx: int = clampi(int(ceil(totals.size() * 0.95)) - 1, 0, totals.size() - 1)
	var avg_total_ms: float = sum_total_ms / float(maxi(1, sample_count))
	var processed_per_ms: float = _processed_per_ms(largest_work_done, largest_processed_cells,
		largest_processed_pixels, largest_processed_indices, largest_ms)
	return {
		"sus_sim_avg_300": avg_total_ms,
		"sus_sim_p95_300": float(totals[p95_idx]),
		"sus_sim_max_300": max_total_ms,
		"over_1ms_count_300": over_count,
		"largest_slice_job": largest_job,
		"largest_slice_stage": largest_stage,
		"largest_slice_substage": largest_substage,
		"largest_slice_path": largest_path,
		"largest_slice_ms": largest_ms,
		"largest_slice_work_done": largest_work_done,
		"largest_slice_processed_cells": largest_processed_cells,
		"largest_slice_processed_pixels": largest_processed_pixels,
		"largest_slice_processed_indices": largest_processed_indices,
		"largest_slice_cursor_start": largest_cursor_start,
		"largest_slice_cursor_end": largest_cursor_end,
		"largest_slice_fallback_path": largest_fallback_path,
		"largest_slice_processed_per_ms": processed_per_ms,
		"sim_frame_budget_ms": frame_budget_ms,
		"sim_slice_budget_ms": _max_registered_slice_budget_ms(false),
		"sim_upload_slice_budget_ms": _max_registered_slice_budget_ms(true),
		"sim_strict_budget_enabled": strict_budget_enabled,
		"sim_budget_warn_ms": sim_budget_warn_ms,
		"economy_reserved_budget_ms": maxf(0.0, 16.666 - frame_budget_ms),
		"sample_count": sample_count,
	}


func _slice_stage_name(slice_result: Dictionary) -> String:
	for key in ["stage_name", "stage", "pass", "axis"]:
		if slice_result.has(key):
			return str(slice_result[key])
	return ""


func _slice_substage_name(slice_result: Dictionary) -> String:
	for key in ["substage", "micro_stage", "stage_detail"]:
		if slice_result.has(key):
			return str(slice_result[key])
	return ""


func _is_upload_job(job_id: StringName) -> bool:
	return job_id == &"enum_atlas_upload" \
		or job_id == &"dynamic_visual_atlas_upload"


func _slice_stage_looks_cell_based(stage: String) -> bool:
	return stage.begins_with("weather_") or stage.begins_with("pass_") \
		or stage == "ocean_water" or stage == "ocean_land" \
		or stage == "sea_ice" or stage == "transp"


func _slice_stage_looks_pixel_based(stage: String) -> bool:
	return stage.find("pixel") >= 0 or stage.find("raster") >= 0


func _processed_per_ms(work_done: int, processed_cells: int, processed_pixels: int,
		processed_indices: int, elapsed_ms: float) -> float:
	if elapsed_ms <= 0.0:
		return 0.0
	var processed: int = max(work_done, max(processed_cells, max(processed_pixels, processed_indices)))
	return float(processed) / elapsed_ms


func _max_registered_slice_budget_ms(upload_jobs: bool) -> float:
	var out: float = 0.0
	for j in _jobs:
		if _is_upload_job(j.id) == upload_jobs:
			out = maxf(out, float(j.slice_budget_ms))
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
	var bw: Dictionary = _sim_budget_window_dict()
	if int(bw.get("sample_count", 0)) > 0:
		print("[SUS] budget last %d ticks: total_p95=%.2fms max=%.2fms over_1ms=%d largest=%s/%s/%s path=%s %.2fms"
			% [int(bw.get("sample_count", 0)),
				float(bw.get("sus_sim_p95_300", 0.0)),
				float(bw.get("sus_sim_max_300", 0.0)),
				int(bw.get("over_1ms_count_300", 0)),
				str(bw.get("largest_slice_job", "")),
				str(bw.get("largest_slice_stage", "")),
				str(bw.get("largest_slice_substage", "")),
				str(bw.get("largest_slice_path", "")),
				float(bw.get("largest_slice_ms", 0.0))])
	# DataCore 状态尾巴一行（dots-foundation-and-weather-migration 任务 10）。
	# 仅在已 bind World 时打印；未 bind 时（默认 legacy）保持静默以减少 log 噪声。
	if world != null:
		var bound: bool = world.has_method("is_bound") and world.is_bound()
		if bound:
			var ent_n: int = int(world.entity_count()) if world.has_method("entity_count") else 0
			var comp_n: int = int(world.component_count()) if world.has_method("component_count") else 0
			var pool_n: int = int(world.pool_count()) if world.has_method("pool_count") else 0
			print("[SUS] world: bound=true entities=%d components=%d pools=%d" % [ent_n, comp_n, pool_n])
