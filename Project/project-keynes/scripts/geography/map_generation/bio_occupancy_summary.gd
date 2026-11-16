extends RefCounted

## Cold diagnostic summary; native publication stays in the generator bridge.
static func summarize(generator, occupancy: PackedInt32Array,
		landmass: PackedInt32Array, knobs: Dictionary,
		out_landmass: PackedInt32Array, out_classes: PackedStringArray,
		out_foods: PackedStringArray) -> void:
	var class_names := PackedStringArray(generator.BIO_LOG_CLASS_NAMES)
	var food_names: Array = generator.BIO_LOG_FOOD_NAMES
	var food_bits: PackedInt32Array = generator._bio_log_food_bits()
	var occ_bits: PackedInt32Array = knobs.get("species_occupancy_bits", PackedInt32Array())
	var habitat_class: PackedInt32Array = knobs.get("species_habitat_class", PackedInt32Array())
	var summaries := {}
	for cell in range(mini(occupancy.size(), landmass.size())):
		var lid := int(landmass[cell])
		if lid <= 0:
			continue
		if not summaries.has(lid):
			summaries[lid] = {"foods": [], "classes": []}
		var foods: Array = summaries[lid].foods
		var classes: Array = summaries[lid].classes
		var bits := int(occupancy[cell])
		if bits == 0:
			continue
		for i in food_bits.size():
			if food_bits[i] >= 0 and (bits & (1 << food_bits[i])) != 0 \
					and not foods.has(food_names[i]):
				foods.append(food_names[i])
		for si in range(mini(occ_bits.size(), habitat_class.size())):
			var bit := int(occ_bits[si])
			var habitat := int(habitat_class[si])
			if bit < 0 or bit >= 32 or (bits & (1 << bit)) == 0 \
					or habitat <= 0 or habitat >= class_names.size():
				continue
			var habitat_name := String(class_names[habitat])
			if not classes.has(habitat_name):
				classes.append(habitat_name)
	out_landmass.resize(summaries.size())
	out_classes.resize(summaries.size())
	out_foods.resize(summaries.size())
	var idx := 0
	for lid in summaries:
		var foods: Array = summaries[lid].foods
		var classes: Array = summaries[lid].classes
		out_landmass[idx] = int(lid)
		out_classes[idx] = ", ".join(classes) if not classes.is_empty() else "none"
		out_foods[idx] = ", ".join(foods) if not foods.is_empty() else "none"
		idx += 1
