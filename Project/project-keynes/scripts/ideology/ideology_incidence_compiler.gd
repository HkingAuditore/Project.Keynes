class_name IdeologyIncidenceCompiler
extends RefCounted

## Compiles the material-support channel table: one dense Q16 row per card level.
##
## The channel layout is owned by Economy (`EconomyApi::kIncidencePrefixChannelCount`
## + one slot per need). This file owns what each stat key MEANS for a class, so the
## native runtime never parses a string. Kept out of `ideology_catalog.gd` because
## that file is already past its size ratchet.

## Must match EconomyApi's published layout:
## [0..5] sector income, [6] input cost, [7] owner profit, [8] merchant income,
## [9] birth, [10] death, [11..] need spend.
const PREFIX_CHANNEL_COUNT := 11
const SECTOR_IDS := [
	"agriculture", "extractive", "manufacturing", "energy", "knowledge", "military",
]
## A birth or death factor is a demographic effect, not a cash flow. 0.15 keeps it
## visible without letting "+10% birth" outrank every economic card.
const DEMOGRAPHIC_WEIGHT_Q16 := 9830
const Q16 := 65536
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")


## Diagnostic sink for tools/probes. A probe assigns an `Array` here and
## `compile_level_row` records every stat key it could not map to a material
## channel; production leaves it `null`. Deliberately NOT part of the catalog dict:
## adding a key there would change the catalog hash that saves are validated against.
static var debug_unmapped_keys = null


## `definitions` must be in the same order the catalog emits levels, so row N is
## the Nth level in `level_offsets` order.
static func compile(definitions: Array, program_resource: Resource,
		economy_catalog: Dictionary) -> Dictionary:
	var need_ids: PackedStringArray = economy_catalog.get(
		"need_ids", PackedStringArray())
	var need_index := {}
	for need_slot in need_ids.size():
		need_index[String(need_ids[need_slot])] = need_slot
	var channel_count := PREFIX_CHANNEL_COUNT + need_ids.size()
	var good_sector := _good_sector_weights(economy_catalog)
	var program_rows := _program_rows(program_resource)
	var modifier_rows := _modifier_rows()
	var rows := PackedInt32Array()
	var measured := PackedByteArray()
	var unmapped := 0
	for definition in definitions:
		if definition == null:
			continue
		for level in definition.levels:
			var compiled := compile_level_row(level, program_rows, modifier_rows,
				good_sector, need_index, channel_count)
			unmapped += int(compiled.get("unmapped", 0))
			rows.append_array(compiled["row"])
			measured.append(1 if bool(compiled.get("measured", false)) else 0)
	return {"channel_count": channel_count, "rows": rows, "unmapped": unmapped,
		"measured": measured}


## Program key -> [[stat_key, magnitude_q16], ...].
##
## A ramp encodes its magnitude in the instruction stream and writes a unit
## command value (1). The instruction constants mix two units: the per-unit slope
## (Q16, e.g. 655 = 1%) and the metric cap (raw units, e.g. 24 cells), so their
## PRODUCT is the advertised ceiling and neither constant alone is one. Taking the
## largest constant that is a legal Q16 delta is the safe bound: it can understate
## a ramp card but can never invent a 2400% effect.
static func _program_rows(program_resource: Resource) -> Dictionary:
	var out := {}
	if program_resource == null:
		return out
	for effect in program_resource.effects:
		if effect == null or not effect is IdeologyEffectDefinition:
			continue
		var ramp_ceiling := 1
		for instruction in effect.instructions:
			if instruction == null:
				continue
			var raw := int(instruction.value_q16)
			if raw > 1 and raw <= Q16 and raw > ramp_ceiling:
				ramp_ceiling = raw
		var rows: Array = []
		for command in effect.commands:
			if command == null:
				continue
			var stat_key := String(command.definition_key)
			if stat_key.is_empty():
				continue
			var magnitude := int(command.value_q16)
			if magnitude <= 1:
				magnitude = ramp_ceiling
			rows.append([stat_key, maxi(1, magnitude)])
		out[String(effect.definition_key)] = rows
	return out


## Modifier definition key -> the same row shape. Legacy cards carry a
## `ideology.<card>` Modifier key instead of a program, so without this their
## channel row would be all zero and they would silently lose the gate.
static func _modifier_rows() -> Dictionary:
	var out := {}
	var catalog: Resource = ModifierCatalogScript.load_default()
	if catalog == null:
		return out
	for definition in catalog.definitions:
		if definition == null:
			continue
		var rows: Array = []
		for term in definition.terms:
			if term == null:
				continue
			var raw_value := float(term.value)
			var magnitude := int(round(absf(raw_value) * Q16))
			if magnitude <= 0:
				continue
			# Reuse the `.cut` convention instead of a second sign channel: a
			# negative term is a cut, and the classifier already knows what a cut
			# means for each stat family.
			var stat_key := String(term.stat_key)
			if raw_value < 0.0:
				stat_key += ".cut"
			rows.append([stat_key, magnitude])
		out[String(definition.key)] = rows
	return out


## Good -> civil-sector production weights, Q16. A good's producer sector is not a
## property of the good; it is the set of building types that output it.
static func _good_sector_weights(economy_catalog: Dictionary) -> Dictionary:
	var out := {}
	var good_ids: PackedStringArray = economy_catalog.get(
		"good_ids", PackedStringArray())
	var sectors: PackedInt32Array = economy_catalog.get(
		"building_economic_sectors", PackedInt32Array())
	var offsets: PackedInt32Array = economy_catalog.get(
		"building_output_offsets", PackedInt32Array())
	var outputs: PackedInt32Array = economy_catalog.get(
		"building_output_good_ids", PackedInt32Array())
	if sectors.is_empty() or offsets.size() != sectors.size() + 1:
		return out
	for building in sectors.size():
		var sector := int(sectors[building])
		if sector < 0 or sector >= 5:
			continue
		for k in range(int(offsets[building]), int(offsets[building + 1])):
			if k < 0 or k >= outputs.size():
				continue
			var good := int(outputs[k])
			if good < 0 or good >= good_ids.size():
				continue
			var row: Array = out.get(String(good_ids[good]), [0, 0, 0, 0, 0, 0])
			row[sector] = int(row[sector]) + 1
			out[String(good_ids[good])] = row
	for good in out.keys():
		var row: Array = out[good]
		var total := 0
		for sector in 5:
			total += int(row[sector])
		if total <= 0:
			out.erase(good)
			continue
		for sector in 5:
			row[sector] = int(row[sector]) * Q16 / total
		out[good] = row
	return out


## One stat key -> the channels it moves, a Q16 weight per channel, and the
## welfare sign. Empty means "not an economic channel"; the caller counts those so
## a new stat family cannot silently become a no-op card.
static func channels_of(stat_key: String, good_sector: Dictionary,
		need_index: Dictionary) -> Dictionary:
	var key := stat_key
	var sign := 1
	if key.ends_with(".cut"):
		key = key.substr(0, key.length() - 4)
		sign = -1
	var channels := PackedInt32Array()
	var weights := PackedInt32Array()
	if key.begins_with("economy.city.building.") and key.ends_with("_output_factor"):
		var sector_id := key.trim_prefix("economy.city.building.") \
			.trim_suffix("_output_factor")
		var sector := SECTOR_IDS.find(sector_id)
		if sector < 0:
			return {}
		channels.append(sector)
		weights.append(Q16)
	elif key == "economy.city.output_factor":
		for sector in 5:
			channels.append(sector)
			weights.append(13107)
	elif key.begins_with("country.output.") and key.ends_with("_factor"):
		var country_sector_id := key.trim_prefix("country.output.") \
			.trim_suffix("_factor")
		var country_sector := SECTOR_IDS.find(country_sector_id)
		if country_sector < 0:
			return {}
		channels.append(country_sector)
		weights.append(Q16)
	elif key.begins_with("economy.city.good.") and key.ends_with(".output_factor"):
		var good := key.trim_prefix("economy.city.good.").trim_suffix(".output_factor")
		if not good_sector.has(good):
			return {}
		var row: Array = good_sector[good]
		for sector in 5:
			var weight := int(row[sector])
			if weight <= 0:
				continue
			channels.append(sector)
			weights.append(weight)
	elif key.begins_with("economy.city.need.") and key.ends_with(".consumption_factor"):
		var need := key.trim_prefix("economy.city.need.") \
			.trim_suffix(".consumption_factor")
		if not need_index.has(need):
			return {}
		channels.append(PREFIX_CHANNEL_COUNT + int(need_index[need]))
		weights.append(Q16)
		# `consumption_factor` is a household REQUIREMENT ("居住维护消费需求提高
		# 5%" is a cost), so a positive delta hurts every consumer.
		sign = -sign
	elif key.ends_with("birth_factor"):
		channels.append(9)
		weights.append(DEMOGRAPHIC_WEIGHT_Q16)
	elif key.ends_with("death_factor"):
		channels.append(10)
		weights.append(DEMOGRAPHIC_WEIGHT_Q16)
		sign = -sign
	elif key.ends_with("input_factor"):
		channels.append(6)
		weights.append(Q16)
		sign = -sign
	elif key.ends_with("regen_factor"):
		channels.append(0)
		weights.append(32768)
		channels.append(1)
		weights.append(32768)
	elif key.contains("construction.cost_factor"):
		channels.append(7)
		weights.append(Q16)
		sign = -sign
	elif key.contains("research.cost_factor"):
		channels.append(4)
		weights.append(Q16)
		sign = -sign
	elif key.contains("trade.capacity_factor"):
		channels.append(8)
		weights.append(Q16)
	elif key.begins_with("ideology.military."):
		channels.append(5)
		weights.append(Q16)
	else:
		return {}
	return {"channels": channels, "weights": weights, "sign": sign}


## One dense channel row for a card level. Mutually exclusive variants of one card
## write the same stat, so the row keeps the LARGEST magnitude per channel instead
## of summing both branches; a sum would double-count an either/or card.
static func compile_level_row(level: Resource, program_rows: Dictionary,
		modifier_rows: Dictionary, good_sector: Dictionary, need_index: Dictionary,
		channel_count: int) -> Dictionary:
	var row := PackedInt32Array()
	row.resize(channel_count)
	row.fill(0)
	var unmapped := 0
	for effects in [level.persistent_effects, level.on_enter_effects]:
		for effect in effects:
			if effect == null:
				continue
			var stats: Array = program_rows.get(String(effect.definition_key), [])
			if stats.is_empty():
				stats = modifier_rows.get(String(effect.definition_key), [])
			if stats.is_empty():
				stats = [[String(effect.definition_key),
					maxi(1, int(effect.value_q16))]]
			for entry in stats:
				var classification := channels_of(String(entry[0]), good_sector,
					need_index)
				if classification.is_empty():
					unmapped += 1
					if debug_unmapped_keys != null:
						debug_unmapped_keys.append(String(entry[0]))
					continue
				var magnitude := int(entry[1])
				var channels: PackedInt32Array = classification["channels"]
				var weights: PackedInt32Array = classification["weights"]
				var sign := int(classification["sign"])
				for i in channels.size():
					var channel := int(channels[i])
					if channel < 0 or channel >= channel_count:
						continue
					var delta := magnitude * int(weights[i]) / Q16
					if delta == 0:
						delta = 1
					delta *= sign
					# The native table accepts at most 100% per channel. A few
					# authored rows exceed it (104858 = 160%), so clamp here rather
					# than rejecting the whole catalog at configure time.
					delta = clampi(delta, -Q16, Q16)
					if absi(int(row[channel])) < absi(delta):
						row[channel] = delta
	var measured := false
	for value in row:
		if value != 0:
			measured = true
			break
	return {"row": row, "unmapped": unmapped, "measured": measured}
