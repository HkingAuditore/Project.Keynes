extends RefCounted

## Shared limits and stable identifier lookups for military catalog compilation.

const ROLE_IDS := ["barracks", "fortification", "war_college"]
const ECONOMY_BUILDING_KIND_STATE := 3
const MAX_FORT_BONUS := 10.0
const MAX_TRAINING_SPEED := 10.0
const MAX_BUILDING_UPKEEP := 100.0
const MAX_MATERIAL_UNITS := 1000.0
const MAX_REPAIR_SLOTS := 4
const REPAIR_Q32_ONE := 4294967296.0
const REPAIR_MILLI_GOODS := 1000.0
const REPAIR_MONEY_SCALE := 10000.0
const SUPPLY_CLASS_COUNT := 6
const SUPPLY_RATION := 0
const SUPPLY_FODDER := 1
const SUPPLY_AMMUNITION := 2
const SUPPLY_FUEL := 3
const SUPPLY_UPKEEP := 4
const SUPPLY_CLASS_IDS: Array[String] = [
	"ration", "fodder", "ammunition", "fuel", "upkeep", "equipment"]
const MAX_UNITS := 64
const ROLE_BARRACKS := 0


static func _resolve_unlock(tech_id: String, tech_index: Dictionary,
		unlock_tech_ids: PackedInt32Array, unlock_bits: Dictionary) -> Dictionary:
	if not unlock_bits.has(tech_id):
		var dense := _index_optional(tech_index, tech_id)
		if dense < 0:
			return _fail("military_unlock_technology_unknown: %s" % tech_id)
		unlock_bits[tech_id] = unlock_tech_ids.size()
		unlock_tech_ids.append(dense)
	return {
		"ok": true,
		"bit": int(unlock_bits[tech_id]),
		"unlock_tech_ids": unlock_tech_ids,
		"unlock_bits": unlock_bits,
	}


static func _index_of(ids: PackedStringArray) -> Dictionary:
	var index := {}
	for i in range(ids.size()):
		index[String(ids[i])] = i
	return index


static func _index_optional(index: Dictionary, id_value: String) -> int:
	return int(index.get(id_value, -1))


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
