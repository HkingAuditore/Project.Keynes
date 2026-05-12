@tool
extends RefCounted

# ═══════════════════════════════════════════════════════════════════
# DCEcsJob — production-path ECS job record
# ═══════════════════════════════════════════════════════════════════
#
# Promoted from `tmp/demo_ecs_job.gd` (DOTS-A2 sandbox). Used by# `DCEcsScheduler` to express one chunk of work that consumes/produces
# DCWorld component slots.
#
# Fields:
#   * `name`             — debug-only label (StringName)
#   * `reads` / `writes` — comp_id arrays (declarative). Scheduler builds
#                          "writes-before-reads" + "writes-before-writes
#                          (registration order)" edges from these.
#   * `archetype_filter` — optional logical filter (-1 = no filter).
#                          Job runners may pass it to C++ kernels via
#                          `run_*_archetyped(target_archetype)`.
#   * `run_callable`     — Callable(ctx: Dictionary, job: DCEcsJob) -> void.
#                          The actual work; `ctx` is a per-tick bag forwarded
#                          verbatim by the scheduler.
#   * `params`           — job-private kv bag (scheduler does not introspect).
#
# Contract:
#   - `reads` / `writes` MUST be Array[int] of comp_ids resolved BEFORE
#     job registration. The scheduler does no name → id resolution.
#   - `run_callable` must NOT mutate the scheduler or other jobs' state.
#     It may freely call DCWorldExt passes (sync) and read its own params.
#   - The scheduler is strictly serial; no thread-safety required from
#     the runner today.
#
# References: docs/dots-experiment-report.md §3 (A2), §6.3.
# ════════════════════════════════════════════════════════════════════

var name: StringName = &""
var reads: Array[int] = []
var writes: Array[int] = []
var archetype_filter: int = -1
var run_callable: Callable

# Optional auxiliary parameters for run_callable to consume via job.params.
var params: Dictionary = {}


func _init(p_name: StringName = &"", p_reads: Array[int] = [],
		p_writes: Array[int] = [], p_run: Callable = Callable(),
		p_filter: int = -1, p_params: Dictionary = {}) -> void:
	name = p_name
	reads = p_reads.duplicate()
	writes = p_writes.duplicate()
	run_callable = p_run
	archetype_filter = p_filter
	params = p_params.duplicate()


func describe() -> String:
	return "%s reads=%s writes=%s filter=%d" % [
		String(name), str(reads), str(writes), archetype_filter
	]
