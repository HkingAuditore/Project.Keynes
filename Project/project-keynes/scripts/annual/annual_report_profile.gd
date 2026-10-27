extends Resource
class_name AnnualReportProfile

## The native reducer owns all scoring. This resource only compiles content.
@export var version: int = 2
@export var grade_thresholds := PackedInt32Array([9800, 9300, 8400, 7200, 5200, 3200, 0])
@export var reward_draws := PackedInt32Array([4, 3, 2, 1, 1, 0, 0])
@export var quality_weights := PackedInt32Array([2000, 2000, 1500, 1500])
@export var quality_targets := PackedInt32Array([64225, 64880, 64225, 62259])
@export var active_target: int = 62259
@export var progress_weights := PackedInt32Array([800, 600, 500, 300, 300, 500])
@export var progress_targets := PackedInt32Array([6554, 3277, 3277, 6554, 3277, 131072])

func compile_native(country: Dictionary, ideology: Dictionary) -> Dictionary:
	var costs: PackedInt64Array = country.get("technology_costs", PackedInt64Array())
	var tech_eras: PackedStringArray = country.get("technology_era_ids", PackedStringArray())
	var ordered: PackedStringArray = country.get("technology_era_ids_ordered", PackedStringArray())
	var by_era: Array = []
	for _era in ordered:
		by_era.append([])
	for i in costs.size():
		var era: int = ordered.find(tech_eras[i]) if i < tech_eras.size() else -1
		if era >= 0 and costs[i] > 0:
			by_era[era].append(int(costs[i]))
	var medians: Array[int] = []
	for bucket in by_era:
		bucket.sort()
		var median: int = 1
		if not bucket.is_empty():
			median = int(bucket[bucket.size() / 2])
			if bucket.size() % 2 == 0:
				median = (median + int(bucket[bucket.size() / 2 - 1])) / 2
		medians.append(median)
	var equivalents := PackedInt32Array()
	var era_indices := PackedInt32Array()
	for i in costs.size():
		var era: int = ordered.find(tech_eras[i]) if i < tech_eras.size() else -1
		era_indices.append(era)
		var median: int = medians[era] if era >= 0 else 1
		equivalents.append(clampi(int(costs[i]) * 65536 / maxi(1, median), 0, 2147483647))
	return {
		"version": version, "grade_thresholds": grade_thresholds,
		"reward_draws": reward_draws, "quality_weights": quality_weights,
		"quality_targets": quality_targets, "active_target": active_target,
		"progress_weights": progress_weights, "progress_targets": progress_targets,
		"offer_cost_q16": int(ideology.get("offer_cost_q16", 393216)),
		"offer_cost_growth_percent": int(ideology.get("offer_cost_growth_percent", 120)),
		"offer_cost_max_q16": int(ideology.get("offer_cost_max_q16", 9223372036854775807)),
		"technology_equivalents_q16": equivalents, "technology_eras": era_indices,
		"era_milestones": country.get("technology_era_milestone_indices", PackedInt32Array()),
	}
