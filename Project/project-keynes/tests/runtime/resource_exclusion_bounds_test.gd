extends SceneTree

# A following row deliberately contains exclusions: an out-of-row ID must not
# borrow them, even when the overall allocation is large enough for the read.
func _initialize() -> void:
	var world := DCWorldExt.new()
	var scalars := PackedFloat32Array()
	scalars.resize(64)
	scalars.fill(0.0)
	for base in [0, 32]:
		scalars[base] = 1.0
		scalars[base + 3] = 1.0
	var knobs := {
		"cell_count": 3, "temperature": PackedFloat32Array([0, 0, 0]),
		"moisture": PackedFloat32Array([0, 0, 0]),
		"habitat_mask": PackedByteArray([1, 1, 1]),
		"terrain": PackedByteArray([0, 1, 255]),
		"vegetation": PackedByteArray([0, 1, 255]),
		"field_names": PackedStringArray(["a", "b"]),
		"habitat_codes": PackedInt32Array([0, 0]), "scalars": scalars,
		"lf_offsets": PackedInt32Array([0, 0, 0]),
		"veg_offsets": PackedInt32Array([0, 0, 0]),
		"noise": [null, null], "province_noise": [null, null], "belt_noise": [null, null]}
	var failures := 0
	for field in ["terrain", "vegetation"]:
		knobs["excluded_" + field + "_width"] = 1
		knobs["excluded_" + field] = PackedByteArray([0, 1])
		var result: Dictionary = world.run_resource_deposit_pass(knobs)
		if not bool(result.get("ok", false)):
			failures += 1
		else:
			var reserves: Array = result["reserves"]
			if reserves[0] != PackedFloat32Array([100, 100, 100]) \
					or reserves[1] != PackedFloat32Array([0, 100, 100]):
				failures += 1
		knobs.erase("excluded_" + field + "_width")
		knobs.erase("excluded_" + field)
	print("resource exclusion bounds: 2 checks, %d failures" % failures)
	quit(0 if failures == 0 else 1)
