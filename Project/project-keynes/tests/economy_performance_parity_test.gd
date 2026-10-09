extends "res://tests/runtime_economy_stage_ops_soak_parity_test.gd"

## Wall-clock adaptive cadence is unsuitable for a deterministic two-path
## oracle: the paths are timed differently. Freeze only this test's cadence.
func _profile() -> Dictionary:
	var profile := super._profile()
	profile.economy_cadence_force_market_days = 1
	profile.economy_cadence_force_plan_days = 5
	profile.economy_cadence_force_investment_days = 10
	return profile

func _soak_days() -> int:
	return 30
