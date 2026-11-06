extends "res://tests/runtime/golden_external_advancers_test.gd"

const AlignedHost = preload("res://tests/runtime/fixtures/day_aligned_external_host.gd")

func _create_host() -> WorldRuntimeHost:
	return AlignedHost.new()

func _wait_golden_read_boundary(host: WorldRuntimeHost, economy, day: int) -> bool:
	var ready := await super._wait_golden_read_boundary(host, economy, day)
	if not ready:
		return false
	# The inherited v5 driver cannot submit the next day until this returns.
	var result: Dictionary = (host as AlignedHost).align_committed_day(day)
	if not bool(result.get("ok", false)):
		print("EXTERNAL_DAY_ALIGNMENT_REJECT=" + JSON.stringify({"result": result, "day": day,
			"host_day": host._runtime_commit_day, "resource_target": host._runtime_natural_resource_pending_target_day,
			"military_target": host._runtime_military_pending_target_day}))
	_expect("experimental exact-day boundary", bool(result.get("ok", false)))
	return bool(result.get("ok", false))
