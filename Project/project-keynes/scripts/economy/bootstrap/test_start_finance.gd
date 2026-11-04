extends RefCounted

# Pure opening stock and cash calculation. Inputs are copied values; this module
# has no world, facade, registry, command or save access.
const Inputs = preload("res://scripts/economy/bootstrap/test_start_inputs.gd")
const Policy = preload("res://scripts/economy/bootstrap/test_start_policy.gd")
const BOOTSTRAP_BRIDGE_STOCK = Policy.BOOTSTRAP_BRIDGE_STOCK
const CLOTHING_GOOD_IDS = Policy.CLOTHING_GOOD_IDS
const FOOD_GOOD_IDS = Policy.FOOD_GOOD_IDS
const GOODS_SCALE = Policy.GOODS_SCALE
const INITIAL_BUILDING_INPUT_STOCK_DAYS = Policy.INITIAL_BUILDING_INPUT_STOCK_DAYS
const INITIAL_HOUSEHOLD_STOCK_DAYS = Policy.INITIAL_HOUSEHOLD_STOCK_DAYS
const INT64_MAX = Policy.INT64_MAX
const PLANNED_UTILIZATION_Q16 = Policy.PLANNED_UTILIZATION_Q16
const Q16_ONE = Policy.Q16_ONE

static func bootstrap_market_packet(map: Inputs, finance: Dictionary,
		cohort_cells: PackedInt32Array, signature_ids: PackedInt32Array,
		populations: PackedInt64Array, groups_by_cell: Dictionary,
		populated_cells: PackedInt32Array, cycle_days: int) -> Dictionary:
	var good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	var stock := PackedInt64Array()
	stock.resize(map.cell_count() * good_ids.size())
	stock.fill(0)
	var household_stock := 0
	for cohort in range(mini(cohort_cells.size(),
			mini(signature_ids.size(), populations.size()))):
		household_stock = sat_add_nonnegative(household_stock,
			add_initial_household_stock(stock, good_ids, map, finance,
				int(cohort_cells[cohort]), int(signature_ids[cohort]),
				int(populations[cohort]), INITIAL_HOUSEHOLD_STOCK_DAYS))
	var building_input_stock := 0
	for cell_idx_raw in populated_cells:
		var cell_idx := int(cell_idx_raw)
		for group_raw in groups_by_cell.get(cell_idx, []):
			var group: Dictionary = group_raw
			var spec: Dictionary = group.spec
			var inputs: PackedStringArray = spec.get(
				"input_good_ids", PackedStringArray())
			var quantities: PackedInt64Array = spec.get(
				"input_quantities", PackedInt64Array())
			for input_idx in range(mini(inputs.size(), quantities.size())):
				var selected := initial_building_input(spec, input_idx,
					maxi(0, int(quantities[input_idx])))
				var good_idx := good_ids.find(String(selected.good_id))
				if good_idx < 0:
					continue
				var quantity := sat_mul_nonnegative(
					sat_mul_nonnegative(maxi(0, int(group.count)),
						int(selected.quantity)),
					INITIAL_BUILDING_INPUT_STOCK_DAYS)
				add_market_stock(stock, cell_idx, good_idx, good_ids.size(), quantity)
				building_input_stock = sat_add_nonnegative(
					building_input_stock, quantity)
	var bridge_stock := 0
	for cell_idx_raw in populated_cells:
		var cell_idx := int(cell_idx_raw)
		for good_id in BOOTSTRAP_BRIDGE_STOCK:
			var good_idx := good_ids.find(String(good_id))
			var quantity := int(BOOTSTRAP_BRIDGE_STOCK[good_id])
			add_market_stock(stock, cell_idx, good_idx, good_ids.size(), quantity)
			bridge_stock = sat_add_nonnegative(bridge_stock, quantity)
	return {
		"packet": {"stock": stock},
		"household_stock": household_stock,
		"building_input_stock": building_input_stock,
		"bridge_stock": bridge_stock,
		"total_stock": sum_i64(stock),
	}


static func initial_building_input(
		spec: Dictionary, input_idx: int, base_quantity: int) -> Dictionary:
	var input_ids: PackedStringArray = spec.get("input_good_ids", PackedStringArray())
	var offsets: PackedInt32Array = spec.get(
		"input_candidate_offsets", PackedInt32Array())
	var candidates: PackedStringArray = spec.get(
		"input_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = spec.get(
		"input_candidate_efficiency_q16", PackedInt32Array())
	if input_idx + 1 < offsets.size():
		var begin := int(offsets[input_idx])
		var end := int(offsets[input_idx + 1])
		if begin >= 0 and begin < end and begin < candidates.size():
			var efficiency := int(efficiencies[begin]) \
				if begin < efficiencies.size() else Q16_ONE
			var physical := (base_quantity * Q16_ONE + maxi(1, efficiency) - 1) / \
				maxi(1, efficiency)
			return {"good_id": String(candidates[begin]), "quantity": physical}
	return {
		"good_id": String(input_ids[input_idx]) if input_idx < input_ids.size() else "",
		"quantity": base_quantity,
	}


static func add_initial_household_stock(stock: PackedInt64Array,
		good_ids: PackedStringArray, map: Inputs, finance: Dictionary,
		cell_idx: int, signature_id: int, population: int, days: int) -> int:
	if population <= 0 or days <= 0:
		return 0
	var plan_ids: PackedStringArray = finance.get("plan_ids", PackedStringArray())
	var signature_plans: PackedInt32Array = finance.get(
		"signature_plan_ids", PackedInt32Array())
	var plan_idx := int(signature_plans[signature_id]) \
		if signature_id >= 0 and signature_id < signature_plans.size() else -1
	var plan_offsets: PackedInt32Array = finance.get(
		"plan_need_offsets", PackedInt32Array())
	var signature_ethnicity: PackedInt32Array = finance.get(
		"signature_ethnicity_ids", PackedInt32Array())
	if plan_idx < 0 or plan_idx + 1 >= plan_offsets.size() \
			or signature_id < 0 or signature_id >= signature_ethnicity.size():
		return 0
	var stable_needs: PackedInt32Array = finance.get(
		"need_stable_ids", PackedInt32Array())
	var base_quantities: PackedInt64Array = finance.get(
		"need_base_qty_per_person", PackedInt64Array())
	var need_curves: PackedInt32Array = finance.get(
		"need_quantity_env_curve_ids", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = finance.get(
		"need_variant_offsets", PackedInt32Array())
	var preferences: PackedInt32Array = finance.get(
		"variant_preference_q16", PackedInt32Array())
	var preference_curves: PackedInt32Array = finance.get(
		"variant_preference_env_curve_ids", PackedInt32Array())
	var component_offsets: PackedInt32Array = finance.get(
		"variant_component_offsets", PackedInt32Array())
	var component_goods: PackedInt32Array = finance.get(
		"component_good_ids", PackedInt32Array())
	var component_quantities: PackedInt64Array = finance.get(
		"component_qty_per_need", PackedInt64Array())
	var need_ids: PackedStringArray = finance.get("need_ids", PackedStringArray())
	var ethnicity_factors: PackedInt32Array = finance.get(
		"ethnicity_need_factor_q16", PackedInt32Array())
	var ethnicity := int(signature_ethnicity[signature_id])
	var added := 0
	for need_idx in range(int(plan_offsets[plan_idx]), int(plan_offsets[plan_idx + 1])):
		if need_idx >= stable_needs.size() or need_idx >= base_quantities.size() \
				or need_idx >= need_curves.size() or need_idx + 1 >= need_variant_offsets.size():
			continue
		var desired := sat_mul_nonnegative(
			sat_mul_nonnegative(population, int(base_quantities[need_idx])), days)
		desired = desired * sample_environment_curve(
			finance, int(need_curves[need_idx]), map, cell_idx) / Q16_ONE
		var stable_need := int(stable_needs[need_idx])
		if stable_need < 0 or stable_need >= need_ids.size():
			continue
		var factor_idx := ethnicity * need_ids.size() + stable_need
		if factor_idx >= 0 and factor_idx < ethnicity_factors.size():
			desired = desired * int(ethnicity_factors[factor_idx]) / Q16_ONE
		var variant_begin := int(need_variant_offsets[need_idx])
		var variant_end := int(need_variant_offsets[need_idx + 1])
		var score_sum := 0
		for variant in range(variant_begin, variant_end):
			if variant < preferences.size() and variant < preference_curves.size() and \
					variant_goods_available(variant, finance, component_offsets,
						component_goods):
				score_sum += maxi(0, int(preferences[variant]) * sample_environment_curve(
					finance, int(preference_curves[variant]), map, cell_idx) / Q16_ONE)
		if desired <= 0 or score_sum <= 0:
			continue
		var prefix_score := 0
		var allocated := 0
		for variant in range(variant_begin, variant_end):
			if variant >= preferences.size() or variant >= preference_curves.size() \
					or variant + 1 >= component_offsets.size() or \
					not variant_goods_available(
						variant, finance, component_offsets, component_goods):
				continue
			prefix_score += maxi(0, int(preferences[variant]) * sample_environment_curve(
				finance, int(preference_curves[variant]), map, cell_idx) / Q16_ONE)
			var next := desired * prefix_score / score_sum
			var variant_units := maxi(0, next - allocated)
			allocated = next
			for component in range(int(component_offsets[variant]),
					int(component_offsets[variant + 1])):
				if component >= component_goods.size() or component >= component_quantities.size():
					continue
				var good_idx := int(component_goods[component])
				if good_idx < 0 or good_idx >= good_ids.size():
					continue
				var quantity := variant_units * int(component_quantities[component]) / GOODS_SCALE
				add_market_stock(stock, cell_idx, good_idx, good_ids.size(), quantity)
				added = sat_add_nonnegative(added, quantity)
	return added


static func variant_goods_available(variant: int, finance: Dictionary,
		component_offsets: PackedInt32Array,
		component_goods: PackedInt32Array) -> bool:
	if variant < 0 or variant + 1 >= component_offsets.size():
		return false
	var offsets: PackedInt32Array = finance.get(
		"good_technology_tag_offsets", PackedInt32Array())
	var tags: PackedStringArray = finance.get(
		"good_technology_tags", PackedStringArray())
	for component in range(int(component_offsets[variant]),
			int(component_offsets[variant + 1])):
		if component < 0 or component >= component_goods.size():
			return false
		var good_idx := int(component_goods[component])
		if good_idx < 0 or good_idx + 1 >= offsets.size():
			return false
		var begin := int(offsets[good_idx])
		var end := int(offsets[good_idx + 1])
		if begin < 0 or end > tags.size() or end < begin:
			return false
		# technology_tags are alternative discovery routes, as in the native
		# catalog. Requiring every route incorrectly asks a stone-age household
		# to discover textile machinery before it can stock cloth.
		if not Policy.technology_available(tags.slice(begin, end)):
			return false
	return true


static func add_market_stock(stock: PackedInt64Array, cell_idx: int,
		good_idx: int, good_count: int, quantity: int) -> void:
	var index := cell_idx * good_count + good_idx
	if quantity <= 0 or index < 0 or index >= stock.size():
		return
	stock[index] = sat_add_nonnegative(int(stock[index]), quantity)


static func default_input_cost_per_day(spec: Dictionary, finance: Dictionary) -> int:
	var good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var quantities: PackedInt64Array = spec.get("input_quantities", PackedInt64Array())
	var offsets: PackedInt32Array = spec.get("input_candidate_offsets", PackedInt32Array())
	var candidates: PackedStringArray = spec.get("input_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = spec.get(
		"input_candidate_efficiency_q16", PackedInt32Array())
	var total := 0
	for input_idx in range(quantities.size()):
		if input_idx + 1 >= offsets.size():
			continue
		var cheapest := -1
		for candidate_idx in range(int(offsets[input_idx]), int(offsets[input_idx + 1])):
			if candidate_idx >= candidates.size() or candidate_idx >= efficiencies.size():
				continue
			var good_idx := good_ids.find(String(candidates[candidate_idx]))
			var efficiency := int(efficiencies[candidate_idx])
			if good_idx < 0 or good_idx >= prices.size() or efficiency <= 0:
				continue
			var physical := (int(quantities[input_idx]) * Q16_ONE + efficiency - 1) / efficiency
			var cost := physical * int(prices[good_idx]) / GOODS_SCALE
			if cheapest < 0 or cost < cheapest:
				cheapest = cost
		if cheapest > 0:
			total += cheapest
	return total


static func default_output_inventory_value_per_day(
		spec: Dictionary, finance: Dictionary) -> int:
	var good_ids: PackedStringArray = finance.get("good_ids", PackedStringArray())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var target_days: PackedInt32Array = finance.get(
		"good_target_inventory_days_q16", PackedInt32Array())
	var buy_factors: PackedInt32Array = finance.get(
		"good_merchant_buy_factor_q16", PackedInt32Array())
	var issue_values: PackedInt64Array = finance.get(
		"good_monetary_issue_values", PackedInt64Array())
	var outputs: PackedStringArray = spec.get("output_good_ids", PackedStringArray())
	var quantities: PackedInt64Array = spec.get("output_quantities", PackedInt64Array())
	var total := 0
	for output_idx in range(mini(outputs.size(), quantities.size())):
		var good_idx := good_ids.find(String(outputs[output_idx]))
		if good_idx < 0 or good_idx >= prices.size() or good_idx >= target_days.size() \
				or good_idx >= buy_factors.size():
			continue
		if good_idx < issue_values.size() and int(issue_values[good_idx]) > 0:
			continue
		var market_share_q16 := Q16_ONE / 2 if FOOD_GOOD_IDS.has(
			String(outputs[output_idx])) or CLOTHING_GOOD_IDS.has(
			String(outputs[output_idx])) else Q16_ONE
		var planned_quantity := int(quantities[output_idx]) * \
			PLANNED_UTILIZATION_Q16 / Q16_ONE
		var target_quantity := planned_quantity * int(target_days[good_idx]) / Q16_ONE
		target_quantity = target_quantity * market_share_q16 / Q16_ONE
		var buy_price := int(prices[good_idx]) * int(buy_factors[good_idx]) / Q16_ONE
		total += target_quantity * buy_price / GOODS_SCALE
	return total


static func survival_cost_per_person_per_day(
		map: Inputs, cell_idx: int, signature_id: int, finance: Dictionary) -> int:
	var plan_ids: PackedStringArray = finance.get("plan_ids", PackedStringArray())
	var plan_id := plan_ids.find(String(finance.get(
		"living_cost_base_plan_id", "survival_household")))
	var plan_offsets: PackedInt32Array = finance.get("plan_need_offsets", PackedInt32Array())
	var signature_ethnicity: PackedInt32Array = finance.get(
		"signature_ethnicity_ids", PackedInt32Array())
	if plan_id < 0 or plan_id + 1 >= plan_offsets.size() \
			or signature_id < 0 or signature_id >= signature_ethnicity.size():
		return 0
	var need_ids: PackedStringArray = finance.get("need_ids", PackedStringArray())
	var living_weights: PackedInt32Array = finance.get(
		"need_living_cost_weights_q16", PackedInt32Array())
	var stable_needs: PackedInt32Array = finance.get("need_stable_ids", PackedInt32Array())
	var base_quantities: PackedInt64Array = finance.get(
		"need_base_qty_per_person", PackedInt64Array())
	var need_curves: PackedInt32Array = finance.get(
		"need_quantity_env_curve_ids", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = finance.get(
		"need_variant_offsets", PackedInt32Array())
	var preferences: PackedInt32Array = finance.get(
		"variant_preference_q16", PackedInt32Array())
	var preference_curves: PackedInt32Array = finance.get(
		"variant_preference_env_curve_ids", PackedInt32Array())
	var component_offsets: PackedInt32Array = finance.get(
		"variant_component_offsets", PackedInt32Array())
	var component_goods: PackedInt32Array = finance.get(
		"component_good_ids", PackedInt32Array())
	var component_quantities: PackedInt64Array = finance.get(
		"component_qty_per_need", PackedInt64Array())
	var prices: PackedInt32Array = finance.get("good_default_price", PackedInt32Array())
	var ethnicity_factors: PackedInt32Array = finance.get(
		"ethnicity_need_factor_q16", PackedInt32Array())
	var ethnicity := int(signature_ethnicity[signature_id])
	var total := 0
	for need_idx in range(int(plan_offsets[plan_id]), int(plan_offsets[plan_id + 1])):
		if need_idx >= stable_needs.size() or need_idx >= base_quantities.size() \
				or need_idx >= need_curves.size() or need_idx + 1 >= need_variant_offsets.size():
			continue
		var stable_need := int(stable_needs[need_idx])
		if stable_need < 0 or stable_need >= living_weights.size():
			continue
		var score_sum := 0
		var weighted_price := 0
		for variant in range(int(need_variant_offsets[need_idx]),
				int(need_variant_offsets[need_idx + 1])):
			if variant >= preferences.size() or variant >= preference_curves.size() \
					or variant + 1 >= component_offsets.size():
				continue
			var unit_price := 0
			for component in range(int(component_offsets[variant]),
					int(component_offsets[variant + 1])):
				if component >= component_goods.size() or component >= component_quantities.size():
					continue
				var good_idx := int(component_goods[component])
				if good_idx >= 0 and good_idx < prices.size():
					unit_price += int(component_quantities[component]) * int(prices[good_idx]) / GOODS_SCALE
			var score := int(preferences[variant]) * sample_environment_curve(
				finance, int(preference_curves[variant]), map, cell_idx) / Q16_ONE
			score_sum += maxi(0, score)
			weighted_price += maxi(1, unit_price) * maxi(0, score)
		if score_sum <= 0:
			continue
		var quantity := int(base_quantities[need_idx]) * int(living_weights[stable_need]) / Q16_ONE
		quantity = quantity * sample_environment_curve(
			finance, int(need_curves[need_idx]), map, cell_idx) / Q16_ONE
		var factor_index := ethnicity * need_ids.size() + stable_need
		if factor_index >= 0 and factor_index < ethnicity_factors.size():
			quantity = quantity * int(ethnicity_factors[factor_index]) / Q16_ONE
		total += quantity * (weighted_price / score_sum) / GOODS_SCALE
	return maxi(0, total)


static func sample_environment_curve(
		finance: Dictionary, curve_id: int, map: Inputs, cell_idx: int) -> int:
	if curve_id < 0:
		return Q16_ONE
	var signals: PackedInt32Array = finance.get(
		"environment_curve_signal_ids", PackedInt32Array())
	var values: PackedInt32Array = finance.get(
		"environment_curve_values_q16", PackedInt32Array())
	if curve_id >= signals.size() or (curve_id + 1) * 17 > values.size():
		return 0
	var signal_q16 := environment_signal_q16(map, cell_idx, int(signals[curve_id]))
	var scaled := clampi(signal_q16, 0, Q16_ONE) * 16
	var lo := mini(16, scaled / Q16_ONE)
	var hi := mini(16, lo + 1)
	var fraction := scaled - lo * Q16_ONE
	var begin := curve_id * 17
	return int(values[begin + lo]) + \
		(int(values[begin + hi]) - int(values[begin + lo])) * fraction / Q16_ONE


static func environment_signal_q16(map: Inputs, cell_idx: int, signal_id: int) -> int:
	var values: PackedFloat32Array
	var fallback := 0.0
	match signal_id:
		0:
			values = map.temp_arr
			fallback = 0.5
		1:
			values = map.moisture_arr
			fallback = 0.5
		2:
			values = map.snow_cover_arr
		3:
			values = map.weather_intensity_arr
		_:
			return 0
	var value := float(values[cell_idx]) if cell_idx >= 0 and cell_idx < values.size() else fallback
	if not is_finite(value):
		value = fallback
	return clampi(roundi(clampf(value, 0.0, 1.0) * Q16_ONE), 0, Q16_ONE)


static func sat_add_nonnegative(a: int, b: int) -> int:
	a = maxi(0, a)
	b = maxi(0, b)
	return INT64_MAX if a > INT64_MAX - b else a + b


static func sat_mul_nonnegative(a: int, b: int) -> int:
	a = maxi(0, a)
	b = maxi(0, b)
	if a == 0 or b == 0:
		return 0
	return INT64_MAX if a > INT64_MAX / b else a * b


static func sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total = sat_add_nonnegative(total, int(value))
	return total

