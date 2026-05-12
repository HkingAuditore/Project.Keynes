@tool
extends RefCounted

# ═══════════════════════════════════════════════════════════════════
# DCEcsScheduler — production-path serial ECS scheduler
# ═══════════════════════════════════════════════════════════════════
#
# Promoted from `tmp/demo_ecs_scheduler.gd` (DOTS-A2 sandbox). The# algorithm is unchanged; only the class name and header are updated
# so the scheduler can be referenced from `scripts/main.gd` and other
# production paths.
#
# Algorithm:
#   1. Collect jobs (registered via `add_job`).
#   2. Build a DAG of "writes-before-reads" and "writes-before-writes
#      (registration order tiebreaks)" edges.
#   3. Kahn topological sort, stable by registration order.
#   4. `tick(ctx)` runs jobs in topo order, each via `job.run_callable.call`.
#
# Constraints (from cpp-gdscript-best-practices §11):
#   * Strictly serial. No threads, no signals, no node tree access.
#   * Jobs are pure call-out wrappers around C++ passes.
#   * Cycle detection guard: if topo_sort drops short, push_error and abort.
#
# Performance envelope (from `bench_ecs_scheduler_stress.gd`):
#   * J ≤ 30 jobs: topo_sort + tick stays well under 200 µs total.
#   * J ≥ 50: still legal+stable, but topo_sort cost (~270 µs) starts to
#     dominate; revisit with a hash-bucket variant if/when we exceed 50
#     production jobs.
#
# Non-goals (deferred to a future ECS design doc):
#   * Parallel waves of mutually-independent jobs.
#   * Per-frame budget / interleaving.
#   * Component versioning / change-detection.
#   * Partial-run / resume semantics.
# ════════════════════════════════════════════════════════════════════

var _jobs: Array = []  # Array of DCEcsJob (kept untyped—the class is accessed via const preload from callers)
var _last_topo: PackedInt32Array = PackedInt32Array()  # debug: last sort order


func add_job(job) -> void:
	_jobs.append(job)


func clear() -> void:
	_jobs.clear()
	_last_topo = PackedInt32Array()


func job_count() -> int:
	return _jobs.size()


# ────────────────────────────────────────────────────────────────────
# Build dependency edges. Returns { children: { idx: Array[child_idx] },
# in_degree: PackedInt32Array }.
# Complexity: O(J²) over comp-id intersection. Fine for J ≤ 50 (see
# bench_ecs_scheduler_stress).
# ────────────────────────────────────────────────────────────────────
func _build_dag() -> Dictionary:
	var n: int = _jobs.size()
	var children: Dictionary = {}
	var in_degree: PackedInt32Array = PackedInt32Array()
	in_degree.resize(n)
	for k in range(n):
		children[k] = []

	for a in range(n):
		var ja = _jobs[a]
		var ja_writes: Array[int] = ja.writes
		if ja_writes.is_empty():
			continue
		for b in range(n):
			if a == b: continue
			var jb = _jobs[b]
			var write_to_read: bool = _intersects(ja_writes, jb.reads)
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
# Returns indices into `_jobs`. Empty array on cycle (with push_error).
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
		push_error("[DCEcsScheduler] cycle detected — declared %d jobs, sorted %d"
			% [n, order.size()])
		return PackedInt32Array()
	_last_topo = order
	return order


# ────────────────────────────────────────────────────────────────────
# Run one tick. `ctx` is forwarded verbatim to each job's run_callable
# (typical contents: ext, w, h, plus job-specific knobs).
# ────────────────────────────────────────────────────────────────────
func tick(ctx: Dictionary) -> void:
	var order: PackedInt32Array = topo_sort()
	if order.is_empty() and not _jobs.is_empty():
		return
	for k in range(order.size()):
		var idx: int = order[k]
		var job = _jobs[idx]
		if job.run_callable.is_valid():
			job.run_callable.call(ctx, job)
		else:
			push_warning("[DCEcsScheduler] job '%s' has no run_callable" % String(job.name))


func last_order_names() -> Array[String]:
	var out: Array[String] = []
	for k in range(_last_topo.size()):
		var idx: int = _last_topo[k]
		var j = _jobs[idx]
		out.append(String(j.name))
	return out


static func _intersects(a: Array[int], b: Array[int]) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	for x in a:
		if b.has(x):
			return true
	return false
