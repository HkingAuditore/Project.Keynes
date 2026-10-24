extends SceneTree

## L4-12 acceptance: `route_tag` stops being authoring-only metadata.
##
## Why this exists
## ---------------
## `IdeologyDefinition.route_tag` used to carry the comment "the runtime never
## reads it". A 体系 bond therefore had to enumerate every member card id in its
## synergy row, which means adding a card to a build route silently leaves that
## bond behind — it does not break, it just keeps counting the old roster.
##
## The fix is deliberately compile-time only: a synergy may now select its
## members by route tag, and `IdeologyCatalog` expands that into the same flat
## (ideology, min_level, location_mask) rows the native runtime already eats.
## Nothing on the native side changed, nothing in the save format changed, and
## the runtime "reads" the route by construction.
##
## What has to be pinned here
## --------------------------
##  1. A card's route membership is one authored field plus extras, and the
##     accessor is the only place that decides what the set is.
##  2. A repeated route is rejected, not folded — folding would erase the only
##     trace a copy-paste mistake leaves.
##  3. A route synergy and a named synergy are alternatives, never a union.
##  4. Expansion: order-preserving on success, and every failure names itself
##     distinctly (unknown / empty / tier taller than the route).
##
## The end-to-end compile is covered indirectly: expansion is a pure function
## and `compile_native_catalog` only appends its output to the requirement
## tables, which `ideology_content_test.gd` already walks.

const IdeologyDefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const IdeologySynergyDefinitionScript = preload(
	"res://scripts/ideology/ideology_synergy_definition.gd")
const IdeologyLevelDefinitionScript = preload(
	"res://scripts/ideology/ideology_level_definition.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("ideology route tag: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_card_route_set()
	_test_card_route_rules()
	_test_synergy_form_exclusivity()
	_test_synergy_route_rules()
	_test_expansion_success()
	_test_expansion_failures()
	_test_route_display_names()
	_test_compile_end_to_end()


## 1. The accessor is the single source of truth for "which routes is this card
##    in", so it must handle the shapes authoring actually produces.
func _test_card_route_set() -> void:
	var card := _card(&"a", &"", PackedStringArray())
	_expect("an untagged card belongs to no route",
		card.route_tags().is_empty(), str(card.route_tags()))

	card = _card(&"a", &"mining", PackedStringArray())
	_expect("a primary route is the whole set when there are no extras",
		card.route_tags() == PackedStringArray(["mining"]), str(card.route_tags()))

	card = _card(&"a", &"mining", PackedStringArray(["labor"]))
	_expect("extras follow the primary, in authored order",
		card.route_tags() == PackedStringArray(["mining", "labor"]),
		str(card.route_tags()))

	# A card with extras but no primary is legal: some cards are pure
	# contributors to a second route. The set must not start with a blank.
	card = _card(&"a", &"", PackedStringArray(["season"]))
	_expect("a card with only extras still yields just those",
		card.route_tags() == PackedStringArray(["season"]), str(card.route_tags()))

	# Whitespace is stripped, and an entry that strips to the primary is dropped
	# rather than counted twice. `validate()` rejects the authored repeat; this
	# is the defensive half so a loaded save/resource can never double-count.
	card = _card(&"a", &" mining ", PackedStringArray(["  ", "mining"]))
	_expect("padded ids are normalised and a repeat of the primary is dropped",
		card.route_tags() == PackedStringArray(["mining"]), str(card.route_tags()))


## 2. Authoring rules. Count cap so a copy-paste loop cannot enrol one card into
##    every bond; repeats and blanks rejected by name.
func _test_card_route_rules() -> void:
	_expect("an untagged card validates",
		_card(&"a", &"", PackedStringArray()).validate().is_empty())

	var too_many := _card(&"a", &"mining",
		PackedStringArray(["labor", "market", "learning"]))
	_expect("more than two extras is rejected",
		too_many.validate() == "ideology_route_tag_count_invalid",
		too_many.validate())
	_expect("exactly two extras still validates",
		_card(&"a", &"mining", PackedStringArray(["labor", "market"]))
			.validate().is_empty())

	var blank := _card(&"a", &"", PackedStringArray([""]))
	_expect("a blank extra route is rejected by name",
		blank.validate() == "ideology_route_tag_empty", blank.validate())

	var repeated := _card(&"a", &"mining", PackedStringArray(["mining"]))
	_expect("repeating the primary is rejected, not folded",
		repeated.validate() == "ideology_route_tag_duplicate", repeated.validate())

	var repeated_extra := _card(&"a", &"mining", PackedStringArray(["labor", "labor"]))
	_expect("repeating an extra is rejected too",
		repeated_extra.validate() == "ideology_route_tag_duplicate",
		repeated_extra.validate())


## 3. Route form vs named form. The failure this prevents is a row that looks
##    like it selects by route while the compiler silently took the id list.
func _test_synergy_form_exclusivity() -> void:
	var route_form := _synergy_route(&"r", &"mining", 2, 0, 2)
	_expect("a route synergy validates",
		route_form.validate().is_empty(), route_form.validate())
	_expect("a route synergy reports the route form",
		route_form.uses_route_tag())

	var both := _synergy_route(&"r", &"mining", 2, 0, 2)
	both.required_ideology_ids = PackedStringArray(["a"])
	both.minimum_levels = PackedInt32Array([0])
	both.location_masks = PackedByteArray([2])
	_expect("route tag plus explicit ids is rejected",
		both.validate() == "ideology_synergy_route_tag_conflicts_with_ids",
		both.validate())

	var named := _synergy_named(&"n", PackedStringArray(["a", "b"]), 1)
	_expect("a named synergy validates", named.validate().is_empty(), named.validate())
	_expect("a named synergy is not the route form", not named.uses_route_tag())

	# Whitespace-only is the "forgot to fill it in" shape, and it must fall back
	# to the named branch rather than becoming a route that matches nothing.
	var padded := _synergy_route(&"r", &"   ", 1, 0, 2)
	padded.required_ideology_ids = PackedStringArray(["a"])
	padded.minimum_levels = PackedInt32Array([0])
	padded.location_masks = PackedByteArray([2])
	_expect("a whitespace-only route tag is the named form",
		not padded.uses_route_tag() and padded.validate().is_empty(),
		padded.validate())


## 4. Route-form-only rules. `min_count` is the tier ("2 张"), so 0 is not a
##    tier — it would make the bond true with nothing equipped.
func _test_synergy_route_rules() -> void:
	var zero_tier := _synergy_route(&"r", &"mining", 0, 0, 2)
	_expect("a zero tier is rejected",
		zero_tier.validate() == "ideology_synergy_route_tag_min_count_invalid",
		zero_tier.validate())

	var bad_mask := _synergy_route(&"r", &"mining", 2, 0, 0)
	_expect("a zero location mask is rejected",
		bad_mask.validate() == "ideology_synergy_route_tag_mask_invalid",
		bad_mask.validate())

	var out_of_range := _synergy_route(&"r", &"mining", 2, 0, 8)
	_expect("a mask bit outside equipped/national-spirit is rejected",
		out_of_range.validate() == "ideology_synergy_route_tag_mask_invalid",
		out_of_range.validate())


## 5. Expansion success. Order matters: the native requirement table is walked
##    in row order, so a map-iteration order would make two builds of the same
##    content disagree.
func _test_expansion_success() -> void:
	var index := {"mining": PackedInt32Array([0, 3, 7])}
	var result: Dictionary = IdeologyCatalogScript._expand_route_synergy_members(
		"mining", index, 2)
	_expect("a known route expands", bool(result.get("ok", false)),
		str(result.get("reason", "")))
	_expect("expansion keeps dense order",
		result.get("members", PackedInt32Array()) == PackedInt32Array([0, 3, 7]),
		str(result.get("members", PackedInt32Array())))
	_expect("expansion reports the normalised route id",
		String(result.get("route_tag", "")) == "mining",
		String(result.get("route_tag", "")))

	# Padded ids must resolve: the route key is normalised on both sides.
	var padded: Dictionary = IdeologyCatalogScript._expand_route_synergy_members(
		"  mining  ", index, 2)
	_expect("a padded route id still expands", bool(padded.get("ok", false)),
		str(padded.get("reason", "")))

	# min_count equal to the member count is the top tier and must be allowed.
	var top: Dictionary = IdeologyCatalogScript._expand_route_synergy_members(
		"mining", index, 3)
	_expect("a tier equal to the member count expands",
		bool(top.get("ok", false)), str(top.get("reason", "")))


## 6. The three failures must be distinguishable. They send the reader to three
##    different files: fix the id, author cards, lower the tier.
func _test_expansion_failures() -> void:
	var index := {"mining": PackedInt32Array([0, 3, 7]), "empty_route": PackedInt32Array()}

	var blank: Dictionary = IdeologyCatalogScript._expand_route_synergy_members(
		"  ", index, 1)
	_expect("a blank route id is rejected",
		String(blank.get("reason", "")).begins_with(
			"ideology_synergy_route_tag_empty"), str(blank.get("reason", "")))

	var unknown: Dictionary = IdeologyCatalogScript._expand_route_synergy_members(
		"nowhere", index, 1)
	_expect("an unknown route id names itself",
		String(unknown.get("reason", "")) == "ideology_synergy_route_tag_unknown:nowhere",
		str(unknown.get("reason", "")))

	var empty: Dictionary = IdeologyCatalogScript._expand_route_synergy_members(
		"empty_route", index, 1)
	_expect("a route with no members is not reported as unknown",
		String(empty.get("reason", "")) ==
			"ideology_synergy_route_tag_no_members:empty_route",
		str(empty.get("reason", "")))

	var tall: Dictionary = IdeologyCatalogScript._expand_route_synergy_members(
		"mining", index, 4)
	_expect("a tier taller than the route names both numbers",
		String(tall.get("reason", "")) ==
			"ideology_synergy_route_tag_min_count_exceeds_members:mining:4>3",
		str(tall.get("reason", "")))

	# A missing key entirely (catalog with no routes at all) is the unknown case,
	# not an empty bucket -- there is no difference to report and the fix is the
	# same, so this asserts the shared message rather than inventing a third.
	var no_index: Dictionary = IdeologyCatalogScript._expand_route_synergy_members(
		"mining", {}, 1)
	_expect("an absent route index reports unknown",
		String(no_index.get("reason", "")) == "ideology_synergy_route_tag_unknown:mining",
		str(no_index.get("reason", "")))


## 7. Display names are presentation only, and a missing entry must degrade to
##    the raw id so content can ship before the table catches up.
func _test_route_display_names() -> void:
	_expect("a documented route resolves to its Chinese label",
		IdeologyCatalogScript.route_display_name("mining") == "矿冶",
		IdeologyCatalogScript.route_display_name("mining"))
	_expect("an undocumented route falls back to its id",
		IdeologyCatalogScript.route_display_name("brand_new") == "brand_new",
		IdeologyCatalogScript.route_display_name("brand_new"))
	_expect("the label list follows route order",
		IdeologyCatalogScript._route_display_names(
			PackedStringArray(["mining", "brand_new"]))
			== PackedStringArray(["矿冶", "brand_new"]))
	_expect("an empty route list yields an empty label list",
		IdeologyCatalogScript._route_display_names(PackedStringArray()).is_empty())


## 8. End to end through `compile_native_catalog` + `catalog_view`.
##
## The pure-function tests above prove the expansion arithmetic. They cannot
## prove the compile loop actually calls it, in the right order, against the
## right index -- which is the same argument §29.6 made for the tag-name
## resolver. So one real catalog is mutated (in memory only) and compiled.
##
## The shipped catalog already has several mining cards. The native route table is a
## catalog contract (it maps card masks to route_count scalar ids), so a synthetic
## route could not be represented by the EffectDomainCatalog's fixed scalar table.
## The acceptance is that the requirement span shows up with the authored
## level/mask and that a typo still fails the build.
func _test_compile_end_to_end() -> void:
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("economy catalog compiles for the end-to-end case",
		bool(economy_ir.get("ok", false)))
	if not bool(economy_ir.get("ok", false)):
		return
	var catalog: Resource = IdeologyCatalogScript.load_default()
	_expect("default ideology catalog loads", catalog != null)
	if catalog == null:
		return
	const ROUTE := &"mining"
	var card_ids := PackedStringArray()
	for definition in catalog.definitions:
		if definition == null:
			continue
		if definition.route_tags().has(ROUTE):
			card_ids.append(String(definition.id))
	_expect("the shipped catalog has at least two mining cards",
		card_ids.size() >= 2,
		str(card_ids))
	if card_ids.size() < 2:
		return

	var tier := _synergy_route(&"zz_route_probe_tier", ROUTE, 2, 1, 2)
	catalog.synergies.append(tier)
	var compiled: Dictionary = catalog.compile_native_catalog(economy_ir, economy_ir)
	_expect("a route-tag synergy compiles",
		bool(compiled.get("ok", false)), str(compiled.get("reason", "")))
	if bool(compiled.get("ok", false)):
		var synergy_ids: PackedStringArray = compiled.synergy_ids
		var synergy_index := synergy_ids.find("zz_route_probe_tier")
		_expect("the route synergy is present in the compiled table",
			synergy_index >= 0, str(synergy_index))
		if synergy_index >= 0:
			var offsets: PackedInt32Array = compiled.synergy_requirement_offsets
			var begin := int(offsets[synergy_index])
			var end := int(offsets[synergy_index + 1])
			_expect("the route expands to exactly its shipped members",
				end - begin == card_ids.size(), "%d..%d expected=%d" %
					[begin, end, card_ids.size()])
			var levels: PackedInt32Array = compiled.synergy_requirement_min_levels
			var masks: PackedByteArray = compiled.synergy_requirement_location_masks
			var all_level_one := true
			var all_mask_two := true
			var dense: PackedInt32Array = compiled.synergy_requirement_ideology_ids
			var matched := PackedStringArray()
			for cursor in range(begin, end):
				all_level_one = all_level_one and int(levels[cursor]) == 1
				all_mask_two = all_mask_two and int(masks[cursor]) == 2
				matched.append(String(compiled.ideology_ids[int(dense[cursor])]))
			_expect("every expanded row carries the authored min level",
				all_level_one)
			_expect("every expanded row carries the authored location mask",
				all_mask_two)
			# The expansion must select exactly the tagged cards -- not one more
			# (a route index that also matched an untagged card) and not one
			# fewer (a route index built before the tag was written).
			matched.sort()
			var expected := card_ids.duplicate()
			expected.sort()
			_expect("the expanded rows are exactly the tagged cards",
				matched == expected, "%s vs %s" % [matched, expected])
			_expect("the authored tier survives expansion",
				int(compiled.synergy_min_counts[synergy_index]) == 2,
				str(compiled.synergy_min_counts[synergy_index]))

	# The view must expose the route on the card and on the synergy, otherwise
	# the player-facing "体系" label and the bond tooltip still need the id list.
	var view: Dictionary = catalog.catalog_view(economy_ir, economy_ir)
	_expect("catalog view still compiles", bool(view.get("ok", false)),
		str(view.get("reason", "")))
	if bool(view.get("ok", false)):
		var saw_route := false
		for row in view.get("ideologies", []) as Array:
			var tags: PackedStringArray = (row as Dictionary).get(
				"route_tags", PackedStringArray())
			if tags.has(ROUTE):
				saw_route = true
				var names: PackedStringArray = (row as Dictionary).get(
					"route_names", PackedStringArray())
				_expect("a known route id resolves to its display label",
					names.has(IdeologyCatalogScript.route_display_name(ROUTE)),
					str(names))
				break
		_expect("the view exposes route membership per card", saw_route)

	# A misspelled route must fail the build. Without this the bond compiles with
	# zero requirement rows and reads as "implemented, never fires".
	catalog.synergies.append(_synergy_route(&"zz_route_probe_typo", &"no_such_route", 1, 0, 2))
	var broken: Dictionary = catalog.compile_native_catalog(economy_ir, economy_ir)
	_expect("a misspelled route fails the build", not bool(broken.get("ok", false)))
	_expect("the failure names the misspelled route",
		String(broken.get("reason", "")) ==
			"ideology_synergy_route_tag_unknown:no_such_route",
		str(broken.get("reason", "")))


func _card(id: StringName, primary: StringName,
		extras: PackedStringArray) -> Resource:
	var card := IdeologyDefinitionScript.new()
	card.id = id
	card.route_tag = primary
	card.secondary_route_tags = extras
	# Minimum viable level table: `validate()` requires 1..64 levels with
	# non-decreasing thresholds.
	var level := IdeologyLevelDefinitionScript.new()
	level.understanding_threshold_q16 = 0
	card.levels = [level]
	return card


## Route-form synergy. `tier` is `min_count`, `min_level`/`mask` apply to every
## expanded row.
func _synergy_route(id: StringName, route: StringName, tier: int,
		min_level: int, mask: int) -> Resource:
	var synergy := IdeologySynergyDefinitionScript.new()
	synergy.id = id
	synergy.route_tag = route
	synergy.min_count = tier
	synergy.route_tag_min_level = min_level
	synergy.route_tag_location_mask = mask
	return synergy


func _synergy_named(id: StringName, ids: PackedStringArray, tier: int) -> Resource:
	var synergy := IdeologySynergyDefinitionScript.new()
	synergy.id = id
	synergy.required_ideology_ids = ids
	synergy.minimum_levels = PackedInt32Array()
	synergy.location_masks = PackedByteArray()
	for _index in ids.size():
		synergy.minimum_levels.append(0)
		synergy.location_masks.append(2)
	synergy.min_count = tier
	return synergy


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("[FAIL] %s" % label)
	else:
		print("[FAIL] %s (%s)" % [label, detail])
