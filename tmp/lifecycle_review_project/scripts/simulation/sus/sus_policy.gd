extends RefCounted
class_name SusPolicy

## SUS Policy — abstract base for "should this job run on this tick?" decisions.
##
## All subclasses live in the same file (per requirements) so they share
## class_name visibility without circular preload pain. Concrete strategies:
##
## - AlwaysPolicy()                                  — every tick
## - StridePolicy(stride, phase = 0)                 — every Nth tick
## - AccumulatorPolicy(threshold, getter)            — when accumulator ≥ threshold
## - ContinuousSlicedPolicy(period_ticks, slice_count)
##                                                   — slice_count slices spread
##                                                     over period_ticks days
## - AndPolicy(a, b) / OrPolicy(a, b)                — combinators

## Decide whether the job should be allowed to run a slice on this tick.
## Default returns true (Always-on). Subclasses override.
func should_run(_job, _ctx: SusTickContext) -> bool:
	return true


## Optional hook called by SUS *after* a job's slice reports done = true.
## AccumulatorPolicy uses it to clear the accumulator.
func on_job_completed(_job, _ctx: SusTickContext) -> void:
	pass


# ---------------------------------------------------------------------------
# AlwaysPolicy
# ---------------------------------------------------------------------------

class AlwaysPolicy extends SusPolicy:
	pass


# ---------------------------------------------------------------------------
# StridePolicy — "every stride ticks, with optional phase offset"
# ---------------------------------------------------------------------------

class StridePolicy extends SusPolicy:
	var stride: int = 1
	var phase: int = 0

	func _init(p_stride: int = 1, p_phase: int = 0) -> void:
		stride = max(1, p_stride)
		phase = p_phase

	func should_run(_job, ctx: SusTickContext) -> bool:
		return ((ctx.tick_index + phase) % stride) == 0


# ---------------------------------------------------------------------------
# AccumulatorPolicy — fires when an external accumulator value crosses threshold
# ---------------------------------------------------------------------------

class AccumulatorPolicy extends SusPolicy:
	var threshold: float = 1.0
	var _getter: Callable = Callable()
	var _resetter: Callable = Callable()

	func _init(p_threshold: float, p_getter: Callable, p_resetter: Callable = Callable()) -> void:
		threshold = p_threshold
		_getter = p_getter
		_resetter = p_resetter

	func should_run(_job, _ctx: SusTickContext) -> bool:
		if not _getter.is_valid():
			return false
		var v: float = float(_getter.call())
		return v >= threshold

	func on_job_completed(_job, _ctx: SusTickContext) -> void:
		if _resetter.is_valid():
			_resetter.call()


# ---------------------------------------------------------------------------
# ContinuousSlicedPolicy — period_ticks days, slice_count slices,
# producing one slice every (period_ticks / slice_count) ticks.
# ---------------------------------------------------------------------------

class ContinuousSlicedPolicy extends SusPolicy:
	var period_ticks: int = 30
	var slice_count: int = 10
	var _phase_offset: int = 0

	func _init(p_period_ticks: int = 30, p_slice_count: int = 10, p_phase_offset: int = 0) -> void:
		period_ticks = max(1, p_period_ticks)
		slice_count = max(1, p_slice_count)
		_phase_offset = p_phase_offset

	## Number of ticks between two consecutive slice starts.
	func ticks_per_slice() -> int:
		return max(1, int(ceil(float(period_ticks) / float(slice_count))))

	func should_run(_job, ctx: SusTickContext) -> bool:
		var tps: int = ticks_per_slice()
		return ((ctx.tick_index + _phase_offset) % tps) == 0


# ---------------------------------------------------------------------------
# Combinators
# ---------------------------------------------------------------------------

class AndPolicy extends SusPolicy:
	var a: SusPolicy = null
	var b: SusPolicy = null

	func _init(p_a: SusPolicy, p_b: SusPolicy) -> void:
		a = p_a
		b = p_b

	func should_run(job, ctx: SusTickContext) -> bool:
		var ra: bool = (a == null) or a.should_run(job, ctx)
		var rb: bool = (b == null) or b.should_run(job, ctx)
		return ra and rb


class OrPolicy extends SusPolicy:
	var a: SusPolicy = null
	var b: SusPolicy = null

	func _init(p_a: SusPolicy, p_b: SusPolicy) -> void:
		a = p_a
		b = p_b

	func should_run(job, ctx: SusTickContext) -> bool:
		var ra: bool = (a != null) and a.should_run(job, ctx)
		var rb: bool = (b != null) and b.should_run(job, ctx)
		return ra or rb
