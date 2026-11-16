extends "res://tests/runtime/golden_day_hash_test.gd"

# Same formal world, same boundary reads and assertions as the fixed-cadence
# golden fixture. This target deliberately retains the production timing input.
# Machine load is supplied by separate processes, never by changing game inputs.
func _install_observation_cadence(_ext: Object) -> void:
	print("LOAD_CONSISTENCY_SETUP=" + JSON.stringify({
		"cadence": "production", "seed": 20260727, "days": _observation_days()}))


func _observation_days() -> int:
	return 30


func _run_day(host: WorldRuntimeHost, economy, clock: WorldClock, day: int) -> Dictionary:
	var report: Dictionary = await super._run_day(host, economy, clock, day)
	# Full report is diagnostic only. Results still compare all original business
	# fields; timing and iteration counts never become equality expectations.
	print("LOAD_CONSISTENCY_DAY=" + JSON.stringify({"day": day, "report": report}))
	return report
