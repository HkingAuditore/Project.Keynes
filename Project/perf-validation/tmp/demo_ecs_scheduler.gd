extends RefCounted
class_name DemoEcsScheduler

# ════════════════════════════════════════════════════════════════════
# ⚠️  DO NOT RUN THIS FILE DIRECTLY (it's a RefCounted library, not an
#     EditorScript). To execute the DOTS-A2 experiment, open
#     `res://tmp/demo_ecs_run.gd` and choose File → Run.
# ════════════════════════════════════════════════════════════════════
#
# DemoEcsScheduler — DOTS-A2 EXPERIMENT
# ════════════════════════════════════════════════════════════════════
#
# A minimal serial scheduler over a set of DemoEcsJob records.
#
# Algorithm:
#   1. Collect jobs (registered via add_job).
#   2. Build a DAG:
#        for every (jobA, jobB) with A != B,
#          if jobA.writes ∩ jobB.reads ≠ ∅  →  edge A → B
#          if jobA.writes ∩ jobB.writes ≠ ∅ →  edge A → B (write-after-write,
#                                              broken by registration order)
#   3. Kahn's algorithm topological sort.
#        Tie-break by registration order (stable; debugging-friendly).
#   4. tick(ctx): execute jobs in topo order, calling job.run_callable.call(ctx).
#
# Constraints honoured (best-practices §9 / §11):
#   * Strictly serial. No std::thread, no WorkerThreadPool, no async.
#   * No I/O, no signals, no node tree access.
#   * Jobs themselves invoke C++ passes via ctx.ext.run_*; the scheduler
#     does not know nor care what each job actually does — it only
#     respects the declared reads/writes for ordering.
#
# What this PROVES:
#   * Declarative reads/writes are sufficient to express the existing
#     climate/weather pipeline ordering without hand-coded tick sequences.
#   * Cycle detection works (we throw an error if the user's declarations
#     are inconsistent — useful as a guardrail for future ECS work).
#
# What this does NOT cover (deferred to the future ECS design doc):
#   * Parallel dispatch within a "wave" of mutually-independent jobs.
#   * Per-frame budget / interleaving (sus_scheduler's domain).
#   * Component versioning / change-detection.
#   * Partial-run / resume semantics.
# ════════════════════════════════════════════════════════════════════

var _jobs: Array = []  # Array[DemoEcsJob]
var _last_topo: PackedInt32Array = PackedInt32Array()  # debug: last sort order


func add_job(job: DemoEcsJob) -> void:
	_jobs.append(job)


func clear() -> void:
	_jobs.clear()
	_last_topo = PackedInt32Array()


func job_count() -> int:
	return _jobs.size()


# ────────────────────────────────────────────────────────────────────
# Build dependency edges. Returns a Dictionary { job_idx: Array[child_idx] }
# plus an in_degree count array. O(J²) over comp-id intersection — fine
# for J ≤ 50; the production scheduler will need a hash-bucket variant.
# ────────────────────────────────────────────────────────────────────
func _build_dag() -> Dictionary:
	var n: int = _jobs.size()
	var children: Dictionary = {}
	var in_degree: PackedInt32Array = PackedInt32Array()
	in_degree.resize(n)
	for k in range(n):
		children[k] = []

	for a in range(n):
		var ja: DemoEcsJob = _jobs[a]
		var ja_writes: Array[int] = ja.writes
		if ja_writes.is_empty():
			continue
		for b in range(n):
			if a == b: continue
			var jb: DemoEcsJob = _jobs[b]
			# write→read edge
			var write_to_read: bool = _intersects(ja_writes, jb.reads)
			# write→write edge: registration order wins (a < b means a first)
			var write_to_write: bool = (a < b) and _intersects(ja_writes, jb.writes)
			if write_to_read or write_to_write:
				var arr: Array = children[a]
				if not arr.has(b):
					arr.append(b)
					children[a] = arr
					in_degree[b] += 1
	return {"children": children, "in_degree": in_degree}


# ────────────────────────────────────────────────────────────────────
# Kahn topological sort (stable: ties resolved by registration order).
# Returns a PackedInt32Array with indices into _jobs.
# Pushes an error and returns an empty array if a cycle is detected.
# ────────────────────────────────────────────────────────────────────
func topo_sort() -> PackedInt32Array:
	var dag: Dictionary = _build_dag()
	var children: Dictionary = dag["children"]
	var in_degree: PackedInt32Array = dag["in_degree"]
	var n: int = _jobs.size()

	var ready: Array[int] = []
	for i in range(n):
		if in_degree[i] == 0:
			ready.append(i)

	var order: PackedInt32Array = PackedInt32Array()
	while not ready.is_empty():
		# Stable: take the smallest registration index from `ready`.
		var pick: int = 0
		for k in range(1, ready.size()):
			if ready[k] < ready[pick]:
				pick = k
		var idx: int = ready[pick]
		ready.remove_at(pick)
		order.append(idx)
		var kids: Array = children[idx]
		for c in kids:
			in_degree[c] -= 1
			if in_degree[c] == 0:
				ready.append(c)

	if order.size() != n:
		push_error("[DemoEcsScheduler] cycle detected — declared %d jobs, sorted %d"
			% [n, order.size()])
		return PackedInt32Array()
	_last_topo = order
	return order


# ────────────────────────────────────────────────────────────────────
# Run one tick. ctx is forwarded verbatim to each job's run_callable
# (typical contents: ext, grid_w, grid_h, plus job-specific knobs).
# ────────────────────────────────────────────────────────────────────
func tick(ctx: Dictionary) -> void:
	var order: PackedInt32Array = topo_sort()
	if order.is_empty() and not _jobs.is_empty():
		return  # cycle already reported
	for k in range(order.size()):
		var idx: int = order[k]
		var job: DemoEcsJob = _jobs[idx]
		if job.run_callable.is_valid():
			job.run_callable.call(ctx, job)
		else:
			push_warning("[DemoEcsScheduler] job '%s' has no run_callable" % String(job.name))


func last_order_names() -> Array[String]:
	var out: Array[String] = []
	for k in range(_last_topo.size()):
		var idx: int = _last_topo[k]
		var j: DemoEcsJob = _jobs[idx]
		out.append(String(j.name))
	return out


# ────────────────────────────────────────────────────────────────────
# Helper: does Array[int] a share any element with Array[int] b?
# ────────────────────────────────────────────────────────────────────
static func _intersects(a: Array[int], b: Array[int]) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	for x in a:
		if b.has(x):
			return true
	return false
