extends SceneTree

## L5-14 acceptance: the tag id is resolved from a name, at build time, once.
##
## Why this exists
## ---------------
## `target_selector_param[1]` is a raw 1-based index into the tag dictionary
## (see `TargetTagDictionary`). A card that writes `4` there is correct only
## until a tag is inserted above it — and when that happens the card does not
## break, it silently starts matching different cells. Nothing in the runtime
## can notice: the id is valid, the selector runs, the effect applies.
##
## So the authoring surface takes a name (`&"cell.market"`) and the compiler
## resolves it. Three things therefore have to be pinned:
##
##  1. The resolution itself: blank is a no-op, known writes `param[1]`, and
##     every flavour of "unknown" names itself instead of defaulting to 0 —
##     because 0 already means something else ("no tag filter").
##  2. The card rulebook: a tag name is only meaningful for the two tag-scoped
##     kinds, and must not compete with a raw `param[1]`.
##  3. The whole compile loop, not just the helper: a typo must fail the build
##     even on a card whose program key is already claimed. Resolving after the
##     duplicate-key short-circuit would hide exactly the typos this feature
##     exists to surface.
##
## The id contract itself (which name maps to which number) lives in
## `target_tag_dictionary_test.gd`; this file only assumes it is stable.

const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const IdeologyEffectDefinitionScript = preload("res://scripts/ideology/ideology_effect_definition.gd")
const TargetTagDictionaryScript = preload("res://scripts/effect/target_tag_dictionary.gd")

## Deliberately `var`, not `const`: a const initialiser that reaches through a
## preloaded script's enum is not accepted by every GDScript version, and a
## parse error here would fail the whole file rather than one check.
var OWN_TERRITORY: int = IdeologyEffectDefinitionScript.TargetSelectorKind.OWN_TERRITORY
var TAG_ANY_CELL: int = IdeologyEffectDefinitionScript.TargetSelectorKind.TAG_ANY_CELL
var OWNER: int = IdeologyEffectDefinitionScript.TargetSelectorKind.OWNER

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("effect selector tag resolution: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_blank_tag_is_a_no_op()
	_test_known_tag_writes_param_one()
	_test_unknown_tag_names_itself()
	_test_missing_dictionary_is_distinguishable()
	_test_short_param_array_is_widened()
	_test_card_rulebook()
	_test_multi_tag_rulebook()
	_test_compile_loop_end_to_end()
	_test_compile_loop_resolves_before_dedupe()
	_test_multi_tag_compile_loop()


## 1. A blank name must cost nothing: the card keeps its raw params, which is
##    how every pre-L5-14 card is authored.
func _test_blank_tag_is_a_no_op() -> void:
	var program := _program([8, 0])
	var reason: String = EffectDomainCatalogScript._apply_selector_tag(
		program, &"", {"cell.market": 4})
	_expect("a blank tag name is accepted", reason.is_empty(), reason)
	_expect("a blank tag name leaves params untouched",
		_params(program) == PackedInt32Array([8, 0]), str(_params(program)))


## 2. The whole point: a name becomes the id the runtime reads.
func _test_known_tag_writes_param_one() -> void:
	var program := _program([8, 0])
	var reason: String = EffectDomainCatalogScript._apply_selector_tag(
		program, &"cell.market", {"cell.frontier": 1, "cell.market": 4})
	_expect("a known tag name is accepted", reason.is_empty(), reason)
	_expect("the id lands in param[1]",
		_params(program) == PackedInt32Array([8, 4]), str(_params(program)))
	# param[0] is the cell cap and is none of this function's business; a
	# resolution that rewrote it would silently change how many cells a card
	# hits — the same class of bug, one slot over.
	_expect("the cell cap in param[0] survives resolution",
		_params(program)[0] == 8, str(_params(program)))

	var unfiltered := _program([8, 0])
	reason = EffectDomainCatalogScript._apply_selector_tag(
		unfiltered, &"cell.frontier", {"cell.frontier": 1, "cell.market": 4})
	_expect("the first tag resolves to 1, not to 'no filter'", reason.is_empty(), reason)
	_expect("id 1 on a fresh card is written, not treated as unset",
		_params(unfiltered) == PackedInt32Array([8, 1]), str(_params(unfiltered)))


## 3. Unknown names. 0 is already spoken for — it means "no tag filter" — so an
##    unknown name must never fall back to it.
func _test_unknown_tag_names_itself() -> void:
	var program := _program([8, 0])
	var reason: String = EffectDomainCatalogScript._apply_selector_tag(
		program, &"cell.nowhere", {"cell.market": 4})
	_expect("an unknown tag name is rejected", not reason.is_empty())
	_expect("the rejection names the invariant",
		reason.begins_with("effect_catalog_target_selector_tag_unknown"), reason)
	_expect("the rejection carries the program key and the offending name",
		reason.ends_with(":%s:cell.nowhere" % String(program.key)), reason)
	_expect("a rejected tag leaves params untouched",
		_params(program) == PackedInt32Array([8, 0]), str(_params(program)))

	# A dictionary entry whose id is 0 cannot be honoured: writing it would turn
	# "filter by tag" into "no filter", which is a different card.
	var zero_id := _program([8, 0])
	reason = EffectDomainCatalogScript._apply_selector_tag(
		zero_id, &"cell.market", {"cell.market": 0})
	_expect("id 0 is rejected as unknown rather than read as 'no filter'",
		reason.begins_with("effect_catalog_target_selector_tag_unknown"), reason)


## 4. "No dictionary" and "typo" are different failures. Reporting a typo when
##    the economy catalog failed sends the next reader hunting for a bad tag
##    that is not there.
func _test_missing_dictionary_is_distinguishable() -> void:
	var program := _program([8, 0])
	var reason: String = EffectDomainCatalogScript._apply_selector_tag(
		program, &"cell.market", {})
	_expect("a missing dictionary names itself",
		reason.begins_with("effect_catalog_target_selector_tag_no_dictionary"), reason)


## 5. `to_effect_definition()` always emits two slots, but a hand-built or
##    older program may not, and `param[1]` must still land.
func _test_short_param_array_is_widened() -> void:
	var empty := _program([])
	var reason: String = EffectDomainCatalogScript._apply_selector_tag(
		empty, &"cell.market", {"cell.market": 4})
	_expect("an empty param array is widened, not skipped", reason.is_empty(), reason)
	_expect("widening fills param[0] with 'runtime default'",
		_params(empty) == PackedInt32Array([0, 4]), str(_params(empty)))

	var single := _program([16])
	reason = EffectDomainCatalogScript._apply_selector_tag(
		single, &"cell.market", {"cell.market": 4})
	_expect("a one-slot param array keeps its cap",
		reason.is_empty() and _params(single) == PackedInt32Array([16, 4]),
		"%s %s" % [reason, str(_params(single))])


## 6. The card's own rulebook. The compiler calls `validate()` rather than
##    re-deriving these rules, so this is the single place they are stated.
func _test_card_rulebook() -> void:
	var cases := [
		{
			"label": "a tag on an untagged kind",
			"kind": OWNER, "tag": &"cell.market", "params": PackedInt32Array([0, 0]),
			"reason": "ideology_effect_selector_tag_kind_invalid",
		},
		{
			"label": "a tag competing with a raw param[1]",
			"kind": TAG_ANY_CELL, "tag": &"cell.market",
			"params": PackedInt32Array([0, 7]),
			"reason": "ideology_effect_selector_tag_conflicts_with_param",
		},
		{
			"label": "a tag outside the selector ceiling",
			"kind": 14, "tag": &"", "params": PackedInt32Array([0, 0]),
			"reason": "ideology_effect_selector_invalid",
		},
	]
	for entry in cases:
		var card := _card(&"test.rule", int(entry["kind"]),
			StringName(entry["tag"]), entry["params"])
		var error: String = card.validate()
		_expect("%s is rejected" % entry["label"],
			error == String(entry["reason"]), error)

	for kind in [OWN_TERRITORY, TAG_ANY_CELL]:
		var accepted := _card(&"test.ok", int(kind), &"cell.market",
			PackedInt32Array([0, 0]))
		var error: String = accepted.validate()
		_expect("a tag on kind %d is accepted" % int(kind), error.is_empty(), error)


## 6b. The multi-name form. `target_selector_tags` writes the *same* slot as
##     `target_selector_tag`, so every rule about that slot has to hold for the
##     list too — otherwise the list becomes a way to smuggle a second meaning
##     into `param[1]`.
func _test_multi_tag_rulebook() -> void:
	var both := _card(&"test.both", TAG_ANY_CELL, &"cell.market",
		PackedInt32Array([0, 0]),
		PackedStringArray(["cell.market", "cell.grain"]))
	_expect("naming a tag and a tag list at once is rejected",
		both.validate() == "ideology_effect_selector_tag_conflicts_with_tags",
		both.validate())

	var too_many := _card(&"test.many", TAG_ANY_CELL, &"", PackedInt32Array([0, 0]),
		PackedStringArray(["cell.frontier", "cell.settlement", "cell.metropolis",
			"cell.market", "cell.grain"]))
	_expect("five names exceed the authoring cap",
		too_many.validate() == "ideology_effect_selector_tag_count_invalid",
		too_many.validate())

	var blank := _card(&"test.blank", TAG_ANY_CELL, &"", PackedInt32Array([0, 0]),
		PackedStringArray(["cell.market", "   "]))
	_expect("a blank name in the list is rejected",
		blank.validate() == "ideology_effect_selector_tag_name_empty",
		blank.validate())

	# `A AND A` is `A`, so a repeat never changes the meaning — which is exactly
	# why it must fail: it is always a copy-paste slip, and collapsing it
	# quietly leaves the card saying something its author did not write.
	var repeated := _card(&"test.repeat", TAG_ANY_CELL, &"", PackedInt32Array([0, 0]),
		PackedStringArray(["cell.market", "cell.grain", "cell.market"]))
	_expect("a repeated name is rejected rather than collapsed",
		repeated.validate() == "ideology_effect_selector_tag_name_duplicate",
		repeated.validate())

	var wrong_kind := _card(&"test.kind", OWNER, &"", PackedInt32Array([0, 0]),
		PackedStringArray(["cell.market", "cell.grain"]))
	_expect("a tag list on an untagged kind is rejected",
		wrong_kind.validate() == "ideology_effect_selector_tag_kind_invalid",
		wrong_kind.validate())

	var competing := _card(&"test.param", TAG_ANY_CELL, &"",
		PackedInt32Array([0, 9]),
		PackedStringArray(["cell.market", "cell.grain"]))
	_expect("a tag list competing with a raw param[1] is rejected",
		competing.validate() == "ideology_effect_selector_tag_conflicts_with_param",
		competing.validate())

	for kind in [OWN_TERRITORY, TAG_ANY_CELL]:
		var accepted := _card(&"test.multi_ok", int(kind), &"",
			PackedInt32Array([0, 0]),
			PackedStringArray(["cell.frontier", "cell.grain", "cell.sector.agriculture"]))
		_expect("a three-name AND on kind %d is accepted" % int(kind),
			accepted.validate().is_empty(), accepted.validate())


## 7. End to end: a card that writes a name compiles into a program whose
##    `param[1]` is the id the runtime reads — read back from the dictionary the
##    same build published, so this cannot drift from the id contract.
func _test_compile_loop_end_to_end() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var card := _card(&"test.tag_any_cell", TAG_ANY_CELL, &"cell.market",
		PackedInt32Array([0, 0]))
	var catalog: Resource = EffectDomainCatalogScript.build(null, _effects([card]))
	_expect("a card naming a real tag compiles", catalog != null)
	if catalog == null:
		return
	var definitions: Array[Resource] = catalog.definitions
	var compiled := _find(definitions, "ideology.effect.test.tag_any_cell")
	_expect("the card reached the definition table", compiled != null)
	if compiled == null:
		return
	var expected := int(TargetTagDictionaryScript.tag_index(
		catalog.get("target_tags"), "cell.market"))
	_expect("the published dictionary knows cell.market", expected > 0, str(expected))
	var params: PackedInt32Array = compiled.target_selector_param
	_expect("param[1] is the resolved id", params.size() > 1 and params[1] == expected,
		"%s vs %d" % [str(params), expected])

	var typo := _card(&"test.bad_tag", TAG_ANY_CELL, &"cell.market_typo",
		PackedInt32Array([0, 0]))
	var rejected: Resource = EffectDomainCatalogScript.build(null, _effects([typo]))
	_expect("a typo'd tag name fails the whole build", rejected == null)


## 8. The regression this ordering exists for: the resolution runs before the
##    duplicate-key short-circuit, so the second card to claim a key still has
##    its tag checked. Resolve-after-dedupe would return null here — a green
##    build with a misspelled tag silently dropped from the table.
func _test_compile_loop_resolves_before_dedupe() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var first := _card(&"test.duplicate", TAG_ANY_CELL, &"cell.market",
		PackedInt32Array([0, 0]))
	var second := _card(&"test.duplicate", TAG_ANY_CELL, &"cell.no_such_tag",
		PackedInt32Array([0, 0]))
	var rejected: Resource = EffectDomainCatalogScript.build(
		null, _effects([first, second]))
	_expect("a duplicate key does not hide the second card's typo", rejected == null)


## 9. The multi-name compile loop. This is the check that the runtime needs no
##    change: `param[1]` still holds ONE 1-based id, and the id points at a
##    synthetic tag the build appended to the same dictionary every other card
##    reads. If this ever grew a second param slot or a second table, the
##    worker side would silently disagree with the main thread.
func _test_multi_tag_compile_loop() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var names := PackedStringArray([
		"cell.frontier", "cell.sector.agriculture", "cell.grain"])
	var card := _card(&"test.three_tags", TAG_ANY_CELL, &"",
		PackedInt32Array([0, 0]), names)
	var catalog: Resource = EffectDomainCatalogScript.build(null, _effects([card]))
	_expect("a three-tag card compiles", catalog != null)
	if catalog == null:
		return
	var compiled := _find(catalog.definitions, "ideology.effect.test.three_tags")
	_expect("the three-tag card reached the definition table", compiled != null)
	if compiled == null:
		return
	var tags: Array = catalog.get("target_tags")
	var composite := "cell.frontier&cell.grain&cell.sector.agriculture"
	var resolved := int(TargetTagDictionaryScript.tag_index(tags, composite))
	_expect("the build appended the synthetic tag", resolved > 0, composite)
	var params: PackedInt32Array = compiled.target_selector_param
	_expect("param[1] is the synthetic id",
		params.size() > 1 and params[1] == resolved,
		"%s vs %d" % [str(params), resolved])
	_expect("the cell cap in param[0] survives the fold", params[0] == 0,
		str(params))
	# The synthetic tag is appended, never inserted: inserting would shift every
	# id below it and silently retarget cards that never changed.
	_expect("cell.frontier keeps id 1 after the append",
		int(TargetTagDictionaryScript.tag_index(tags, "cell.frontier")) == 1,
		str(TargetTagDictionaryScript.tag_index(tags, "cell.frontier")))
	_expect("the synthetic tag is the last entry",
		resolved == tags.size(), "%d vs %d" % [resolved, tags.size()])
	var rows: Array = tags[resolved - 1]["rows"]
	var clauses := {}
	for row in rows:
		clauses[int(row["clause"])] = true
	_expect("the synthetic tag carries the 15-row clause product",
		rows.size() == TargetTagDictionaryScript.GRAIN_GOODS.size() * 3,
		str(rows.size()))
	_expect("its clauses are one per grain good",
		clauses.size() == TargetTagDictionaryScript.GRAIN_GOODS.size(),
		str(clauses.size()))

	# Two cards listing the same tags in different orders must share one entry,
	# not append two: otherwise the dictionary grows with card count and the two
	# entries can drift apart the moment one of them is regenerated.
	var first := _card(&"test.order_a", TAG_ANY_CELL, &"",
		PackedInt32Array([0, 0]),
		PackedStringArray(["cell.frontier", "cell.sector.agriculture", "cell.grain"]))
	var second := _card(&"test.order_b", TAG_ANY_CELL, &"",
		PackedInt32Array([0, 0]),
		PackedStringArray(["cell.grain", "cell.frontier", "cell.sector.agriculture"]))
	var shared: Resource = EffectDomainCatalogScript.build(
		null, _effects([first, second]))
	_expect("both orderings compile", shared != null)
	if shared == null:
		return
	var shared_tags: Array = shared.get("target_tags")
	var occurrences := 0
	for tag in shared_tags:
		if String(tag["name"]) == composite:
			occurrences += 1
	_expect("both orderings collapse onto one dictionary entry",
		occurrences == 1, str(occurrences))
	var left := _find(shared.definitions, "ideology.effect.test.order_a")
	var right := _find(shared.definitions, "ideology.effect.test.order_b")
	_expect("both cards address the same id",
		left != null and right != null
			and left.target_selector_param[1] == right.target_selector_param[1],
		"%s vs %s" % [
			str(left.target_selector_param) if left != null else "null",
			str(right.target_selector_param) if right != null else "null"])

	# A typo anywhere in the list must fail the whole build, same as the
	# single-name path — the fold is not allowed to be the softer door.
	var typo := _card(&"test.multi_typo", TAG_ANY_CELL, &"",
		PackedInt32Array([0, 0]),
		PackedStringArray(["cell.frontier", "cell.grann", "cell.sector.agriculture"]))
	_expect("a typo inside a tag list fails the build",
		EffectDomainCatalogScript.build(null, _effects([typo])) == null)


func _program(params: Array) -> Resource:
	var program: Resource = EffectDefinitionScript.new()
	program.key = &"test.program"
	program.target_selector_param = PackedInt32Array(params)
	return program


func _params(program: Resource) -> PackedInt32Array:
	return program.target_selector_param


## A card with everything `validate()` requires already valid, so a failure in
## `_test_card_rulebook` can only come from the selector fields under test.
func _card(key: StringName, kind: int, tag: StringName,
		params: PackedInt32Array,
		tags: PackedStringArray = PackedStringArray()) -> Resource:
	var card: Resource = IdeologyEffectDefinitionScript.new()
	card.definition_key = key
	card.target_selector_kind = kind
	card.target_selector_tag = tag
	card.target_selector_tags = tags
	card.target_selector_param = params
	var instructions: Array[Resource] = [EffectInstructionScript.new()]
	var commands: Array[Resource] = [EffectCommandScript.new()]
	card.instructions = instructions
	card.commands = commands
	return card


func _effects(cards: Array) -> Resource:
	var catalog: Resource = IdeologyEffectCatalogScript.new()
	var effects: Array[Resource] = []
	for card in cards:
		effects.append(card)
	catalog.effects = effects
	return catalog


func _find(definitions: Array, key: String) -> Resource:
	for definition in definitions:
		if definition != null and String(definition.key) == key:
			return definition
	return null


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		if detail.is_empty():
			push_error("[FAIL] %s" % label)
		else:
			push_error("[FAIL] %s (%s)" % [label, detail])
