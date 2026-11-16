extends RefCounted

## Fixtures that are NOT about the support gate use this to make equip/unequip
## deterministic: zero the authored stance table so the material model takes its
## `stance_count == 0` bypass.
##
## This is the same technique `ideology_worker_authority_parity_test._zero_support_gates`
## already used for its main-thread legs, extracted so the two paths cannot drift.

static func apply(native: Dictionary) -> Dictionary:
	var count := (native.get("ideology_ids", PackedStringArray()) as PackedStringArray).size()
	var offsets := PackedInt32Array()
	offsets.resize(count + 1)
	native["stance_offsets"] = offsets
	for key in ["stance_class_indices", "stance_adopt_q16", "stance_repeal_q16",
			"stance_promote_q16", "stance_adopt_min_q16", "stance_repeal_min_q16",
			"stance_promote_min_q16"]:
		native[key] = PackedInt32Array()
	var thresholds := PackedInt32Array()
	thresholds.resize(count)
	native["adopt_thresholds_q16"] = thresholds.duplicate()
	native["repeal_thresholds_q16"] = thresholds.duplicate()
	native["promote_thresholds_q16"] = thresholds.duplicate()
	return native
