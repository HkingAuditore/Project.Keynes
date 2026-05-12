@tool
extends RefCounted
class_name DemoEcsJob

# ════════════════════════════════════════════════════════════════════
# ⚠️  DO NOT RUN THIS FILE DIRECTLY (it's a RefCounted library, not an
#     EditorScript). To execute the DOTS-A2 experiment, open
#     `res://tmp/demo_ecs_run.gd` and choose File → Run.
# ════════════════════════════════════════════════════════════════════
#
# DemoEcsJob — DOTS-A2 EXPERIMENT
# ════════════════════════════════════════════════════════════════════
#
# A minimal "system-style" record describing one chunk of work the
# scheduler may dispatch:
#
#   * `name`               — debug-only label
#   * `reads` / `writes`   — comp_id arrays, declarative; the scheduler
#                            uses them to compute a "writes-before-reads"
#                            dependency edge.
#   * `archetype_filter`   — optional logical filter; passed to the C++
#                            kernel via run_*_archetyped(target_archetype).
#                            -1 means "no filter".
#   * `run_callable`       — the actual work, takes a single Dictionary
#                            ctx (ext, w, h, params...). Returns nothing;
#                            success is implicit (we don't model errors
#                            in this PoC).
#
# This is NOT meant to grow into the production scheduler. It exists
# solely to prove that the dependency-graph model can express the
# existing climate / weather pipeline cleanly. Once that's proven,
# best-practices §11 says we open a separate document and design the
# real ECS scheduler — possibly threaded — under that doc.
# ════════════════════════════════════════════════════════════════════

var name: StringName = &""
var reads: Array[int] = []
var writes: Array[int] = []
var archetype_filter: int = -1
var run_callable: Callable

# Optional auxiliary parameters for run_callable to consume via ctx.
# The scheduler does not introspect this — it's job-private state.
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
