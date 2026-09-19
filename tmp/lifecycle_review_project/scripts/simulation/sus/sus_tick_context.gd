extends RefCounted
class_name SusTickContext

## SUS Tick Context — describes the source and timing of a SUS.tick() call.
##
## Created cheaply per-tick by the dispatcher (e.g. main.gd._on_day_changed).
## Jobs read fields like day_index / season_phase to compute their progress.

## Monotonically increasing per SUS instance; resets only on map regenerate.
var tick_index: int = 0

## Snapshot of WorldClock.day_index() at the moment of dispatch.
var day_index: int = 0

## Snapshot of WorldClock.season_phase() in [0, 4).
var season_phase: float = 0.0

## Snapshot of WorldClock.speed_multiplier (x1 / x5 / x20 ...).
var speed_scale: float = 1.0

## Origin of the dispatch: &"day_changed" / &"season_changed" / &"year_changed" / &"frame".
var source: StringName = &""


static func make(p_tick_index: int,
				p_day_index: int,
				p_season_phase: float,
				p_speed_scale: float,
				p_source: StringName) -> SusTickContext:
	var ctx := SusTickContext.new()
	ctx.tick_index = p_tick_index
	ctx.day_index = p_day_index
	ctx.season_phase = p_season_phase
	ctx.speed_scale = p_speed_scale
	ctx.source = p_source
	return ctx