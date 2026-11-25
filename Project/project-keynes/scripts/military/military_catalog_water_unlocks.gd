extends RefCounted


## Resolves the four water-tier bits from the catalog's `unlock_tech_ids` array,
## in that order: 0 = lake (`tech.river_transport`), 1 = shallow sea
## (`tech.military.coastal_transport`), 2 = far sea (`tech.celestial_navigation`),
## 3 = deep sea (`tech.oceanic_ship_design`). The tier of a tree cell comes from
## its landform (gdext/src/water_tier.h); a country may enter any tier at or
## below the highest one it unlocked. Must run after every unit/building
## reference so no existing unlock bit moves. A missing or empty entry leaves
## that tier closed (-1).
static func _compile_water_unlocks(raw_ids, tech_index: Dictionary,
		unlock_tech_ids: PackedInt32Array, unlock_bits: Dictionary, resolve_unlock: Callable) -> Dictionary:
	var ordered_tech := unlock_tech_ids
	var ordered_bits := unlock_bits
	var bits := PackedInt32Array([-1, -1, -1, -1])
	var rows: Array = raw_ids if raw_ids is Array else []
	for index in range(mini(rows.size(), bits.size())):
		var tech_id := String(rows[index]).strip_edges()
		if tech_id.is_empty():
			continue
		var bit_result: Dictionary = resolve_unlock.call(tech_id, tech_index, ordered_tech, ordered_bits)
		if not bool(bit_result.get("ok", false)):
			return bit_result
		ordered_tech = bit_result.get("unlock_tech_ids", ordered_tech)
		ordered_bits = bit_result.get("unlock_bits", ordered_bits)
		bits[index] = int(bit_result.get("bit", -1))
	return {
		"ok": true,
		"unlock_tech_ids": ordered_tech,
		"unlock_bits": ordered_bits,
		"water_lake_bit": int(bits[0]),
		"water_shallow_bit": int(bits[1]),
		"water_far_bit": int(bits[2]),
		"water_deep_bit": int(bits[3]),
	}
