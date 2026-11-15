class_name MilitaryCatalogSupport
extends RefCounted

const SUPPLY_CLASS_COUNT := 6


## Returns the concrete dense goods a slot may accept. Core slots enforce the
## authored minimum quality; secondary slots may use every good in the
## category, with procurement preferring goods that meet the minimum first.
## This is shared by the runtime-facing audits so they keep the same contract.
static func slot_accepted_goods(slot: Dictionary, category: Dictionary) -> PackedInt32Array:
	var goods: PackedInt32Array = category.get("goods", PackedInt32Array())
	var qualities: PackedInt32Array = category.get("qualities", PackedInt32Array())
	var out := PackedInt32Array()
	var core := bool(slot.get("core", false))
	var minimum := clampi(int(slot.get("min_quality", 1)), 1, 5)
	for index in range(goods.size()):
		if not core or (index < qualities.size() and int(qualities[index]) >= minimum):
			out.append(int(goods[index]))
	return out


## Every dense good a compiled unit consumes: goods its equipment slots accept,
## its repair goods, and the candidates of each supply class it draws. The
## audits use this to count the army as a consumer.
static func unit_consumed_goods(military: Dictionary, unit: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for slot_value in unit.equipment:
		var slot: Dictionary = slot_value
		out.append_array(slot_accepted_goods(slot, military.categories[int(slot.category)]))
	out.append_array(PackedInt32Array(unit.repair_goods))
	var idle: PackedFloat32Array = unit.supply_idle
	var combat: PackedFloat32Array = unit.supply_combat
	for supply_class in range(idle.size()):
		if idle[supply_class] > 0.0 or combat[supply_class] > 0.0:
			out.append_array(PackedInt32Array(military.supply_goods[supply_class]))
	return out


static func _catalog_hash(compiled: Dictionary, good_ids: PackedStringArray,
		tech_ids: PackedStringArray) -> int:
	# Stable across machines and dictionary insertion order: FNV-1a over the
	# resolved dense columns only (an authored rename that keeps the same dense
	# ids must not change the hash).
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hash_mix(hasher, "pkmi.catalog.v1")
	hash_mix(hasher, str(compiled.get("economy_good_count", 0)))
	hash_mix(hasher, str(compiled.get("soldier_profession_id", -1)))
	hash_mix(hasher, str(compiled.get("unemployed_profession_id", -1)))
	hash_mix(hasher, str(compiled.get("ration_need_per_head", 0)))
	for unit_value in compiled.get("units", []):
		var unit: Dictionary = unit_value
		hash_mix(hasher, String(unit.get("id", "")))
		hash_mix(hasher, str(int(unit.get("class", 0))))
		hash_mix(hasher, str(int(unit.get("unlock_bit", -1))))
		hash_mix(hasher, str(int(unit.get("era", 0))))
		for row_value in unit.get("equipment", []):
			var row: Dictionary = row_value
			hash_mix(hasher, "%d:%d:%d:%.6f:%.6f" % [int(row.get("category", -1)),
				1 if bool(row.get("core", false)) else 0,
				int(row.get("min_quality", 1)), float(row.get("per_100", 0.0)),
				float(row.get("weight", 1.0))])
		var idle: PackedFloat32Array = unit.get("supply_idle", PackedFloat32Array())
		var combat: PackedFloat32Array = unit.get("supply_combat", PackedFloat32Array())
		for k in range(mini(SUPPLY_CLASS_COUNT, idle.size())):
			hash_mix(hasher, "i%.6f" % float(idle[k]))
		for k in range(mini(SUPPLY_CLASS_COUNT, combat.size())):
			hash_mix(hasher, "c%.6f" % float(combat[k]))
		# Physical repair recipe: size first (so an empty row and a row of
		# zero-rate entries hash differently), then every dense good id with
		# its frozen rate.
		var repair_goods: PackedInt32Array = unit.get("repair_goods",
			PackedInt32Array())
		var repair_rate: PackedInt64Array = unit.get("repair_rate_q32",
			PackedInt64Array())
		hash_mix(hasher, "r%d" % repair_goods.size())
		for k in range(repair_goods.size()):
			hash_mix(hasher, "%d:%d" % [int(repair_goods[k]),
				int(repair_rate[k]) if k < repair_rate.size() else 0])
	for category_value in compiled.get("categories", []):
		var category: Dictionary = category_value
		hash_mix(hasher, String(category.get("id", "")))
		var goods: PackedInt32Array = category.get("goods", PackedInt32Array())
		var qualities: PackedInt32Array = category.get("qualities", PackedInt32Array())
		for k in range(goods.size()):
			hash_mix(hasher, "%d:%d" % [int(goods[k]),
				int(qualities[k]) if k < qualities.size() else 1])
	for building_value in compiled.get("state_buildings", []):
		var building: Dictionary = building_value
		hash_mix(hasher, String(building.get("id", "")))
		hash_mix(hasher, str(int(building.get("role", 0))))
		hash_mix(hasher, str(int(building.get("capacity", 0))))
		# The economy bridge is part of the identity. Two catalogs that point
		# the same lot at different economy building types describe different
		# worlds, and `MilitaryCore::catalog_hash()` (military_core.cpp) mixes
		# this column too: leaving it out here would let a bridge-only edit look
		# content-identical on this side while PKMI loads keep failing.
		hash_mix(hasher, str(int(building.get("economy_building_id", -1))))
		var repair_goods: PackedInt32Array = building.get("repair_goods",
			PackedInt32Array())
		var repair_rate: PackedInt64Array = building.get("repair_rate_q32",
			PackedInt64Array())
		hash_mix(hasher, "r%d" % repair_goods.size())
		for k in range(repair_goods.size()):
			hash_mix(hasher, "%d:%d" % [int(repair_goods[k]),
				int(repair_rate[k]) if k < repair_rate.size() else 0])
	var unlock: PackedInt32Array = compiled.get("unlock_tech_ids", PackedInt32Array())
	for dense in unlock:
		hash_mix(hasher, "%d:%s" % [int(dense),
			String(tech_ids[int(dense)]) if int(dense) < tech_ids.size() else ""])
	for supply_class in range(SUPPLY_CLASS_COUNT):
		var goods: PackedInt32Array = (compiled.get("supply_goods", []) as Array)[
			supply_class]
		var yields: PackedInt32Array = (compiled.get("supply_yield_q16", []) as Array)[
			supply_class]
		for k in range(goods.size()):
			hash_mix(hasher, "s%d:%d:%d" % [supply_class, int(goods[k]),
				int(yields[k]) if k < yields.size() else 0])
	var digest := hasher.finish()
	var value := 0
	for byte in digest:
		value = (value * 1099511628211 + int(byte)) & 0x7FFFFFFFFFFFFFFF
	return value


static func hash_mix(hasher: HashingContext, text: String) -> void:
	hasher.update(text.to_utf8_buffer())
	hasher.update(PackedByteArray([0]))
