extends RefCounted

## Compiles state buildings and repair requirements from authored catalog rows.

const CatalogSchema = preload("res://scripts/military/military_catalog_schema.gd")


static func _compile_state_buildings(raw_buildings, good_index: Dictionary,
		good_default_price: PackedInt32Array,
		building_type_ids: PackedStringArray, tech_index: Dictionary,
		unlock_tech_ids: PackedInt32Array, unlock_bits: Dictionary,
		economy_tag_offsets: PackedInt32Array = PackedInt32Array(),
		economy_tags: PackedStringArray = PackedStringArray(),
		economy_kinds: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var building_index := CatalogSchema._index_of(building_type_ids)
	var out: Array = []
	var seen := {}
	var ordered_unlock_tech := unlock_tech_ids
	var ordered_bits := unlock_bits
	for raw_value in raw_buildings:
		if not raw_value is Dictionary:
			return CatalogSchema._fail("military_state_building_not_object")
		var raw: Dictionary = raw_value
		var building_id := String(raw.get("id", "")).strip_edges()
		if building_id.is_empty() or seen.has(building_id):
			return CatalogSchema._fail("military_state_building_id_invalid")
		seen[building_id] = true
		var role_id := String(raw.get("role", "barracks")).strip_edges()
		var role := CatalogSchema.ROLE_IDS.find(role_id)
		if role < 0:
			return CatalogSchema._fail("military_state_building_role_invalid: %s" % building_id)
		var unlock_bit := -1
		var tech_id := String(raw.get("tech", "")).strip_edges()
		# Design §1.4: every state lot is gated by a technology. An empty
		# `tech` used to mean "always buildable", which silently shipped a
		# free barracks alongside the researched ones.
		if tech_id.is_empty():
			return CatalogSchema._fail("military_state_building_technology_missing: %s"
				% building_id)
		# Bridge to the economy catalog (design §5.1/§5.2/§5.4). The dense
		# economy building type index is the only handle either runtime may
		# use to name "this same lot": it is what `building_commit` keys the
		# ledger on, what the construction workspace offers, and what the
		# derived `barracks_count` / `fort_tier` / `college_tier` read back.
		# Resolving by stable id keeps the two catalogs independent; a -1
		# placeholder would instead let the military side invent a lot that
		# no economy group exists for, so it is a hard failure here.
		var economy_building := CatalogSchema._index_optional(building_index, building_id)
		if economy_building < 0:
			return CatalogSchema._fail(
				"military_state_building_without_economy_profile: %s"
				% building_id)
		if not economy_kinds.is_empty():
			if economy_building >= economy_kinds.size():
				return CatalogSchema._fail(
					"military_state_building_economy_columns_ragged: %s"
					% building_id)
			var economy_kind := int(economy_kinds[economy_building])
			if economy_kind != CatalogSchema.ECONOMY_BUILDING_KIND_STATE:
				return CatalogSchema._fail(
					"military_state_building_economy_kind_invalid: %s (kind=%d)"
					% [building_id, economy_kind])
		var bit_result := CatalogSchema._resolve_unlock(tech_id, tech_index,
			ordered_unlock_tech, ordered_bits)
		if not bool(bit_result.get("ok", false)):
			return bit_result
		ordered_unlock_tech = bit_result.get("unlock_tech_ids",
			ordered_unlock_tech)
		ordered_bits = bit_result.get("unlock_bits", ordered_bits)
		unlock_bit = int(bit_result.get("bit", -1))
		# Design §1.4/§1.5: this catalog and the economy building profile are
		# two separate content files that must agree on the one technology
		# unlocking the lot. If they drift, the construction workspace and
		# the military roster advertise different gates for the same
		# building. Reported against the building id: it is an authoring
		# error in that pair, not a catalog-wide one.
		if not economy_tag_offsets.is_empty():
			if economy_building + 1 >= economy_tag_offsets.size():
				return CatalogSchema._fail(
					"military_state_building_technology_columns_ragged: %s"
					% building_id)
			var economy_technology_ids := PackedStringArray()
			var economy_tag_begin := int(economy_tag_offsets[economy_building])
			var economy_tag_end := int(economy_tag_offsets[economy_building + 1])
			if economy_tag_begin < 0 or economy_tag_end > economy_tags.size():
				return CatalogSchema._fail(
					"military_state_building_technology_columns_ragged: %s"
					% building_id)
			for economy_tag_index in range(economy_tag_begin, economy_tag_end):
				var economy_tag := String(
					economy_tags[economy_tag_index]).strip_edges()
				if economy_tag.begins_with("tech."):
					economy_technology_ids.append(economy_tag)
			if economy_technology_ids.size() != 1:
				return CatalogSchema._fail(
					"military_state_building_technology_count_invalid: %s (%d)"
					% [building_id, economy_technology_ids.size()])
			if economy_technology_ids[0] != tech_id:
				return CatalogSchema._fail(
					("military_state_building_technology_mismatch: %s "
						+ "(military=%s economy=%s)")
					% [building_id, tech_id, economy_technology_ids[0]])
		var fort_bonus := maxf(0.0, float(raw.get("fort_bonus", 0.0)))
		var training_speed := maxf(0.0, float(raw.get("training_speed", 1.0)))
		var upkeep := maxf(0.0, float(raw.get("upkeep", 0.0)))
		# Scale check: these columns are authored human-readable and multiplied by
		# q16 / MONEY_SCALE exactly once downstream. A value above the design
		# ceiling means the column was written in its internal fixed-point form,
		# which would render as `守备 +1966100%` and clamp training to int32 max.
		if fort_bonus > CatalogSchema.MAX_FORT_BONUS:
			return CatalogSchema._fail("military_state_building_fort_bonus_out_of_range: %s (%s)"
				% [building_id, str(fort_bonus)])
		if training_speed > CatalogSchema.MAX_TRAINING_SPEED:
			return CatalogSchema._fail("military_state_building_training_speed_out_of_range: %s (%s)"
				% [building_id, str(training_speed)])
		if upkeep > CatalogSchema.MAX_BUILDING_UPKEEP:
			return CatalogSchema._fail("military_state_building_upkeep_out_of_range: %s (%s)"
				% [building_id, str(upkeep)])
		var material_goods := PackedInt32Array()
		var material_qty := PackedInt64Array()
		var materials: Dictionary = raw.get("materials", {})
		for good_key in materials.keys():
			var good := CatalogSchema._index_optional(good_index, String(good_key))
			if good < 0:
				return CatalogSchema._fail("military_state_building_material_unknown: %s" % String(
					good_key))
			var material_units := maxf(0.0, float(materials[good_key]))
			if material_units > CatalogSchema.MAX_MATERIAL_UNITS:
				return CatalogSchema._fail(
					"military_state_building_material_out_of_range: %s.%s (%s)"
					% [building_id, String(good_key), str(material_units)])
			material_goods.append(good)
			material_qty.append(maxi(0, int(round(material_units * 1000.0))))
		# Physical repair materials. The IDLE building upkeep (money units per
		# day) is converted into goods through each good's `default_price`;
		# `upkeep` itself stays authored because the legacy cash path still
		# settles it until the follow-up stage removes it.
		var repair := _compile_repair(raw.get("repair", {}), good_index,
			building_id, good_default_price, upkeep, true)
		if not bool(repair.get("ok", false)):
			return repair
		out.append({
			"id": building_id,
			"name": String(raw.get("name", "")).strip_edges(),
			"economy_building_id": economy_building,
			"role": role,
			"tier": clampi(int(raw.get("tier", 0)), 0, 7),
			"unlock_bit": unlock_bit,
			# Authored stable technology id behind `unlock_bit` ("" = always
			# available). UI-only label so a gate never has to reverse the dense
			# id table; it is not part of the catalog hash.
			"unlock_tech_id": tech_id,
			"capacity": maxi(0, int(raw.get("capacity", 0))),
			"fort_bonus": fort_bonus,
			"training_speed": training_speed,
			"upkeep": upkeep,
			"build_days": maxi(0, int(raw.get("build_days", 0))),
			"material_goods": material_goods,
			"material_qty": material_qty,
			# Dense repair goods and their per-day physical rate, parallel and
			# in authored order (same q32-of-milli-goods unit as the units).
			"repair_goods": PackedInt32Array(
				repair.get("goods", PackedInt32Array())),
			"repair_rate_q32": PackedInt64Array(
				repair.get("rate_q32", PackedInt64Array())),
		})
	return {
		"ok": true,
		"state_buildings": out,
		"unlock_tech_ids": ordered_unlock_tech,
		"unlock_bits": ordered_bits,
	}


## Resolves one authored `"repair": { "goods": [{good, weight}, ...] }` recipe
## into the two parallel packed columns the native runtime reads
## (`repair_goods` / `repair_rate_q32`), in authored order.
##
## `intensity` is the authored daily service level of the owner:
##   - state building: cash `upkeep` in money units per day, converted to goods
##     through the good's `default_price` (`scale_by_price = true`):
##       daily_goods = upkeep * w / sum_w * 10000 / default_price
##   - unit: `supply_idle.upkeep`, already authored in goods units per 100
##     heads per day, so the ratio is used as-is (`scale_by_price = false`):
##       daily_goods = idle_upkeep * w / sum_w
## Both land in the same unit: `rate_q32` is q32 of ONE MILLI-GOOD per day,
## i.e. `round(daily_goods * 1000 * 2^32)`. A positive weight whose rate rounds
## to zero is intentionally allowed - the native side accumulates a fractional
## remainder, so a tiny lot is not forced to consume a whole item per day. A
## zero service level (militia) ships empty columns instead of zero-rate rows.
static func _compile_repair(raw_repair, good_index: Dictionary, owner_id: String,
		good_default_price: PackedInt32Array, intensity: float,
		scale_by_price: bool) -> Dictionary:
	var goods := PackedInt32Array()
	var rate_q32 := PackedInt64Array()
	if raw_repair == null:
		return {"ok": true, "goods": goods, "rate_q32": rate_q32}
	if not raw_repair is Dictionary:
		return CatalogSchema._fail("military_repair_not_object: %s" % owner_id)
	var recipe: Dictionary = raw_repair
	var raw_rows = recipe.get("goods", [])
	if not raw_rows is Array:
		return CatalogSchema._fail("military_repair_goods_not_array: %s" % owner_id)
	var rows: Array = raw_rows
	# The native slots are fixed at four entries per owner.
	if rows.size() > CatalogSchema.MAX_REPAIR_SLOTS:
		return CatalogSchema._fail("military_repair_overflow: %s (%d)"
			% [owner_id, rows.size()])
	if rows.is_empty():
		return {"ok": true, "goods": goods, "rate_q32": rate_q32}
	var weights := PackedFloat64Array()
	var resolved_ids: Array[String] = []
	var seen := {}
	var weight_sum := 0.0
	for row_value in rows:
		if not row_value is Dictionary:
			return CatalogSchema._fail("military_repair_good_not_object: %s" % owner_id)
		var row: Dictionary = row_value
		var good_id := String(row.get("good", "")).strip_edges()
		var good := CatalogSchema._index_optional(good_index, good_id)
		if good < 0:
			return CatalogSchema._fail("military_repair_good_unknown: %s:%s"
				% [owner_id, good_id])
		if seen.has(good):
			return CatalogSchema._fail("military_repair_good_duplicate: %s:%s"
				% [owner_id, good_id])
		seen[good] = true
		var weight := float(row.get("weight", 0.0))
		if weight <= 0.0:
			return CatalogSchema._fail("military_repair_weight_invalid: %s:%s (%s)"
				% [owner_id, good_id, str(weight)])
		goods.append(good)
		weights.append(weight)
		resolved_ids.append(good_id)
		weight_sum += weight
	# A zero price would make the cash -> goods conversion undefined; the native
	# side has no fallback, so a bad row must never reach it.
	var prices := PackedInt64Array()
	for k in range(goods.size()):
		var good := int(goods[k])
		if good >= good_default_price.size():
			return CatalogSchema._fail("military_repair_price_missing: %s:%s"
				% [owner_id, resolved_ids[k]])
		var price := int(good_default_price[good])
		if price <= 0:
			return CatalogSchema._fail("military_repair_price_missing: %s:%s (%d)"
				% [owner_id, resolved_ids[k], price])
		prices.append(price)
	# Zero service level: nothing to maintain. Checked after validation so a
	# broken recipe still fails loudly even on a free lot.
	if intensity <= 0.0:
		return {"ok": true, "goods": PackedInt32Array(),
			"rate_q32": PackedInt64Array()}
	for k in range(goods.size()):
		var daily_goods := intensity * float(weights[k]) / weight_sum
		if scale_by_price:
			daily_goods = daily_goods * CatalogSchema.REPAIR_MONEY_SCALE \
				/ float(prices[k])
		rate_q32.append(maxi(0, int(round(
			daily_goods * CatalogSchema.REPAIR_MILLI_GOODS * CatalogSchema.REPAIR_Q32_ONE))))
	return {"ok": true, "goods": goods, "rate_q32": rate_q32}


## Ration candidates come straight from the `soldier_household` consumption plan
## so a change to the staple/protein variants can never drift from the army's
## actual field ration (design §9.2 "口粮折算").
