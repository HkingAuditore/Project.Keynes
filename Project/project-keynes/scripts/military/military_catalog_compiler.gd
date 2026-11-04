class_name MilitaryCatalogCompiler
extends RefCounted

## Compiles `data/military/military_catalog.json` into the dense-id dictionary the
## native bridge consumes (`DCWorldExt.configure_military(catalog, seed)`).
##
## The authored catalog speaks stable string ids (`grain`, `tech.bronze_casting`);
## the native runtime only speaks dense ints. Everything here is the cold
## generation/restore path: no hot loop, no per-frame cost.
##
## Output contract (frozen by docs/plans/military-implementation-contract.md §3):
##   ok, reason, schema, catalog_hash,
##   units: Array[Dictionary]  { id, name, description, tech, class, militia,
##                               era, unlock_bit, attack, defense, speed,
##                               fortification_ignore, training_days,
##                               equipment:[{category, min_quality, per_100, weight}],
##                               supply_idle / supply_combat:
##                               PackedFloat32Array(6) in MILITARY_SUPPLY_* order }
##                               -> order: ration, fodder, ammunition, fuel,
##                                          upkeep, equipment
##   categories: Array[Dictionary] { id, name, goods:PackedInt32Array,
##                                   qualities:PackedInt32Array }
##   state_buildings: Array[Dictionary]
##   supply_goods: Array (6) of PackedInt32Array   (dense good ids)
##   supply_yield_q16: Array (6) of PackedInt32Array (q16 per good, 65536 = 1:1)
##   unlock_tech_ids: PackedInt32Array   (dense technology ids, index == unlock_bit)
##   coastal_transport_bit / ocean_transport_bit: int  (see "naval transport" below;
##                               -1 = the catalog does not grant sea movement)
##   economy_good_count, soldier_profession_id, unemployed_profession_id,
##   ration_need_per_head
##
## Naval transport (army-personnel contract 2 §2.2): the top-level
## `unlock_tech_ids` array names the `tech.military.coastal_transport` /
## `tech.military.naval_transport` ids in that order. Their bits are appended
## AFTER every unit/building reference, so no existing unlock bit is renumbered;
## the native core only uses them to gate water movement (coastal = runs of at
## most 3 consecutive water cells, ocean = no run limit).
##
## Supply classes (index order, ABI): 0 ration, 1 fodder, 2 ammunition,
## 3 fuel, 4 upkeep, 5 equipment.

const CATALOG_PATH := "res://data/military/military_catalog.json"
const SCHEMA_VERSION := 1
const Q16_ONE := 65536

const CLASS_LINE := 0
const CLASS_MOBILE := 1
const CLASS_ARTILLERY := 2
const CLASS_IDS := ["line", "mobile", "artillery"]

const SUPPLY_RATION := 0
const SUPPLY_FODDER := 1
const SUPPLY_AMMUNITION := 2
const SUPPLY_FUEL := 3
const SUPPLY_UPKEEP := 4
const SUPPLY_EQUIPMENT := 5
const SUPPLY_CLASS_COUNT := 6
const SUPPLY_CLASS_IDS: Array[String] = [
	"ration", "fodder", "ammunition", "fuel", "upkeep", "equipment"]

const ROLE_BARRACKS := 0
const ROLE_FORTIFICATION := 1
const ROLE_WAR_COLLEGE := 2
const ROLE_IDS := ["barracks", "fortification", "war_college"]

const SOLDIER_PLAN_ID := "soldier_household"
const SOLDIER_PROFESSION_ID := "soldier"
## Dense `building_kinds` value of a treasury-owned military lot. Mirrors
## `EconomyCatalog.BUILDING_KIND_INDICES["state"]`. The bridge below rejects
## any lot whose economy profile is not authored as a state building, so a
## profile accidentally left at `industrial` cannot silently become a
## market producer that the military runtime keeps counting.
const ECONOMY_BUILDING_KIND_STATE := 3
const UNEMPLOYED_PROFESSION_ID := "unemployed"
## The two `soldier_household` needs whose variants become ration candidates.
const RATION_NEED_IDS: Array[String] = ["staple_food", "protein"]
const MAX_UNITS := 64
const MAX_EQUIP_SLOTS := 4

## Authoring magnitude ceilings, not gameplay caps. Every float column in the
## catalog is authored human-readable and scaled exactly once (compiler ->
## native bridge -> q16 / MONEY_SCALE / GOODS_SCALE). No design value comes
## close: max authored attack is 80, fort +2.4, training x3.0, upkeep 15/day.
## The ceilings exist so a column accidentally written in its *internal* fixed
## point form fails validation loudly instead of shipping `守备 +1966100%`.
const MAX_FORT_BONUS := 10.0
const MAX_TRAINING_SPEED := 10.0
const MAX_BUILDING_UPKEEP := 100.0
const MAX_UNIT_STAT := 1000.0
## Material quantities are whole good units per building (max authored: 300).
const MAX_MATERIAL_UNITS := 1000.0
## Equipment power weight per unit (max authored: 0.6).
const MAX_EQUIP_WEIGHT := 10.0


## Compile from the default catalog path. `economy_catalog` is
## `EconomyFacade.native_catalog()`; `technology_catalog` is
## `TechnologyCatalog.compile_native_catalog()`. Both may be empty when the
## catalogs are unavailable, in which case the compile fails explicitly instead
## of emitting silently wrong dense ids.
static func compile(economy_catalog: Dictionary, technology_catalog: Dictionary,
		catalog_path: String = CATALOG_PATH) -> Dictionary:
	var raw := _read_json(catalog_path)
	if not bool(raw.get("ok", false)):
		return raw
	return compile_from_data(raw.get("data", {}), economy_catalog, technology_catalog)


static func compile_from_data(data: Dictionary, economy_catalog: Dictionary,
		technology_catalog: Dictionary) -> Dictionary:
	if data.is_empty():
		return _fail("military_catalog_empty")
	var good_ids: PackedStringArray = economy_catalog.get(
		"good_ids", PackedStringArray())
	var profession_ids: PackedStringArray = economy_catalog.get(
		"profession_ids", PackedStringArray())
	var building_type_ids: PackedStringArray = economy_catalog.get(
		"building_type_ids", PackedStringArray())
	if good_ids.is_empty():
		return _fail("military_economy_good_catalog_unavailable")
	if profession_ids.is_empty():
		return _fail("military_economy_profession_catalog_unavailable")
	var good_index := _index_of(good_ids)
	var tech_ids: PackedStringArray = technology_catalog.get(
		"technology_ids", PackedStringArray())
	var tech_index := _index_of(tech_ids)

	# ---- unlock bits ------------------------------------------------------
	# One dense bit per referenced technology id, in first-reference order.
	# `unlock_bit` is the index into this array; the digest carries a packed
	# bitset row per country in the same order.
	var unlock_tech_ids := PackedInt32Array()
	var unlock_bits := {}

	var categories_result := _compile_categories(data.get("equipment_categories", []),
		good_index, good_ids.size())
	if not bool(categories_result.get("ok", false)):
		return categories_result
	var categories: Array = categories_result.get("categories", [])
	var category_index := {}
	for i in range(categories.size()):
		category_index[String((categories[i] as Dictionary).get("id", ""))] = i

	var unit_result := _compile_units(data.get("units", []), category_index,
		tech_index, unlock_tech_ids, unlock_bits)
	if not bool(unit_result.get("ok", false)):
		return unit_result
	var units: Array = unit_result.get("units", [])
	unlock_tech_ids = unit_result.get("unlock_tech_ids", PackedInt32Array())
	unlock_bits = unit_result.get("unlock_bits", {})

	var economy_tag_offsets: PackedInt32Array = economy_catalog.get(
		"building_technology_tag_offsets", PackedInt32Array())
	var economy_tags: PackedStringArray = economy_catalog.get(
		"building_technology_tags", PackedStringArray())
	var economy_kinds: PackedInt32Array = economy_catalog.get(
		"building_kinds", PackedInt32Array())
	# Every state lot must bridge to a compiled economy building type. A
	# catalog that ships state buildings but no building columns at all can
	# never resolve the bridge, so fail before the per-row check blames an
	# individual building for a catalog-wide problem.
	if not (data.get("state_buildings", []) as Array).is_empty() \
			and building_type_ids.is_empty():
		return _fail("military_economy_building_catalog_unavailable")
	var building_result := _compile_state_buildings(
		data.get("state_buildings", []), good_index, building_type_ids,
		tech_index, unlock_tech_ids, unlock_bits,
		economy_tag_offsets, economy_tags, economy_kinds)
	if not bool(building_result.get("ok", false)):
		return building_result
	var state_buildings: Array = building_result.get("state_buildings", [])
	unlock_tech_ids = building_result.get("unlock_tech_ids", unlock_tech_ids)

	# ---- naval transport gates (army-personnel contract 2 §2.2) ------------
	# Resolved last so every unit/building bit keeps its index. Both slots are
	# optional: a catalog without them simply never opens the sea.
	var naval_result := _compile_naval_unlocks(data.get("unlock_tech_ids", []),
		tech_index, unlock_tech_ids, unlock_bits)
	if not bool(naval_result.get("ok", false)):
		return naval_result
	unlock_tech_ids = naval_result.get("unlock_tech_ids", unlock_tech_ids)
	var coastal_transport_bit := int(naval_result.get("coastal_transport_bit", -1))
	var ocean_transport_bit := int(naval_result.get("ocean_transport_bit", -1))
	var ration := _compile_ration(good_index, economy_catalog)
	if not bool(ration.get("ok", false)):
		return ration
	var profession_index := _index_of(profession_ids)
	var soldier_profession := _index_optional(profession_index, String(
		data.get("soldier_profession_id", SOLDIER_PROFESSION_ID)))
	var unemployed_profession := _index_optional(profession_index, String(
		data.get("unemployed_profession_id", UNEMPLOYED_PROFESSION_ID)))
	if soldier_profession < 0:
		return _fail("military_soldier_profession_missing")
	if unemployed_profession < 0:
		return _fail("military_unemployed_profession_missing")

	var supply := _compile_supply(data.get("supply", {}), good_index,
		categories_result.get("ammunition_candidates", PackedInt32Array()),
		ration.get("ration_goods", PackedInt32Array()),
		ration.get("ration_yields", PackedInt32Array()))
	if not bool(supply.get("ok", false)):
		return supply

	var out := {
		"ok": true,
		"schema": SCHEMA_VERSION,
		"units": units,
		"categories": categories,
		"state_buildings": state_buildings,
		"supply_goods": supply.get("supply_goods", []),
		"supply_yield_q16": supply.get("supply_yield_q16", []),
		"unlock_tech_ids": unlock_tech_ids,
		"coastal_transport_bit": coastal_transport_bit,
		"ocean_transport_bit": ocean_transport_bit,
		"economy_good_count": good_ids.size(),
		"soldier_profession_id": soldier_profession,
		"unemployed_profession_id": unemployed_profession,
		"ration_need_per_head": int(ration.get("ration_need_per_head", Q16_ONE)),
		"militia_unit_index": int(unit_result.get("militia_index", -1)),
	}
	out["catalog_hash"] = _catalog_hash(out, good_ids, tech_ids)
	return out


## Authoring-time validation used by tools/tests: the catalog must name goods,
## professions, technologies and buildings that the shipped economy catalogs
## actually define.
static func validate(catalog: Dictionary, economy_catalog: Dictionary,
		technology_catalog: Dictionary) -> Dictionary:
	var compiled := compile_from_data(catalog, economy_catalog, technology_catalog)
	if not bool(compiled.get("ok", false)):
		return compiled
	var problems: Array[String] = []
	if int(compiled.get("militia_unit_index", -1)) < 0:
		problems.append("catalog must declare exactly one militia unit")
	var supply_goods: Array = compiled.get("supply_goods", [])
	if supply_goods.size() != SUPPLY_CLASS_COUNT:
		problems.append("supply_goods must hold %d rows" % SUPPLY_CLASS_COUNT)
	else:
		var ration: PackedInt32Array = supply_goods[SUPPLY_RATION]
		if ration.is_empty():
			problems.append("ration candidates are empty")
	var units: Array = compiled.get("units", [])
	if units.size() > MAX_UNITS:
		problems.append("unit count %d exceeds %d" % [units.size(), MAX_UNITS])
	var barracks := 0
	for building in compiled.get("state_buildings", []):
		if int((building as Dictionary).get("role", -1)) == ROLE_BARRACKS:
			barracks += 1
	if barracks == 0:
		problems.append("no barracks state building declared")
	# Naval transport (contract 2 §2.2): both gates must resolve, or the sea can
	# never open and an army ordered across water would silently do nothing.
	if int(compiled.get("coastal_transport_bit", -1)) < 0 \
			or int(compiled.get("ocean_transport_bit", -1)) < 0:
		problems.append("unlock_tech_ids must name the coastal and ocean transport technologies")
	if problems.is_empty():
		return compiled
	var failed := compiled.duplicate()
	failed["ok"] = false
	failed["reason"] = "military_catalog_invalid"
	failed["problems"] = problems
	return failed


# ---------------------------------------------------------------- internals

static func _compile_categories(raw_categories, good_index: Dictionary,
		good_count: int) -> Dictionary:
	var categories: Array = []
	var ammunition_candidates := PackedInt32Array()
	var ammunition_qualities := PackedInt32Array()
	var seen := {}
	for raw_value in raw_categories:
		if not raw_value is Dictionary:
			return _fail("military_equipment_category_not_object")
		var raw: Dictionary = raw_value
		var category_id := String(raw.get("id", "")).strip_edges()
		if category_id.is_empty() or seen.has(category_id):
			return _fail("military_equipment_category_id_invalid")
		seen[category_id] = true
		var goods := PackedInt32Array()
		var qualities := PackedInt32Array()
		var rows: Array = raw.get("goods", [])
		for row_value in rows:
			if not row_value is Dictionary:
				return _fail("military_equipment_good_not_object")
			var row: Dictionary = row_value
			var good := _index_optional(good_index, String(row.get("good", "")))
			if good < 0 or good >= good_count:
				return _fail("military_equipment_good_unknown: %s" % String(
					row.get("good", "")))
			var quality := clampi(int(row.get("quality", 1)), 1, 5)
			goods.append(good)
			qualities.append(quality)
		if goods.is_empty():
			return _fail("military_equipment_category_empty: %s" % category_id)
		# Native walks candidates quality-ascending, fewer goods first, so the
		# densest packing is chosen only when it is not worse in quality.
		var order := _quality_order(qualities)
		var sorted_goods := PackedInt32Array()
		var sorted_qualities := PackedInt32Array()
		for k in order:
			sorted_goods.append(goods[k])
			sorted_qualities.append(qualities[k])
		categories.append({
			"id": category_id,
			# Display copy for equipment slots (兵器 / 护具 / 火器 …); the native
			# parser only reads `id/goods/qualities`.
			"name": String(raw.get("name", "")).strip_edges(),
			"goods": sorted_goods,
			"qualities": sorted_qualities,
		})
		if category_id == "ammunition":
			ammunition_candidates = sorted_goods
			ammunition_qualities = sorted_qualities
	return {
		"ok": true,
		"categories": categories,
		"ammunition_candidates": ammunition_candidates,
		"ammunition_qualities": ammunition_qualities,
	}


static func _quality_order(qualities: PackedInt32Array) -> PackedInt32Array:
	var order := PackedInt32Array()
	order.resize(qualities.size())
	for i in range(qualities.size()):
		order[i] = i
	# Insertion sort: candidate lists are at most five entries.
	for i in range(1, order.size()):
		var key := order[i]
		var key_quality := qualities[key]
		var j := i - 1
		while j >= 0 and qualities[order[j]] > key_quality:
			order[j + 1] = order[j]
			j -= 1
		order[j + 1] = key
	return order


static func _compile_units(raw_units, category_index: Dictionary,
		tech_index: Dictionary, unlock_tech_ids: PackedInt32Array,
		unlock_bits: Dictionary) -> Dictionary:
	if raw_units is not Array or (raw_units as Array).is_empty():
		return _fail("military_units_empty")
	if (raw_units as Array).size() > MAX_UNITS:
		return _fail("military_unit_count_exceeds_cap")
	var units: Array = []
	var seen := {}
	var militia_index := -1
	var militia_count := 0
	var ids: Array[String] = []
	for raw_value in raw_units:
		if not raw_value is Dictionary:
			return _fail("military_unit_not_object")
		var raw: Dictionary = raw_value
		var unit_id := String(raw.get("id", "")).strip_edges()
		if unit_id.is_empty() or seen.has(unit_id):
			return _fail("military_unit_id_invalid")
		seen[unit_id] = true
		ids.append(unit_id)
	var order := _sorted_unit_order(ids)
	var ordered_unlock_tech := unlock_tech_ids
	var ordered_bits := unlock_bits
	# Dense unit ids follow stable string id order (design §4.4).
	for source_index in order:
		var raw: Dictionary = (raw_units as Array)[source_index]
		var unit_id := String(raw.get("id", "")).strip_edges()
		var class_id := String(raw.get("class", "line")).strip_edges()
		var class_index := CLASS_IDS.find(class_id)
		if class_index < 0:
			return _fail("military_unit_class_invalid: %s" % unit_id)
		var is_militia := bool(raw.get("militia", false))
		if is_militia:
			militia_count += 1
			militia_index = units.size()
		var era := clampi(int(raw.get("era", 0)), 0, 10)
		var unlock_bit := -1
		var tech_id := String(raw.get("tech", "")).strip_edges()
		if not tech_id.is_empty():
			var bit_result := _resolve_unlock(tech_id, tech_index,
				ordered_unlock_tech, ordered_bits)
			if not bool(bit_result.get("ok", false)):
				return bit_result
			ordered_unlock_tech = bit_result.get("unlock_tech_ids",
				ordered_unlock_tech)
			ordered_bits = bit_result.get("unlock_bits", ordered_bits)
			unlock_bit = int(bit_result.get("bit", -1))
		var equipment: Array = []
		var equipment_rows: Array = raw.get("equipment", [])
		if equipment_rows.size() > MAX_EQUIP_SLOTS:
			return _fail("military_unit_equipment_slots_exceeded: %s" % unit_id)
		for row_value in equipment_rows:
			if not row_value is Dictionary:
				return _fail("military_unit_equipment_not_object: %s" % unit_id)
			var row: Dictionary = row_value
			var category_id := String(row.get("category", "")).strip_edges()
			if not category_index.has(category_id):
				return _fail("military_equipment_category_unknown: %s" % category_id)
			equipment.append({
				"category": int(category_index[category_id]),
				"min_quality": clampi(int(row.get("min_quality", 1)), 1, 5),
				"per_100": maxf(0.0, float(row.get("per_100", 0.0))),
				"weight": maxf(0.0, float(row.get("weight", 1.0))),
			})
		var idle := _supply_vector(raw.get("supply_idle", {}), unit_id)
		var combat := _supply_vector(raw.get("supply_combat", {}), unit_id)
		if idle.is_empty() or combat.is_empty():
			return _fail("military_unit_supply_invalid: %s" % unit_id)
		# Same scale check as the state buildings: attack / defense / speed /
		# per_100 / weight are authored human-readable and scaled once by the
		# native bridge. An out-of-range value means the column was baked in q16.
		var attack := maxf(0.0, float(raw.get("attack", 1.0)))
		var defense := maxf(0.0, float(raw.get("defense", 1.0)))
		var speed_stat := maxf(0.0, float(raw.get("speed", 1.0)))
		for stat_pair in [["attack", attack], ["defense", defense],
				["speed", speed_stat]]:
			if float(stat_pair[1]) > MAX_UNIT_STAT:
				return _fail("military_unit_stat_out_of_range: %s.%s (%s)"
					% [unit_id, String(stat_pair[0]), str(stat_pair[1])])
		for slot_value in equipment:
			var slot: Dictionary = slot_value
			if float(slot.get("per_100", 0.0)) > MAX_UNIT_STAT:
				return _fail("military_unit_equipment_out_of_range: %s.per_100 (%s)"
					% [unit_id, str(slot.get("per_100", 0.0))])
			if float(slot.get("weight", 0.0)) > MAX_EQUIP_WEIGHT:
				return _fail("military_unit_equipment_out_of_range: %s.weight (%s)"
					% [unit_id, str(slot.get("weight", 0.0))])
		# Combat supply rows are authored as the *extra* wartime consumption in
		# some tables and as the absolute rate in others. The design (§9.2) says
		# "daily + combat extra", so absolute rows are folded back to an extra.
		var combat_extra := PackedFloat32Array()
		combat_extra.resize(SUPPLY_CLASS_COUNT)
		for supply_class in range(SUPPLY_CLASS_COUNT):
			combat_extra[supply_class] = maxf(0.0, combat[supply_class])
		units.append({
			"id": unit_id,
			# Author-facing copy. The native parser ignores both keys; the country
			# view model reads them so the roster can show 青铜矛兵 instead of
			# `bronze_spearmen` without re-reading the JSON on every refresh.
			"name": String(raw.get("name", "")).strip_edges(),
			"description": String(raw.get("description", "")).strip_edges(),
			# Stable technology id behind `unlock_bit` (-1 = always available).
			# The UI needs the readable gate name ("需《青铜铸造》"), and the
			# dense id alone cannot be resolved without the technology catalog.
			"tech": tech_id,
			"class": class_index,
			"militia": is_militia,
			"era": era,
			"unlock_bit": unlock_bit,
			"attack": attack,
			"defense": defense,
			"speed": speed_stat,
			"fortification_ignore": clampf(
				float(raw.get("fortification_ignore", 0.0)), 0.0, 1.0),
			"training_days": clampi(int(raw.get("training_days", 30)), 0, 3650),
			"equipment": equipment,
			"supply_idle": idle,
			"supply_combat": combat_extra,
		})
	if militia_count != 1:
		return _fail("military_militia_unit_count_invalid: %d" % militia_count)
	return {
		"ok": true,
		"units": units,
		"militia_index": militia_index,
		"unlock_tech_ids": ordered_unlock_tech,
		"unlock_bits": ordered_bits,
	}


static func _sorted_unit_order(ids: Array[String]) -> PackedInt32Array:
	var order := PackedInt32Array()
	order.resize(ids.size())
	for i in range(ids.size()):
		order[i] = i
	for i in range(1, order.size()):
		var key := order[i]
		var key_id := ids[key]
		var j := i - 1
		while j >= 0 and ids[order[j]] > key_id:
			order[j + 1] = order[j]
			j -= 1
		order[j + 1] = key
	return order


static func _supply_vector(raw_value, unit_id: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not raw_value is Dictionary:
		return out
	var raw: Dictionary = raw_value
	out.resize(SUPPLY_CLASS_COUNT)
	for supply_class in range(SUPPLY_CLASS_COUNT):
		var key := SUPPLY_CLASS_IDS[supply_class]
		out[supply_class] = maxf(0.0, float(raw.get(key, 0.0)))
	return out


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


## Resolves the two naval transport bits from the catalog's `unlock_tech_ids`
## array: slot 0 = coastal (`tech.military.coastal_transport`, runs of at most 3
## consecutive water cells) and slot 1 = ocean (`tech.military.naval_transport`,
## no run limit). Must run after every unit/building reference so no existing
## unlock bit moves. A missing or empty entry leaves that gate closed (-1).
static func _compile_naval_unlocks(raw_ids, tech_index: Dictionary,
		unlock_tech_ids: PackedInt32Array, unlock_bits: Dictionary) -> Dictionary:
	var ordered_tech := unlock_tech_ids
	var ordered_bits := unlock_bits
	var bits := PackedInt32Array([-1, -1])
	var rows: Array = raw_ids if raw_ids is Array else []
	for index in range(mini(rows.size(), bits.size())):
		var tech_id := String(rows[index]).strip_edges()
		if tech_id.is_empty():
			continue
		var bit_result := _resolve_unlock(tech_id, tech_index, ordered_tech, ordered_bits)
		if not bool(bit_result.get("ok", false)):
			return bit_result
		ordered_tech = bit_result.get("unlock_tech_ids", ordered_tech)
		ordered_bits = bit_result.get("unlock_bits", ordered_bits)
		bits[index] = int(bit_result.get("bit", -1))
	return {
		"ok": true,
		"unlock_tech_ids": ordered_tech,
		"unlock_bits": ordered_bits,
		"coastal_transport_bit": int(bits[0]),
		"ocean_transport_bit": int(bits[1]),
	}


static func _compile_state_buildings(raw_buildings, good_index: Dictionary,
		building_type_ids: PackedStringArray, tech_index: Dictionary,
		unlock_tech_ids: PackedInt32Array, unlock_bits: Dictionary,
		economy_tag_offsets: PackedInt32Array = PackedInt32Array(),
		economy_tags: PackedStringArray = PackedStringArray(),
		economy_kinds: PackedInt32Array = PackedInt32Array()) -> Dictionary:
	var building_index := _index_of(building_type_ids)
	var out: Array = []
	var seen := {}
	var ordered_unlock_tech := unlock_tech_ids
	var ordered_bits := unlock_bits
	for raw_value in raw_buildings:
		if not raw_value is Dictionary:
			return _fail("military_state_building_not_object")
		var raw: Dictionary = raw_value
		var building_id := String(raw.get("id", "")).strip_edges()
		if building_id.is_empty() or seen.has(building_id):
			return _fail("military_state_building_id_invalid")
		seen[building_id] = true
		var role_id := String(raw.get("role", "barracks")).strip_edges()
		var role := ROLE_IDS.find(role_id)
		if role < 0:
			return _fail("military_state_building_role_invalid: %s" % building_id)
		var unlock_bit := -1
		var tech_id := String(raw.get("tech", "")).strip_edges()
		# Design §1.4: every state lot is gated by a technology. An empty
		# `tech` used to mean "always buildable", which silently shipped a
		# free barracks alongside the researched ones.
		if tech_id.is_empty():
			return _fail("military_state_building_technology_missing: %s"
				% building_id)
		# Bridge to the economy catalog (design §5.1/§5.2/§5.4). The dense
		# economy building type index is the only handle either runtime may
		# use to name "this same lot": it is what `building_commit` keys the
		# ledger on, what the construction workspace offers, and what the
		# derived `barracks_count` / `fort_tier` / `college_tier` read back.
		# Resolving by stable id keeps the two catalogs independent; a -1
		# placeholder would instead let the military side invent a lot that
		# no economy group exists for, so it is a hard failure here.
		var economy_building := _index_optional(building_index, building_id)
		if economy_building < 0:
			return _fail(
				"military_state_building_without_economy_profile: %s"
				% building_id)
		if not economy_kinds.is_empty():
			if economy_building >= economy_kinds.size():
				return _fail(
					"military_state_building_economy_columns_ragged: %s"
					% building_id)
			var economy_kind := int(economy_kinds[economy_building])
			if economy_kind != ECONOMY_BUILDING_KIND_STATE:
				return _fail(
					"military_state_building_economy_kind_invalid: %s (kind=%d)"
					% [building_id, economy_kind])
		var bit_result := _resolve_unlock(tech_id, tech_index,
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
				return _fail(
					"military_state_building_technology_columns_ragged: %s"
					% building_id)
			var economy_technology_ids := PackedStringArray()
			var economy_tag_begin := int(economy_tag_offsets[economy_building])
			var economy_tag_end := int(economy_tag_offsets[economy_building + 1])
			if economy_tag_begin < 0 or economy_tag_end > economy_tags.size():
				return _fail(
					"military_state_building_technology_columns_ragged: %s"
					% building_id)
			for economy_tag_index in range(economy_tag_begin, economy_tag_end):
				var economy_tag := String(
					economy_tags[economy_tag_index]).strip_edges()
				if economy_tag.begins_with("tech."):
					economy_technology_ids.append(economy_tag)
			if economy_technology_ids.size() != 1:
				return _fail(
					"military_state_building_technology_count_invalid: %s (%d)"
					% [building_id, economy_technology_ids.size()])
			if economy_technology_ids[0] != tech_id:
				return _fail(
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
		if fort_bonus > MAX_FORT_BONUS:
			return _fail("military_state_building_fort_bonus_out_of_range: %s (%s)"
				% [building_id, str(fort_bonus)])
		if training_speed > MAX_TRAINING_SPEED:
			return _fail("military_state_building_training_speed_out_of_range: %s (%s)"
				% [building_id, str(training_speed)])
		if upkeep > MAX_BUILDING_UPKEEP:
			return _fail("military_state_building_upkeep_out_of_range: %s (%s)"
				% [building_id, str(upkeep)])
		var material_goods := PackedInt32Array()
		var material_qty := PackedInt64Array()
		var materials: Dictionary = raw.get("materials", {})
		for good_key in materials.keys():
			var good := _index_optional(good_index, String(good_key))
			if good < 0:
				return _fail("military_state_building_material_unknown: %s" % String(
					good_key))
			var material_units := maxf(0.0, float(materials[good_key]))
			if material_units > MAX_MATERIAL_UNITS:
				return _fail(
					"military_state_building_material_out_of_range: %s.%s (%s)"
					% [building_id, String(good_key), str(material_units)])
			material_goods.append(good)
			material_qty.append(maxi(0, int(round(material_units * 1000.0))))
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
		})
	return {
		"ok": true,
		"state_buildings": out,
		"unlock_tech_ids": ordered_unlock_tech,
		"unlock_bits": ordered_bits,
	}


## Ration candidates come straight from the `soldier_household` consumption plan
## so a change to the staple/protein variants can never drift from the army's
## actual field ration (design §9.2 "口粮折算").
static func _compile_ration(good_index: Dictionary, economy_catalog: Dictionary) -> Dictionary:
	var plan_ids: PackedStringArray = economy_catalog.get("plan_ids", PackedStringArray())
	var plan_index := _index_optional(_index_of(plan_ids), SOLDIER_PLAN_ID)
	if plan_index < 0:
		return _fail("military_soldier_household_plan_missing")
	var good_count := int((economy_catalog.get("good_ids", PackedStringArray())
		as PackedStringArray).size())
	var need_ids: PackedStringArray = economy_catalog.get("need_ids", PackedStringArray())
	var need_index := _index_of(need_ids)
	var plan_need_offsets: PackedInt32Array = economy_catalog.get(
		"plan_need_offsets", PackedInt32Array())
	var need_stable_ids: PackedInt32Array = economy_catalog.get(
		"need_stable_ids", PackedInt32Array())
	var need_base_qty: PackedInt64Array = economy_catalog.get(
		"need_base_qty_per_person", PackedInt64Array())
	var need_variant_offsets: PackedInt32Array = economy_catalog.get(
		"need_variant_offsets", PackedInt32Array())
	var variant_preference: PackedInt32Array = economy_catalog.get(
		"variant_preference_q16", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = economy_catalog.get(
		"variant_component_offsets", PackedInt32Array())
	var component_good_ids: PackedInt32Array = economy_catalog.get(
		"component_good_ids", PackedInt32Array())
	var component_qty: PackedInt64Array = economy_catalog.get(
		"component_qty_per_need", PackedInt64Array())
	if plan_need_offsets.size() < plan_index + 2:
		return _fail("military_economy_plan_columns_truncated")
	var need_begin := int(plan_need_offsets[plan_index])
	var need_end := int(plan_need_offsets[plan_index + 1])
	var ration_goods := PackedInt32Array()
	var ration_yields := PackedInt32Array()
	var ration_preferences := PackedInt32Array()
	var ration_need_units := 0
	for need_name in RATION_NEED_IDS:
		var need_dense := _index_optional(need_index, need_name)
		if need_dense < 0:
			return _fail("military_ration_need_missing: %s" % need_name)
		var found := false
		for plan_need in range(need_begin, need_end):
			if plan_need >= need_stable_ids.size() \
					or int(need_stable_ids[plan_need]) != need_dense:
				continue
			found = true
			if plan_need < need_base_qty.size():
				ration_need_units += int(need_base_qty[plan_need])
			if need_variant_offsets.size() < plan_need + 2:
				return _fail("military_economy_variant_columns_truncated")
			var variant_begin := int(need_variant_offsets[plan_need])
			var variant_end := int(need_variant_offsets[plan_need + 1])
			for variant in range(variant_begin, variant_end):
				if variant_component_offsets.size() < variant + 2:
					return _fail("military_economy_component_columns_truncated")
				var component_begin := int(variant_component_offsets[variant])
				var component_end := int(variant_component_offsets[variant + 1])
				for component in range(component_begin, component_end):
					if component >= component_good_ids.size() or component >= component_qty.size():
						continue
					var good := int(component_good_ids[component])
					if good < 0 or good >= good_count:
						continue
					var qty := int(component_qty[component])
					if qty <= 0:
						continue
					# goods needed per need unit = qty / 1000 (GOODS_SCALE) ->
					# yield per good unit in q16 = (1 / (qty/1000)) * 65536.
					var yield_q16 := int(round(65536.0 * 1000.0 / float(qty)))
					var existing := ration_goods.find(good)
					if existing >= 0:
						# A good reachable through both needs keeps the better yield
						# and the higher preference so the native picker is monotone.
						ration_yields[existing] = maxi(ration_yields[existing], yield_q16)
						ration_preferences[existing] = maxi(ration_preferences[existing],
							int(variant_preference[variant]) if variant \
								< variant_preference.size() else Q16_ONE)
						continue
					ration_goods.append(good)
					ration_yields.append(yield_q16)
					ration_preferences.append(
						int(variant_preference[variant]) if variant \
							< variant_preference.size() else Q16_ONE)
			break
		if not found:
			return _fail("military_ration_need_not_in_plan: %s" % need_name)
	if ration_goods.is_empty():
		return _fail("military_ration_candidates_empty")
	var order := _yield_order(ration_yields, ration_preferences)
	var sorted_goods := PackedInt32Array()
	var sorted_yields := PackedInt32Array()
	for k in order:
		sorted_goods.append(ration_goods[k])
		sorted_yields.append(ration_yields[k])
	return {
		"ok": true,
		# `ration_need_per_head` is authored in *need units*; the native core
		# compares it against its q16 need accumulator, so normalize here rather
		# than re-deriving the scale in C++.
		"ration_need_per_head": maxi(1, ration_need_units),
		"ration_goods": sorted_goods,
		"ration_yields": sorted_yields,
	}


static func _yield_order(yields: PackedInt32Array,
		preferences: PackedInt32Array) -> PackedInt32Array:
	var order := PackedInt32Array()
	order.resize(yields.size())
	for i in range(yields.size()):
		order[i] = i
	for i in range(1, order.size()):
		var key := order[i]
		var j := i - 1
		while j >= 0:
			var previous := order[j]
			# Preference first (what the household would eat), then yield.
			var key_better: bool = preferences[key] > preferences[previous] \
				or (preferences[key] == preferences[previous] \
					and key < previous)
			if not key_better:
				break
			order[j + 1] = previous
			j -= 1
		order[j + 1] = key
	return order


static func _compile_supply(raw_supply, good_index: Dictionary,
		ammunition_candidates: PackedInt32Array,
		ration_goods: PackedInt32Array, ration_yields: PackedInt32Array) -> Dictionary:
	var supply_goods: Array = []
	var supply_yields: Array = []
	for supply_class in range(SUPPLY_CLASS_COUNT):
		supply_goods.append(PackedInt32Array())
		supply_yields.append(PackedInt32Array())
	if ration_goods.size() != ration_yields.size() or ration_goods.is_empty():
		return _fail("military_ration_candidates_invalid")
	(supply_goods[SUPPLY_RATION] as PackedInt32Array).append_array(ration_goods)
	(supply_yields[SUPPLY_RATION] as PackedInt32Array).append_array(ration_yields)
	for supply_class in range(SUPPLY_CLASS_COUNT):
		if supply_class == SUPPLY_RATION:
			continue
		var key := SUPPLY_CLASS_IDS[supply_class]
		var raw_value = raw_supply.get(key, []) if raw_supply is Dictionary else []
		if raw_value is String:
			# `"@ammunition"` style: take the ammunition equip category's goods.
			if String(raw_value) == "@ammunition" and not ammunition_candidates.is_empty():
				(supply_goods[supply_class] as PackedInt32Array).append_array(
					ammunition_candidates)
				for _unused in range(ammunition_candidates.size()):
					(supply_yields[supply_class] as PackedInt32Array).append(Q16_ONE)
			continue
		if not raw_value is Array:
			continue
		for entry_value in (raw_value as Array):
			var entry: Dictionary = {}
			if entry_value is Dictionary:
				entry = entry_value
			else:
				entry = {"good": String(entry_value), "yield": 1.0}
			var good := _index_optional(good_index, String(entry.get("good", "")))
			if good < 0:
				return _fail("military_supply_good_unknown: %s" % String(
					entry.get("good", "")))
			(supply_goods[supply_class] as PackedInt32Array).append(good)
			(supply_yields[supply_class] as PackedInt32Array).append(
				maxi(1, int(round(float(entry.get("yield", 1.0)) * Q16_ONE))))
	return {
		"ok": true,
		"supply_goods": supply_goods,
		"supply_yield_q16": supply_yields,
	}


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
			hash_mix(hasher, "%d:%d:%.6f:%.6f" % [int(row.get("category", -1)),
				int(row.get("min_quality", 1)), float(row.get("per_100", 0.0)),
				float(row.get("weight", 1.0))])
		var idle: PackedFloat32Array = unit.get("supply_idle", PackedFloat32Array())
		var combat: PackedFloat32Array = unit.get("supply_combat", PackedFloat32Array())
		for k in range(mini(SUPPLY_CLASS_COUNT, idle.size())):
			hash_mix(hasher, "i%.6f" % float(idle[k]))
		for k in range(mini(SUPPLY_CLASS_COUNT, combat.size())):
			hash_mix(hasher, "c%.6f" % float(combat[k]))
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


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _fail("military_catalog_missing: %s" % path)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		return _fail("military_catalog_json_invalid: %s" % path)
	var data: Dictionary = parsed
	var schema := int(data.get("schema", SCHEMA_VERSION))
	if schema != SCHEMA_VERSION:
		return _fail("military_catalog_schema_unsupported: %d" % schema)
	return {"ok": true, "data": data}


static func _index_of(ids: PackedStringArray) -> Dictionary:
	var index := {}
	for i in range(ids.size()):
		index[String(ids[i])] = i
	return index


static func _index_optional(index: Dictionary, id_value: String) -> int:
	return int(index.get(id_value, -1))


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
