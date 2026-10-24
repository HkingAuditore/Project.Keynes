class_name StatKeyFamilies
extends RefCounted

## L5-14b: the symbol table for generated stat keys, plus the dead-key check.
##
## Why this exists
## ---------------
## `ModifierCatalog.compile_native_catalog()` generates 2778 stat keys today by
## looping over economy ids. Each loop is a *family*: "for every good id, emit
## `country.output.good.<id>_factor`". The loops are cheap to add and completely
## silent — a new loop that nobody consumes produces thousands of legal keys,
## every one of them a dead end. A card can reference such a key, the catalog
## compiles, the modifier applies, and nothing happens. That is the failure this
## file makes loud.
##
## The contract
## ------------
## Every generated key belongs to exactly one family listed here, or to the
## explicit table (`ModifierCatalog.stats` + `TECHNOLOGY_STATS`), which is
## declared one key at a time with its own min/max. Anything else is an
## undeclared family and `tests/stat_key_family_test.gd` fails naming the key.
##
## Adding a generator loop therefore means adding one row here. That is the
## point: one line of bookkeeping in exchange for the "looks implemented, is
## inert" bug class being detectable.
##
## Symbols
## -------
## A family's `%s` placeholders are its *symbols*. `format()` builds a key from
## a family id plus symbol values, and `classify()` recovers them. Content and
## tests can address `country.output.good.tools_factor` as
## `format(&"country_output_good", ["tools"])` instead of a literal, which is
## what makes a typo a type error rather than a silently different key.
##
## `consumer` is documentation, not a checked fact: it names the place that
## reads the frozen table. It is kept in code so it rots in review rather than
## in a design document nobody diffs.

const EXPLICIT_FAMILY := &"explicit"

## One row per generator loop in `compile_native_catalog()`. `dimensions` names
## what each `%s` stands for, which is also the symbol namespace a caller must
## pass to `format()` -- an id from the wrong namespace produces a key that is
## well-formed and wrong, so the name is part of the contract.
const FAMILIES := [
	{
		"id": &"climate_profile",
		"pattern": "country.climate.profile.%s.%s_loss_factor",
		"dimensions": ["climate_profile", "hazard"],
		"consumer": "economy_runtime epoch freeze -> country climate loss factor",
	},
	{
		"id": &"city_need_consumption",
		"pattern": "economy.city.need.%s.consumption_factor",
		"dimensions": ["need"],
		"consumer": "economy_runtime epoch freeze -> per-need city consumption",
	},
	{
		"id": &"city_good_consumption",
		"pattern": "economy.city.good.%s.consumption_factor",
		"dimensions": ["good"],
		"consumer": "economy_runtime epoch freeze -> per-good city consumption",
	},
	{
		"id": &"city_good_output",
		"pattern": "economy.city.good.%s.output_factor",
		"dimensions": ["good"],
		"consumer": "economy_runtime epoch freeze -> per-good city output",
	},
	{
		"id": &"city_building_output",
		"pattern": "economy.city.building.%s.output_factor",
		"dimensions": ["building"],
		"consumer": "economy_runtime epoch freeze -> per-building city output",
	},
	{
		"id": &"city_resource_regen",
		"pattern": "economy.city.resource.%s.regen_factor",
		"dimensions": ["resource"],
		"consumer": "economy_runtime epoch freeze -> per-resource city regeneration",
	},
	{
		"id": &"output_family",
		"pattern": "country.output.family.%s_factor",
		"dimensions": ["building_family"],
		"consumer": "economy_runtime epoch freeze -> building-family output",
	},
	{
		"id": &"output_good",
		"pattern": "country.output.good.%s_factor",
		"dimensions": ["good"],
		"consumer": "economy_runtime epoch freeze -> country per-good output",
	},
	{
		"id": &"input_good",
		"pattern": "country.input.good.%s_factor",
		"dimensions": ["good"],
		"consumer": "economy_runtime epoch freeze -> country per-good input",
	},
	{
		"id": &"consumption_good",
		"pattern": "country.consumption.good.%s_factor",
		"dimensions": ["good"],
		"consumer": "economy_runtime epoch freeze -> country per-good household demand",
	},
	{
		"id": &"resource_use",
		"pattern": "country.resource.%s.use_factor",
		"dimensions": ["resource"],
		"consumer": "economy_runtime epoch freeze -> resource extraction draw",
	},
	{
		"id": &"resource_managed_generation",
		"pattern": "country.resource.%s.managed_generation_factor",
		"dimensions": ["resource"],
		"consumer": "economy_runtime epoch freeze -> managed regeneration",
	},
	{
		"id": &"output_landform_sector",
		"pattern": "country.output.landform.%s.%s_factor",
		"dimensions": ["landform", "sector"],
		"consumer": "economy_runtime.cpp epoch freeze -> landform x sector output",
	},
	{
		"id": &"output_terrain_sector",
		"pattern": "country.output.terrain.%s.%s_factor",
		"dimensions": ["terrain", "sector"],
		"consumer": "economy_runtime.cpp epoch freeze -> terrain x sector output",
	},
	{
		"id": &"output_building",
		"pattern": "country.output.building.%s_factor",
		"dimensions": ["building"],
		"consumer": "economy_runtime epoch freeze -> country per-building output",
	},
	{
		"id": &"tax_income",
		"pattern": "country.tax.income.%s.rate_bp",
		"dimensions": ["profession"],
		"consumer": "country_runtime.cpp tax policy snapshot -> effective income rate",
	},
	{
		# R-4 X16: how much tax burden a profession tolerates before its satisfaction
		# tax dimension starts falling. Frozen per epoch in `capture_country_epoch`,
		# read in `economy_runtime.cpp update_cohort_satisfaction`.
		"id": &"profession_tax_tolerance",
		"pattern": "economy.profession.%s.tax_tolerance_factor",
		"dimensions": ["profession"],
		"consumer": "economy_runtime.cpp update_cohort_satisfaction",
	},
	{
		# R-4 X16: basis-point offset on a profession's composite satisfaction. Applied
		# BEFORE the needs ceiling, so a positive bias cannot make a starving city
		# content.
		"id": &"profession_satisfaction",
		"pattern": "economy.profession.%s.satisfaction_bp",
		"dimensions": ["profession"],
		"consumer": "economy_runtime.cpp update_cohort_satisfaction",
	},
	{
		"id": &"tax_consumption",
		"pattern": "country.tax.consumption.%s.rate_bp",
		"dimensions": ["good"],
		"consumer": "country_runtime.cpp tax policy snapshot -> effective consumption rate",
	},
	{
		"id": &"tax_business",
		"pattern": "country.tax.business.%s.rate_bp",
		"dimensions": ["building"],
		"consumer": "country_runtime.cpp tax policy snapshot -> effective business rate",
	},
	{
		"id": &"tax_import",
		"pattern": "country.tax.import.%s.rate_bp",
		"dimensions": ["good"],
		"consumer": "country_runtime.cpp tax policy snapshot -> effective import rate",
	},
	{
		"id": &"tax_export",
		"pattern": "country.tax.export.%s.rate_bp",
		"dimensions": ["good"],
		"consumer": "country_runtime.cpp tax policy snapshot -> effective export rate",
	},
]

## Parsed matchers, keyed by family id. Built once: `classify()` runs over every
## generated key, so a per-call `split()` would be thousands of allocations of
## the same twenty answers.
static var _matchers: Dictionary = {}
static var _patterns: Dictionary = {}


static func family_ids() -> Array:
	var ids := []
	for row in FAMILIES:
		ids.append(row["id"])
	return ids


static func family(family_id: StringName) -> Dictionary:
	for row in FAMILIES:
		if row["id"] == family_id:
			return row
	return {}


static func _build() -> void:
	if not _matchers.is_empty():
		return
	for row in FAMILIES:
		var family_id: StringName = row["id"]
		var pattern := String(row["pattern"])
		_patterns[family_id] = pattern
		var segments := pattern.split(".")
		var matcher := {"segments": segments, "slots": PackedInt32Array(),
			"affixes": []}
		var slots := PackedInt32Array()
		var affixes: Array = []
		for index in segments.size():
			var segment: String = segments[index]
			if not segment.contains("%s"):
				continue
			slots.append(index)
			# `%s` may sit inside a segment with a fixed tail (`%s_factor`), so
			# the affixes are stored rather than assuming a whole-segment slot.
			var pieces := segment.split("%s")
			affixes.append([String(pieces[0]), String(pieces[1]) if pieces.size() > 1 else ""])
		matcher["slots"] = slots
		matcher["affixes"] = affixes
		_matchers[family_id] = matcher


## Splits a generated stat key into its family and symbol values.
## Returns `{}` when no family matches -- which is the dead-key signal.
static func classify(stat_key: String) -> Dictionary:
	_build()
	var segments := stat_key.split(".")
	for family_id in _matchers:
		var matcher: Dictionary = _matchers[family_id]
		var pattern_segments: PackedStringArray = matcher["segments"]
		if pattern_segments.size() != segments.size():
			continue
		var slots: PackedInt32Array = matcher["slots"]
		var affixes: Array = matcher["affixes"]
		var values := PackedStringArray()
		var matched := true
		for index in pattern_segments.size():
			var slot_position := slots.find(index)
			if slot_position < 0:
				if pattern_segments[index] != segments[index]:
					matched = false
					break
				continue
			var prefix := String((affixes[slot_position] as Array)[0])
			var suffix := String((affixes[slot_position] as Array)[1])
			var segment: String = segments[index]
			if segment.length() <= prefix.length() + suffix.length() \
					or not segment.begins_with(prefix) or not segment.ends_with(suffix):
				matched = false
				break
			values.append(segment.substr(prefix.length(),
				segment.length() - prefix.length() - suffix.length()))
		if not matched:
			continue
		return {"family": family_id, "values": values}
	return {}


## Builds a stat key from a family id and its symbol values.
## Refuses arity mismatches instead of producing a key with a literal `%s` in it
## -- a malformed key would silently never resolve, which is the failure mode
## this whole file exists to remove.
static func format(family_id: StringName, values: PackedStringArray) -> String:
	_build()
	if not _patterns.has(family_id):
		return ""
	var pattern := String(_patterns[family_id])
	var expected := int(pattern.count("%s"))
	if values.size() != expected:
		return ""
	var out := pattern
	for value in values:
		# One placeholder per iteration, deliberately: `String.replace` would
		# substitute every `%s` with the first value, producing a key that is
		# well-formed and wrong -- the exact shape of bug this file removes.
		var cursor := out.find("%s")
		if cursor < 0:
			return ""
		out = out.substr(0, cursor) + String(value) + out.substr(cursor + 2)
	if out.contains("%s"):
		return ""
	return out


## Rows whose `dimensions` count disagrees with the `%s` count in `pattern`.
## A family table that cannot round-trip is worse than no table, because it
## looks authoritative.
static func arity_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	var seen := {}
	for row in FAMILIES:
		var family_id := String(row["id"])
		var pattern := String(row.get("pattern", ""))
		var dimensions: Array = row.get("dimensions", [])
		if family_id.is_empty() or pattern.is_empty() or dimensions.is_empty():
			errors.append("stat_key_family_row_incomplete:%s" % family_id)
			continue
		if seen.has(family_id):
			errors.append("stat_key_family_id_duplicate:%s" % family_id)
			continue
		seen[family_id] = true
		if int(pattern.count("%s")) != dimensions.size():
			errors.append("stat_key_family_arity_mismatch:%s:%d!=%d" % [
				family_id, int(pattern.count("%s")), dimensions.size()])
		if String(row.get("consumer", "")).strip_edges().is_empty():
			errors.append("stat_key_family_consumer_undeclared:%s" % family_id)
	return errors
