extends SceneTree

## Read-only audit: survival-food yield per worker for every food-producing
## building, the technology/era that unlocks it, and every technology modifier
## term that touches survival food goods, agriculture or population.
## Run: godot --headless --path Project/project-keynes --script res://tools/food_yield_audit.gd

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const NETWORK_DATA_PATH := "res://data/technology/technology_network.json"
const FOOD_NEEDS := ["staple_food", "protein", "produce"]
const BASE_PLAN := "survival_household"
const GOODS_SCALE := 1000


func _init() -> void:
	var cat: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(cat.get("ok", false)):
		print("[food-audit] catalog failed: ", cat.get("reason", ""))
		quit(1)
		return
	var good_ids: PackedStringArray = cat.good_ids
	var need_ids: PackedStringArray = cat.need_ids
	var plan_ids: PackedStringArray = cat.plan_ids
	var plan_need_offsets: PackedInt32Array = cat.plan_need_offsets
	var need_stable: PackedInt32Array = cat.need_stable_ids
	var need_base_qty: PackedInt64Array = cat.need_base_qty_per_person
	var need_variant_offsets: PackedInt32Array = cat.need_variant_offsets
	var variant_component_offsets: PackedInt32Array = cat.variant_component_offsets
	var component_goods: PackedInt32Array = cat.component_good_ids
	var component_qty: PackedInt64Array = cat.component_qty_per_need

	var food_need_stable := {}
	for i in range(need_ids.size()):
		if FOOD_NEEDS.has(String(need_ids[i])):
			food_need_stable[i] = String(need_ids[i])
	var food_per_unit := {}
	var food_need_of := {}
	for entry in range(need_stable.size()):
		if not food_need_stable.has(int(need_stable[entry])):
			continue
		for v in range(int(need_variant_offsets[entry]), int(need_variant_offsets[entry + 1])):
			var c := int(variant_component_offsets[v])
			var g := int(component_goods[c])
			var q := int(component_qty[c])
			if q > 0:
				food_per_unit[g] = float(GOODS_SCALE) / float(q)
				food_need_of[g] = food_need_stable[int(need_stable[entry])]
	var ration := 0
	var base_plan := plan_ids.find(BASE_PLAN)
	for entry in range(int(plan_need_offsets[base_plan]), int(plan_need_offsets[base_plan + 1])):
		if food_need_stable.has(int(need_stable[entry])):
			ration += int(need_base_qty[entry])
	print("[food-audit] ration_per_person_per_day=%d food_goods=%d" % [ration, food_per_unit.size()])
	for g in food_per_unit.keys():
		print("[food-audit/good] good=%s need=%s food_per_subunit=%.4f" % [
			good_ids[int(g)], food_need_of[g], float(food_per_unit[g])])

	var network := _load_network()
	var unlock_tech := {}
	var tech_era := {}
	var food_terms: Array = []
	for node_value in network.get("nodes", []):
		var node: Dictionary = node_value
		var tech_id := String(node.get("id", ""))
		tech_era[tech_id] = String(node.get("era_id", ""))
		for effect_value in node.get("content_effects", []):
			var effect: Dictionary = effect_value
			if String(effect.get("kind", "")) == "building" \
					and String(effect.get("operation", "")) == "unlock":
				var b := String(effect.get("id", ""))
				if not unlock_tech.has(b):
					unlock_tech[b] = []
				(unlock_tech[b] as Array).append(tech_id)
		for term_value in node.get("modifier_terms", []):
			var term: Dictionary = term_value
			var stat := String(term.get("stat", ""))
			var subject := String(term.get("subject_id", ""))
			var good_idx := good_ids.find(subject)
			var touches_food := good_idx >= 0 and food_per_unit.has(good_idx)
			var keyword := stat.contains("birth") or stat.contains("carrying") \
				or stat.contains("agri") or stat.contains("food") or stat.contains("farm") \
				or stat.contains("death") or stat.contains("fertil") or stat.contains("harvest")
			if touches_food or keyword:
				food_terms.append([String(node.get("era_id", "")), tech_id, stat,
					float(term.get("operation", 0.0)), float(term.get("value", 0.0)), subject])

	var type_ids: PackedStringArray = cat.building_type_ids
	var kinds = cat.building_kinds
	var owner_slots: PackedInt64Array = cat.building_owner_slots
	var emp_off: PackedInt32Array = cat.building_employee_offsets
	var emp_slots: PackedInt64Array = cat.building_employee_slots
	var out_off: PackedInt32Array = cat.building_output_offsets
	var out_goods: PackedInt32Array = cat.building_output_good_ids
	var out_qty: PackedInt64Array = cat.building_output_quantities
	var in_off: PackedInt32Array = cat.building_input_offsets
	var in_goods: PackedInt32Array = cat.building_input_good_ids
	var in_qty: PackedInt64Array = cat.building_input_quantities
	var in_req: PackedInt32Array = cat.building_input_required_q16
	var res_off: PackedInt32Array = cat.building_resource_offsets
	var res_ids: PackedInt32Array = cat.building_production_resource_ids
	var res_qty: PackedInt64Array = cat.building_production_resource_quantities
	var res_modes: PackedInt32Array = cat.building_production_resource_modes
	var resource_names: PackedStringArray = cat.get("resource_ids", PackedStringArray())
	for t in range(type_ids.size()):
		var food := 0.0
		var outs := PackedStringArray()
		for o in range(int(out_off[t]), int(out_off[t + 1])):
			var g := int(out_goods[o])
			if food_per_unit.has(g):
				food += float(out_qty[o]) * float(food_per_unit[g])
			outs.append("%s:%d" % [good_ids[g], int(out_qty[o])])
		if food <= 0.0:
			continue
		var food_in := 0.0
		var ins := PackedStringArray()
		for i in range(int(in_off[t]), int(in_off[t + 1])):
			var g := int(in_goods[i])
			if food_per_unit.has(g):
				food_in += float(in_qty[i]) * float(food_per_unit[g]) * float(in_req[i]) / 65536.0
			ins.append("%s:%d@%.2f" % [good_ids[g], int(in_qty[i]), float(in_req[i]) / 65536.0])
		var workers := int(owner_slots[t])
		for e in range(int(emp_off[t]), int(emp_off[t + 1])):
			workers += int(emp_slots[e])
		var res := PackedStringArray()
		for r in range(int(res_off[t]), int(res_off[t + 1])):
			var rid := int(res_ids[r])
			var rname := resource_names[rid] if rid >= 0 and rid < resource_names.size() else str(rid)
			res.append("%s:%d/m%d" % [rname, int(res_qty[r]), int(res_modes[r])])
		var techs: Array = unlock_tech.get(String(type_ids[t]), [])
		var eras := PackedStringArray()
		for tech in techs:
			eras.append(String(tech_era.get(tech, "?")))
		var net := food - food_in
		print("[food-audit/building] id=%s kind=%s era=%s tech=%s workers=%d food_net_per_day=%.1f fed_per_building=%.2f fed_per_worker=%.2f outputs=%s inputs=%s resources=%s" % [
			type_ids[t], kinds[t], ",".join(eras), ",".join(PackedStringArray(techs)), workers,
			net, net / maxf(1.0, float(ration)), net / maxf(1.0, float(ration)) / maxf(1.0, float(workers)),
			",".join(outs), ",".join(ins), ",".join(res)])
	for row in food_terms:
		print("[food-audit/term] era=%s tech=%s stat=%s op=%.0f value=%.4f subject=%s" % row)
	quit(0)


func _load_network() -> Dictionary:
	var file := FileAccess.open(NETWORK_DATA_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}
