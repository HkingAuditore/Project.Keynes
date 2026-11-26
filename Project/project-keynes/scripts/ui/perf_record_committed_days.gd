extends RefCounted

## The headless recording window, driven by published daily records.
const COLUMNS := [
	"row_idx", "tick_idx", "speed_multiplier", "t_sus_ms",
	"runtime_graph_simulation_committed_day", "runtime_graph_simulation_generation",
	"commit_produced_at_us", "commit_interval_ms",
]

var _after_day := -1
var _through_day := -1
var _speed := 1.0
var _last_day := -1
var _last_commit_us := 0
var _warmup_commit_us := 0
var _last_observed_us := 0
var _observed_days := 0


func configure(after_day: int, through_day: int, speed: float) -> void:
	_after_day = after_day
	_through_day = through_day
	_speed = speed


func is_enabled() -> bool:
	return _after_day >= 0


func reset() -> void:
	_last_day = -1
	_last_commit_us = 0
	_warmup_commit_us = 0
	_last_observed_us = 0
	_observed_days = 0


func measurement() -> Dictionary:
	return {
		"observed_days": _observed_days,
		"warmup_commit_us": _warmup_commit_us,
		"last_commit_us": _last_commit_us,
		"last_observed_us": _last_observed_us,
	}


func record_day(record: Dictionary, observed_us: int) -> Dictionary:
	var day := int(record["day"])
	if day <= _last_day or (_through_day >= 0 and day > _through_day):
		return {}
	var commit_us := int(record["produced_at_us"])
	var interval_ms: Variant = null
	if day > 1 and day == _last_day + 1 and _last_commit_us > 0 and commit_us >= _last_commit_us:
		interval_ms = float(commit_us - _last_commit_us) / 1000.0
	_last_day = day
	_last_commit_us = commit_us
	if day > 0:
		_observed_days += 1
	if day == _after_day:
		_warmup_commit_us = commit_us
	if day <= _after_day:
		return {}

	# Foreground timings cover a batch. This row describes its own commit.
	_last_observed_us = observed_us
	return {
		"tick_idx": day,
		"speed_multiplier": _speed,
		"runtime_graph_simulation_committed_day": day,
		"runtime_graph_simulation_generation": int(record["generation"]),
		"commit_produced_at_us": commit_us,
		"commit_interval_ms": interval_ms,
	}
