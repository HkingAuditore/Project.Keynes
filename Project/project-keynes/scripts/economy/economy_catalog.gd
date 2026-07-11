class_name EconomyCatalog
extends RefCounted

const PROFESSION_DIR := "res://data/economy/professions"
const ETHNICITY_DIR := "res://data/economy/ethnicities"
const PLAN_DIR := "res://data/economy/consumption_plans"
const NEED_DIR := "res://data/economy/needs"
const CURVE_DIR := "res://data/economy/environment_curves"
const BUILDING_DIR := "res://data/economy/buildings"
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")
const Q16_ONE := 65536
const SIGNAL_IDS := {
	"temperature": 0,
	"moisture": 1,
	"snow_cover": 2,
	"weather_intensity": 3,
}

static func compile_native_catalog() -> Dictionary:
	var professions := _load_resources(PROFESSION_DIR)
	var ethnicities := _load_resources(ETHNICITY_DIR)
	var plans := _load_resources(PLAN_DIR)
	var needs := _load_resources(NEED_DIR)
	var curves := _load_resources(CURVE_DIR)
	if professions.is_empty() or ethnicities.is_empty() or plans.is_empty() or needs.is_empty():
		return {"ok": false, "reason": "market v2 catalog is incomplete"}

	var good_columns: Dictionary = GoodProfileRegistry.compile_native_columns()
	var good_ids: PackedStringArray = good_columns.good_ids
	var good_index := _index_ids(good_ids)
	if good_ids.is_empty():
		return {"ok": false, "reason": "good catalog is empty"}

	var need_ids := PackedStringArray()
	for need in needs:
		need_ids.append(String(need.id))
	if need_ids.size() > 32:
		return {"ok": false, "reason": "global need count exceeds 32"}
	var need_index := _index_ids(need_ids)

	var curve_ids := PackedStringArray()
	var curve_signal_ids := PackedInt32Array()
	var curve_values := PackedInt32Array()
	for curve in curves:
		var curve_id := String(curve.id)
		var signal_name := String(curve.signal_id)
		if not SIGNAL_IDS.has(signal_name) or curve.values_q16.size() != 17:
			return {"ok": false, "reason": "invalid environment curve: %s" % curve_id}
		curve_ids.append(curve_id)
		curve_signal_ids.append(int(SIGNAL_IDS[signal_name]))
		for value in curve.values_q16:
			curve_values.append(maxi(0, int(value)))
	var curve_index := _index_ids(curve_ids)

	var plan_ids := PackedStringArray()
	var plan_index := {}
	for i in range(plans.size()):
		var stable_id := String(plans[i].id)
		if stable_id == "" or plan_index.has(stable_id):
			return {"ok": false, "reason": "invalid or duplicate plan id: %s" % stable_id}
		plan_ids.append(stable_id)
		plan_index[stable_id] = i

	var plan_need_offsets := PackedInt32Array([0])
	var need_stable_ids := PackedInt32Array()
	var need_priorities := PackedInt32Array()
	var need_base_qty := PackedInt64Array()
	var need_wealth_elasticity := PackedInt32Array()
	var need_wealth_min := PackedInt32Array()
	var need_wealth_max := PackedInt32Array()
	var need_env_curve_ids := PackedInt32Array()
	var need_variant_offsets := PackedInt32Array([0])
	var variant_preference := PackedInt32Array()
	var variant_elasticity := PackedInt32Array()
	var variant_env_curve_ids := PackedInt32Array()
	var variant_component_offsets := PackedInt32Array([0])
	var component_good_ids := PackedInt32Array()
	var component_qty := PackedInt64Array()

	for plan in plans:
		var need_count: int = plan.need_ids.size()
		if need_count > 16 or plan.priorities.size() != need_count \
				or plan.base_qty_per_person.size() != need_count \
				or plan.wealth_elasticity_q16.size() != need_count \
				or plan.wealth_min_q16.size() != need_count \
				or plan.wealth_max_q16.size() != need_count \
				or plan.quantity_env_curve_ids.size() != need_count \
				or plan.need_variant_offsets.size() != need_count + 1 \
				or plan.need_variant_offsets[0] != 0:
			return {"ok": false, "reason": "invalid need columns in plan %s" % String(plan.id)}
		var variant_count: int = plan.variant_ids.size()
		if plan.need_variant_offsets[need_count] != variant_count \
				or plan.variant_preference_q16.size() != variant_count \
				or plan.variant_price_elasticity_q16.size() != variant_count \
				or plan.variant_preference_env_curve_ids.size() != variant_count \
				or plan.variant_component_offsets.size() != variant_count + 1 \
				or plan.variant_component_offsets[0] != 0:
			return {"ok": false, "reason": "invalid variant columns in plan %s" % String(plan.id)}
		if plan.variant_component_offsets[variant_count] != plan.component_good_ids.size() \
				or plan.component_good_ids.size() != plan.component_qty_per_need.size() \
				or plan.component_good_ids.size() > 32:
			return {"ok": false, "reason": "invalid component columns in plan %s" % String(plan.id)}
		var previous_priority := -2147483648
		for n in range(need_count):
			var need_id := String(plan.need_ids[n])
			var priority := int(plan.priorities[n])
			var vb := int(plan.need_variant_offsets[n])
			var ve := int(plan.need_variant_offsets[n + 1])
			if not need_index.has(need_id) or priority < previous_priority or ve <= vb or ve - vb > 4:
				return {"ok": false, "reason": "invalid need entry in plan %s" % String(plan.id)}
			previous_priority = priority
			need_stable_ids.append(int(need_index[need_id]))
			need_priorities.append(priority)
			need_base_qty.append(int(plan.base_qty_per_person[n]))
			need_wealth_elasticity.append(int(plan.wealth_elasticity_q16[n]))
			need_wealth_min.append(int(plan.wealth_min_q16[n]))
			need_wealth_max.append(int(plan.wealth_max_q16[n]))
			need_env_curve_ids.append(_optional_index(curve_index, String(plan.quantity_env_curve_ids[n])))
			need_variant_offsets.append(need_variant_offsets[-1] + ve - vb)
		for v in range(variant_count):
			var cb := int(plan.variant_component_offsets[v])
			var ce := int(plan.variant_component_offsets[v + 1])
			if ce <= cb or ce - cb > 4:
				return {"ok": false, "reason": "invalid complement bundle in plan %s" % String(plan.id)}
			variant_preference.append(int(plan.variant_preference_q16[v]))
			variant_elasticity.append(int(plan.variant_price_elasticity_q16[v]))
			variant_env_curve_ids.append(_optional_index(
				curve_index, String(plan.variant_preference_env_curve_ids[v])))
			variant_component_offsets.append(variant_component_offsets[-1] + ce - cb)
			for c in range(cb, ce):
				var good_id := String(plan.component_good_ids[c])
				if not good_index.has(good_id) or int(plan.component_qty_per_need[c]) <= 0:
					return {"ok": false, "reason": "invalid good component in plan %s" % String(plan.id)}
				component_good_ids.append(int(good_index[good_id]))
				component_qty.append(int(plan.component_qty_per_need[c]))
		plan_need_offsets.append(need_stable_ids.size())

	var profession_ids := PackedStringArray()
	var profession_index := {}
	for i in range(professions.size()):
		var stable_id := String(professions[i].id)
		if stable_id == "" or profession_index.has(stable_id) \
				or not plan_index.has(String(professions[i].default_consumption_plan_id)):
			return {"ok": false, "reason": "invalid profession: %s" % stable_id}
		profession_ids.append(stable_id)
		profession_index[stable_id] = i

	var ethnicity_ids := PackedStringArray()
	var ethnicity_need_factor := PackedInt32Array()
	for ethnicity in ethnicities:
		var stable_id := String(ethnicity.id)
		if stable_id == "" or ethnicity_ids.has(stable_id) \
				or ethnicity.need_modifier_ids.size() != ethnicity.need_quantity_factors_q16.size():
			return {"ok": false, "reason": "invalid ethnicity: %s" % stable_id}
		ethnicity_ids.append(stable_id)
		var factors := PackedInt32Array()
		factors.resize(need_ids.size())
		factors.fill(Q16_ONE)
		for i in range(ethnicity.need_modifier_ids.size()):
			var need_id := String(ethnicity.need_modifier_ids[i])
			if not need_index.has(need_id):
				return {"ok": false, "reason": "ethnicity references missing need: %s" % need_id}
			factors[int(need_index[need_id])] = int(ethnicity.need_quantity_factors_q16[i])
		ethnicity_need_factor.append_array(factors)

	var signature_profession_ids := PackedInt32Array()
	var signature_ethnicity_ids := PackedInt32Array()
	var signature_plan_ids := PackedInt32Array()
	var signature_birth_rate_q32 := PackedInt64Array()
	var signature_death_rate_q32 := PackedInt64Array()
	var signature_satisfaction_birth_weight_q16 := PackedInt64Array()
	var signature_keys := PackedStringArray()
	for profession_idx in range(professions.size()):
		var profession = professions[profession_idx]
		for ethnicity_idx in range(ethnicities.size()):
			var ethnicity = ethnicities[ethnicity_idx]
			signature_keys.append("%s|%s" % [String(profession.id), String(ethnicity.id)])
			signature_profession_ids.append(profession_idx)
			signature_ethnicity_ids.append(ethnicity_idx)
			signature_plan_ids.append(int(plan_index[String(profession.default_consumption_plan_id)]))
			signature_birth_rate_q32.append((int(profession.birth_rate_q32) * int(ethnicity.birth_rate_factor_q16)) / Q16_ONE)
			signature_death_rate_q32.append((int(profession.death_rate_q32) * int(ethnicity.death_rate_factor_q16)) / Q16_ONE)
			signature_satisfaction_birth_weight_q16.append(int(profession.satisfaction_birth_weight_q16))

	var catalog := {
		"profession_ids": profession_ids,
		"ethnicity_ids": ethnicity_ids,
		"need_ids": need_ids,
		"plan_ids": plan_ids,
		"environment_curve_ids": curve_ids,
		"environment_curve_signal_ids": curve_signal_ids,
		"environment_curve_values_q16": curve_values,
		"plan_need_offsets": plan_need_offsets,
		"need_stable_ids": need_stable_ids,
		"need_priorities": need_priorities,
		"need_base_qty_per_person": need_base_qty,
		"need_wealth_elasticity_q16": need_wealth_elasticity,
		"need_wealth_min_q16": need_wealth_min,
		"need_wealth_max_q16": need_wealth_max,
		"need_quantity_env_curve_ids": need_env_curve_ids,
		"need_variant_offsets": need_variant_offsets,
		"variant_preference_q16": variant_preference,
		"variant_price_elasticity_q16": variant_elasticity,
		"variant_preference_env_curve_ids": variant_env_curve_ids,
		"variant_component_offsets": variant_component_offsets,
		"component_good_ids": component_good_ids,
		"component_qty_per_need": component_qty,
		"ethnicity_need_factor_q16": ethnicity_need_factor,
		"signature_profession_ids": signature_profession_ids,
		"signature_ethnicity_ids": signature_ethnicity_ids,
		"signature_plan_ids": signature_plan_ids,
		"signature_birth_rate_q32": signature_birth_rate_q32,
		"signature_death_rate_q32": signature_death_rate_q32,
		"signature_satisfaction_birth_weight_q16": signature_satisfaction_birth_weight_q16,
		"signature_keys": signature_keys,
	}
	for key in good_columns:
		catalog[key] = good_columns[key]
	catalog["market_catalog_hash"] = _catalog_hash(catalog)
	var building_columns := _compile_building_columns(profession_index, good_index)
	if not bool(building_columns.get("ok", false)):
		return building_columns
	building_columns.erase("ok")
	catalog["building_catalog_hash"] = _catalog_hash(building_columns)
	for key in building_columns:
		catalog[key] = building_columns[key]
	catalog["catalog_hash"] = _catalog_hash(catalog)
	catalog["ok"] = true
	return catalog

static func _compile_building_columns(profession_index: Dictionary,
		good_index: Dictionary) -> Dictionary:
	var profiles := _load_resources(BUILDING_DIR)
	var used_resource_ids := {}
	for profile in profiles:
		for resource_id in profile.resource_ids:
			used_resource_ids[String(resource_id)] = true
		for i in range(profile.condition_signals.size()):
			if int(profile.condition_signals[i]) == 10 and i < profile.condition_reference_ids.size():
				used_resource_ids[String(profile.condition_reference_ids[i])] = true
	var resources: Array = ResourceRegistryScript.ordered().duplicate()
	resources.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))
	var resource_ids := PackedStringArray()
	var resource_reserve_slots := PackedStringArray()
	var resource_extra_slots := PackedStringArray()
	var resource_index := {}
	for resource in resources:
		var stable_id := String(resource.id)
		if not used_resource_ids.has(stable_id):
			continue
		var reserve_slot: String = ResourceRegistryScript.reserve_cpp_name(resource)
		var extra_slot: String = ResourceRegistryScript.extra_change_cpp_name(resource)
		if stable_id == "" or reserve_slot == "" or extra_slot == "" or resource_index.has(stable_id):
			return {"ok": false, "reason": "invalid building resource: %s" % stable_id}
		resource_index[stable_id] = resource_ids.size()
		resource_ids.append(stable_id)
		resource_reserve_slots.append(reserve_slot)
		resource_extra_slots.append(extra_slot)

	var type_ids := PackedStringArray()
	var owner_professions := PackedInt32Array()
	var owner_slots := PackedInt64Array()
	var wages_per_employee_per_day := PackedInt64Array()
	var construction_days := PackedInt32Array()
	var behavior_ids := PackedInt32Array()
	var behavior_versions := PackedInt32Array()
	var employee_offsets := PackedInt32Array([0])
	var employee_professions := PackedInt32Array()
	var employee_slot_counts := PackedInt64Array()
	var construction_offsets := PackedInt32Array([0])
	var construction_goods := PackedInt32Array()
	var construction_quantities := PackedInt64Array()
	var input_offsets := PackedInt32Array([0])
	var input_goods := PackedInt32Array()
	var input_quantities := PackedInt64Array()
	var output_offsets := PackedInt32Array([0])
	var output_goods := PackedInt32Array()
	var output_quantities := PackedInt64Array()
	var production_resource_offsets := PackedInt32Array([0])
	var production_resources := PackedInt32Array()
	var production_resource_quantities := PackedInt64Array()
	var condition_offsets := PackedInt32Array([0])
	var condition_opcodes := PackedInt32Array()
	var condition_signals := PackedInt32Array()
	var condition_compares := PackedInt32Array()
	var condition_references := PackedInt32Array()
	var condition_values := PackedInt64Array()

	for profile in profiles:
		var stable_id := String(profile.id)
		var owner_id := String(profile.owner_profession_id)
		if stable_id == "" or type_ids.has(stable_id) or not profession_index.has(owner_id) \
				or int(profile.owner_slots_per_building) <= 0 or int(profile.construction_days) < 0:
			return {"ok": false, "reason": "invalid building type: %s" % stable_id}
		var wage_policy := String(profile.wage_policy_id)
		var wage_per_employee := int(profile.wage_per_employee_per_day)
		if wage_policy != "none" and wage_policy != "fixed":
			return {"ok": false, "reason": "unsupported building wage policy: %s" % stable_id}
		if wage_per_employee < 0 or (wage_policy == "none" and wage_per_employee != 0):
			return {"ok": false, "reason": "invalid building wage: %s" % stable_id}
		type_ids.append(stable_id)
		owner_professions.append(int(profession_index[owner_id]))
		owner_slots.append(int(profile.owner_slots_per_building))
		wages_per_employee_per_day.append(wage_per_employee if wage_policy == "fixed" else 0)
		construction_days.append(int(profile.construction_days))
		behavior_ids.append(1 if String(profile.behavior_id) == "consume_local_resources" else 0)
		behavior_versions.append(int(profile.behavior_version))

		var role_ids: PackedStringArray = profile.employee_profession_ids
		var role_slots: PackedInt64Array = profile.employee_slots_per_building
		if role_ids.size() != role_slots.size():
			return {"ok": false, "reason": "building employee columns mismatch: %s" % stable_id}
		if not role_ids.is_empty() and (wage_policy != "fixed" or wage_per_employee <= 0):
			return {"ok": false, "reason": "employee building requires fixed wage: %s" % stable_id}
		for i in range(role_ids.size()):
			var profession_id := String(role_ids[i])
			if not profession_index.has(profession_id) or int(role_slots[i]) <= 0:
				return {"ok": false, "reason": "invalid building employee role: %s" % stable_id}
			employee_professions.append(int(profession_index[profession_id]))
			employee_slot_counts.append(int(role_slots[i]))
		employee_offsets.append(employee_professions.size())

		var error := _append_building_goods(profile.construction_good_ids,
			profile.construction_quantities, good_index, construction_goods,
			construction_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		construction_offsets.append(construction_goods.size())
		error = _append_building_goods(profile.input_good_ids,
			profile.input_quantities_per_day, good_index, input_goods, input_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		input_offsets.append(input_goods.size())
		error = _append_building_goods(profile.output_good_ids,
			profile.output_quantities_per_day, good_index, output_goods, output_quantities)
		if error != "": return {"ok": false, "reason": "%s: %s" % [error, stable_id]}
		output_offsets.append(output_goods.size())

		var prod_ids: PackedStringArray = profile.resource_ids
		var prod_qty: PackedInt64Array = profile.resource_quantities_per_day
		if prod_ids.size() != prod_qty.size():
			return {"ok": false, "reason": "building resource columns mismatch: %s" % stable_id}
		for i in range(prod_ids.size()):
			var resource_id := String(prod_ids[i])
			if not resource_index.has(resource_id) or int(prod_qty[i]) <= 0:
				return {"ok": false, "reason": "invalid building production resource: %s" % stable_id}
			production_resources.append(int(resource_index[resource_id]))
			production_resource_quantities.append(int(prod_qty[i]))
		production_resource_offsets.append(production_resources.size())

		var ops: PackedInt32Array = profile.condition_opcodes
		var signals: PackedInt32Array = profile.condition_signals
		var compares: PackedInt32Array = profile.condition_compares
		var refs: PackedStringArray = profile.condition_reference_ids
		var values: PackedInt64Array = profile.condition_values
		if ops.size() != signals.size() or ops.size() != compares.size() \
				or ops.size() != refs.size() or ops.size() != values.size():
			return {"ok": false, "reason": "building condition columns mismatch: %s" % stable_id}
		var depth := 0
		for i in range(ops.size()):
			var opcode := int(ops[i])
			if opcode == 1:
				depth += 1
			elif opcode == 4:
				if depth < 1: return {"ok": false, "reason": "building condition stack underflow: %s" % stable_id}
			elif opcode == 2 or opcode == 3:
				if depth < 2: return {"ok": false, "reason": "building condition stack underflow: %s" % stable_id}
				depth -= 1
			else:
				return {"ok": false, "reason": "building condition opcode invalid: %s" % stable_id}
			var reference := -1
			if int(signals[i]) == 10:
				var ref_id := String(refs[i])
				if not resource_index.has(ref_id):
					return {"ok": false, "reason": "building condition resource missing: %s" % stable_id}
				reference = int(resource_index[ref_id])
			condition_opcodes.append(opcode)
			condition_signals.append(int(signals[i]))
			condition_compares.append(int(compares[i]))
			condition_references.append(reference)
			condition_values.append(int(values[i]))
		if not ops.is_empty() and depth != 1:
			return {"ok": false, "reason": "building condition postfix invalid: %s" % stable_id}
		condition_offsets.append(condition_opcodes.size())

	return {
		"ok": true,
		"building_type_ids": type_ids,
		"building_owner_profession_ids": owner_professions,
		"building_owner_slots": owner_slots,
		"building_wage_per_employee_per_day": wages_per_employee_per_day,
		"building_construction_days": construction_days,
		"building_behavior_ids": behavior_ids,
		"building_behavior_versions": behavior_versions,
		"building_employee_offsets": employee_offsets,
		"building_employee_profession_ids": employee_professions,
		"building_employee_slots": employee_slot_counts,
		"building_construction_offsets": construction_offsets,
		"building_construction_good_ids": construction_goods,
		"building_construction_quantities": construction_quantities,
		"building_input_offsets": input_offsets,
		"building_input_good_ids": input_goods,
		"building_input_quantities": input_quantities,
		"building_output_offsets": output_offsets,
		"building_output_good_ids": output_goods,
		"building_output_quantities": output_quantities,
		"building_resource_ids": resource_ids,
		"building_resource_reserve_slots": resource_reserve_slots,
		"building_resource_extra_slots": resource_extra_slots,
		"building_resource_offsets": production_resource_offsets,
		"building_production_resource_ids": production_resources,
		"building_production_resource_quantities": production_resource_quantities,
		"building_condition_offsets": condition_offsets,
		"building_condition_opcodes": condition_opcodes,
		"building_condition_signals": condition_signals,
		"building_condition_compares": condition_compares,
		"building_condition_references": condition_references,
		"building_condition_values": condition_values,
	}

static func _append_building_goods(ids: PackedStringArray, quantities: PackedInt64Array,
		good_index: Dictionary, out_ids: PackedInt32Array,
		out_quantities: PackedInt64Array) -> String:
	if ids.size() != quantities.size():
		return "building good columns mismatch"
	for i in range(ids.size()):
		var stable_id := String(ids[i])
		if not good_index.has(stable_id) or int(quantities[i]) <= 0:
			return "invalid building good"
		out_ids.append(int(good_index[stable_id]))
		out_quantities.append(int(quantities[i]))
	return ""

static func _load_resources(dir_path: String) -> Array:
	var paths := PackedStringArray()
	for file_name in DirAccess.get_files_at(dir_path):
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [dir_path, file_name])
	paths.sort()
	var out := []
	for path in paths:
		var resource = ResourceLoader.load(path, "Resource")
		if resource != null and String(resource.get("id")) != "":
			out.append(resource)
	out.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))
	return out

static func _index_ids(ids: PackedStringArray) -> Dictionary:
	var out := {}
	for i in range(ids.size()):
		if String(ids[i]) == "" or out.has(String(ids[i])):
			return {}
		out[String(ids[i])] = i
	return out

static func _optional_index(index: Dictionary, id_value: String) -> int:
	if id_value == "":
		return -1
	return int(index.get(id_value, -2))

static func _catalog_hash(catalog: Dictionary) -> int:
	var keys := catalog.keys()
	keys.sort_custom(func(a, b) -> bool: return String(a) < String(b))
	var canonical := "economy-catalog-v2\n"
	for key in keys:
		canonical += "%s=%s\n" % [String(key), var_to_str(catalog[key])]
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(canonical.to_utf8_buffer())
	var digest := hashing.finish()
	var value: int = 0
	for i in range(7):
		value = (value << 8) | int(digest[i])
	return maxi(1, value)
