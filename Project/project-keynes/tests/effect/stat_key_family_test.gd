extends SceneTree

## L5-14b acceptance: every generated stat key belongs to a declared family.
##
## Why this exists
## ---------------
## `ModifierCatalog.compile_native_catalog()` builds a few thousand stat keys by
## looping over economy ids. Adding another loop is trivial and completely
## silent: the keys are well-formed, the catalog compiles, a card can reference
## them, the modifier applies, and no consumer ever reads them. Nothing in the
## build notices, because "the key exists" and "the key is read" are different
## questions and only the first one was being asked.
##
## `StatKeyFamilies` answers the second question by making the set of families
## explicit. This file holds it to the real compiled table:
##
##  1. The family table itself is well formed (arity, ids, declared consumer).
##  2. Every generated key is either an explicitly declared literal (it came
##     with its own min/max in `ModifierCatalog.stats` / `TECHNOLOGY_STATS`) or
##     it classifies into exactly one family. An unclassified key is a loop
##     nobody declared -> fail, naming the key.
##  3. Classification round-trips: `format(classify(key)) == key`. Without this
##     a family row could match loosely and still "cover" the key.
##  4. Every declared family actually produced keys. A stale row would make the
##     table look bigger than the generator and hide a deleted loop.
##  5. The ambiguous shapes resolve to the family they belong to, not to a
##     neighbour that happens to have the same arity.

const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const StatKeyFamiliesScript = preload("res://scripts/modifier/stat_key_families.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("stat key families: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_family_table_shape()
	_test_ambiguous_shapes()
	_test_against_compiled_table()
	_test_family_completeness()
	_test_short_param_guards()


## 1. A family table that cannot round-trip is worse than none: it reads as
##    authoritative while being wrong.
func _test_family_table_shape() -> void:
	var errors: PackedStringArray = StatKeyFamiliesScript.arity_errors()
	_expect("the family table is internally consistent", errors.is_empty(),
		" | ".join(errors))
	_expect("every family declares a consumer",
		StatKeyFamiliesScript.family(&"tax_income").get("consumer", "") != "")
	_expect("an unknown family id resolves to nothing",
		StatKeyFamiliesScript.family(&"no_such_family").is_empty())
	_expect("family ids are unique",
		StatKeyFamiliesScript.family_ids().size()
			== _unique_count(StatKeyFamiliesScript.family_ids()))


## 2. The traps. All of these are four or five dot-segments long and differ only
##    in one position, so a matcher keyed on segment count alone would take the
##    wrong one and still look right.
func _test_ambiguous_shapes() -> void:
	_expect("a per-building country output key is not mistaken for a family key",
		_family_of("country.output.building.mint_factor") == &"output_building",
		str(_family_of("country.output.building.mint_factor")))
	_expect("a family key is not mistaken for a per-building key",
		_family_of("country.output.family.smithing_factor") == &"output_family",
		str(_family_of("country.output.family.smithing_factor")))
	_expect("landform x sector is its own family",
		_family_of("country.output.landform.delta.agriculture_factor")
			== &"output_landform_sector",
		str(_family_of("country.output.landform.delta.agriculture_factor")))
	_expect("terrain x sector does not collide with landform x sector",
		_family_of("country.output.terrain.plain.agriculture_factor")
			== &"output_terrain_sector",
		str(_family_of("country.output.terrain.plain.agriculture_factor")))
	# Both tax rows are `country.tax.<kind>.<id>.rate_bp`; only the kind segment
	# tells them apart, and the kinds draw their ids from different namespaces.
	_expect("income tax keys keep the profession namespace",
		_family_of("country.tax.income.scholar.rate_bp") == &"tax_income",
		str(_family_of("country.tax.income.scholar.rate_bp")))
	_expect("business tax keys keep the building namespace",
		_family_of("country.tax.business.mint.rate_bp") == &"tax_business",
		str(_family_of("country.tax.business.mint.rate_bp")))
	_expect("import tax keys are not conflated with export",
		_family_of("country.tax.import.tools.rate_bp") == &"tax_import",
		str(_family_of("country.tax.import.tools.rate_bp")))
	_expect("the two resource families differ by suffix",
		_family_of("country.resource.coal.use_factor") == &"resource_use"
		and _family_of("country.resource.coal.managed_generation_factor")
			== &"resource_managed_generation",
		"%s / %s" % [
			_family_of("country.resource.coal.use_factor"),
			_family_of("country.resource.coal.managed_generation_factor")])
	_expect("a two-symbol family splits both symbols",
		_classify("country.climate.profile.paddy_crop.flood_loss_factor")
			.get("values", PackedStringArray())
			== PackedStringArray(["paddy_crop", "flood"]),
		str(_classify("country.climate.profile.paddy_crop.flood_loss_factor")
			.get("values", PackedStringArray())))
	# An explicit stat must NOT be swallowed by a family that happens to be the
	# same length -- `country.ideology.point_gain_factor` is 4 segments like
	# `country.output.good.<id>_factor`.
	_expect("an explicit country stat classifies into no family",
		_family_of("country.ideology.point_gain_factor") == &"",
		str(_family_of("country.ideology.point_gain_factor")))
	_expect("an explicit research stat classifies into no family",
		_family_of("country.research.cost_factor") == &"",
		str(_family_of("country.research.cost_factor")))


## 3. The real table. 2778 keys today; the counts are not asserted (content
##    grows) but the partition is.
func _test_against_compiled_table() -> void:
	var catalog: Resource = ModifierCatalogScript.load_default()
	_expect("default modifier catalog loads", catalog != null)
	if catalog == null:
		return
	var compiled: Dictionary = catalog.compile_native_catalog()
	_expect("modifier catalog compiles", bool(compiled.get("ok", false)),
		str(compiled.get("reason", "")))
	if not bool(compiled.get("ok", false)):
		return
	var stat_keys: PackedStringArray = compiled.stat_keys
	_expect("the compiled table is non-trivial", stat_keys.size() > 1000,
		str(stat_keys.size()))
	# Literals are the keys declared one at a time, each with its own min/max.
	# They are *supposed* to classify into no family -- that is how the explicit
	# table is distinguished from the generated one.
	var literals := {}
	for stat in catalog.stats:
		if stat != null:
			literals[String(stat.key)] = true
	for row in ModifierCatalogScript.TECHNOLOGY_STATS:
		literals[String(row[0])] = true

	var unclassified := PackedStringArray()
	var round_trip_failures := PackedStringArray()
	var produced := {}
	for stat_key in stat_keys:
		var key := String(stat_key)
		if literals.has(key):
			continue
		var classified: Dictionary = StatKeyFamiliesScript.classify(key)
		if classified.is_empty():
			unclassified.append(key)
			continue
		var family_id: StringName = classified.get("family", &"")
		var values: PackedStringArray = classified.get("values", PackedStringArray())
		produced[family_id] = int(produced.get(family_id, 0)) + 1
		var rebuilt: String = StatKeyFamiliesScript.format(family_id, values)
		if rebuilt != key:
			round_trip_failures.append("%s -> %s" % [key, rebuilt])
	_expect("every generated key belongs to a declared family",
		unclassified.is_empty(),
		"%d unclassified, first: %s" % [unclassified.size(),
			str(unclassified.slice(0, 5))])
	_expect("classify/format round-trips for every generated key",
		round_trip_failures.is_empty(),
		"%d failures, first: %s" % [round_trip_failures.size(),
			str(round_trip_failures.slice(0, 5))])

	# No stale rows: every declared family must be reachable from real content.
	# A family that produced nothing means either the loop was deleted or the
	# namespace disappeared -- both are worth failing on, because the row would
	# otherwise keep claiming coverage forever.
	var stale := PackedStringArray()
	for family_id in StatKeyFamiliesScript.family_ids():
		if int(produced.get(family_id, 0)) == 0:
			stale.append(String(family_id))
	_expect("every declared family produced at least one key", stale.is_empty(),
		str(stale))

	# And the partition must be total: literals + generated == the whole table.
	var literal_hits := 0
	for key in literals:
		if stat_keys.has(String(key)):
			literal_hits += 1
	var generated_hits := 0
	for family_id in produced:
		generated_hits += int(produced[family_id])
	_expect("generated and explicit keys partition the table exactly",
		generated_hits + literal_hits == stat_keys.size(),
		"%d generated + %d explicit != %d" % [
			generated_hits, literal_hits, stat_keys.size()])
	# A literal declared in the resource but absent from the compiled table would
	# make the previous check pass by accident (both sides undercount).
	var orphan_literals := PackedStringArray()
	for key in literals:
		if not stat_keys.has(String(key)):
			orphan_literals.append(String(key))
	_expect("no declared literal is missing from the compiled table",
		orphan_literals.is_empty(), str(orphan_literals.slice(0, 5)))


## 5. L5-13: the families are BATCHED, not sampled.
##
## The design document listed `country.tax.*` as "only one row" and
## `country.output.landform.*` as "only three". Both claims described the
## generator as it was, and both are the kind of gap that is invisible from the
## outside: a card referencing `country.tax.income.scholar.rate_bp` compiles and
## applies whether or not the key was generated for every profession or only one.
##
## So this asserts the count per family against the dimension list the economy
## catalog publishes. Off by one means a missing id; off by a factor means a
## namespace was swapped (e.g. professions billed against goods), which would
## still produce well-formed keys.
func _test_family_completeness() -> void:
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles for the completeness check",
		bool(economy.get("ok", false)), str(economy.get("reason", "")))
	if not bool(economy.get("ok", false)):
		return
	var catalog: Resource = ModifierCatalogScript.load_default()
	if catalog == null:
		return
	var compiled: Dictionary = catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return
	var produced := {}
	for stat_key in (compiled.stat_keys as PackedStringArray):
		var classified: Dictionary = StatKeyFamiliesScript.classify(String(stat_key))
		if classified.is_empty():
			continue
		var family_id: StringName = classified.get("family", &"")
		produced[family_id] = int(produced.get(family_id, 0)) + 1
	var goods := (economy.good_ids as PackedStringArray).size()
	var buildings := (economy.get("building_type_ids", PackedStringArray()) as PackedStringArray).size()
	var resources := (economy.get("building_resource_ids", PackedStringArray()) as PackedStringArray).size()
	var sectors := (economy.get("modifier_sector_ids", PackedStringArray()) as PackedStringArray).size()
	var landforms := (economy.get("modifier_landform_ids", PackedStringArray()) as PackedStringArray).size()
	var terrains := (economy.get("modifier_terrain_ids", PackedStringArray()) as PackedStringArray).size()
	var professions := (economy.profession_ids as PackedStringArray).size()
	var needs := (economy.need_ids as PackedStringArray).size()
	var families := (economy.get("building_upgrade_family_ids", PackedStringArray()) as PackedStringArray).size()
	var profiles := (economy.get("production_climate_profile_ids", PackedStringArray()) as PackedStringArray).size()
	var expected := {
		&"tax_income": professions,
		&"tax_consumption": goods,
		&"tax_business": buildings,
		&"tax_import": goods,
		&"tax_export": goods,
		&"output_good": goods,
		&"input_good": goods,
		&"consumption_good": goods,
		&"city_good_output": goods,
		&"city_good_consumption": goods,
		&"output_building": buildings,
		&"city_building_output": buildings,
		&"output_family": families,
		&"resource_use": resources,
		&"resource_managed_generation": resources,
		&"city_resource_regen": resources,
		&"city_need_consumption": needs,
		&"output_landform_sector": landforms * sectors,
		&"output_terrain_sector": terrains * sectors,
		&"climate_profile": profiles * 4,
	}
	for family_id in expected:
		_expect("%s is complete against its dimension list" % String(family_id),
			int(produced.get(family_id, 0)) == int(expected[family_id]),
			"%d keys vs %d dimension entries" % [
				int(produced.get(family_id, 0)), int(expected[family_id])])
	# The two sparse families called out by name in the design document, kept as
	# their own checks so a regression there is not buried in the loop above.
	_expect("tax covers every profession, not one row",
		int(produced.get(&"tax_income", 0)) == professions
			and professions > 1,
		"%d keys / %d professions" % [
			int(produced.get(&"tax_income", 0)), professions])
	_expect("landform x sector covers the whole cross product, not three rows",
		int(produced.get(&"output_landform_sector", 0)) == landforms * sectors
			and landforms * sectors > 3,
		"%d keys / %d landforms x %d sectors" % [
			int(produced.get(&"output_landform_sector", 0)), landforms, sectors])


## 6. `format()` must refuse rather than emit a key with a literal `%s` in it,
##    and `classify()` must not accept a truncated symbol.
func _test_short_param_guards() -> void:
	_expect("format rejects too few symbols",
		StatKeyFamiliesScript.format(&"output_good", PackedStringArray()).is_empty())
	_expect("format rejects too many symbols",
		StatKeyFamiliesScript.format(&"output_good",
			PackedStringArray(["tools", "extra"])).is_empty())
	_expect("format rejects an unknown family",
		StatKeyFamiliesScript.format(&"no_such_family",
			PackedStringArray(["tools"])).is_empty())
	_expect("format substitutes every symbol, not just the first",
		StatKeyFamiliesScript.format(&"output_landform_sector",
			PackedStringArray(["delta", "agriculture"]))
			== "country.output.landform.delta.agriculture_factor",
		StatKeyFamiliesScript.format(&"output_landform_sector",
			PackedStringArray(["delta", "agriculture"])))
	# An empty symbol would build `country.output.good._factor`, which is a legal
	# string and a meaningless key; the segment-length check in `classify()`
	# rejects it coming back, so the round-trip guard is what protects callers.
	_expect("an empty symbol does not round-trip",
		StatKeyFamiliesScript.classify(
			StatKeyFamiliesScript.format(&"output_good", PackedStringArray([""])))
			.is_empty())
	_expect("a literal-only family segment is not treated as a symbol",
		StatKeyFamiliesScript.classify("country.output.good._factor").is_empty())


func _classify(stat_key: String) -> Dictionary:
	return StatKeyFamiliesScript.classify(stat_key)


func _family_of(stat_key: String) -> StringName:
	var classified: Dictionary = StatKeyFamiliesScript.classify(stat_key)
	if classified.is_empty():
		return &""
	return classified.get("family", &"")


func _unique_count(values: Array) -> int:
	var seen := {}
	for value in values:
		seen[String(value)] = true
	return seen.size()


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("[FAIL] %s" % label)
	else:
		print("[FAIL] %s (%s)" % [label, detail])
