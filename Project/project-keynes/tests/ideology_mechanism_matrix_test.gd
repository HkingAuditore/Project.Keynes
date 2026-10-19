extends SceneTree

## M4 acceptance: the six mechanism cards.
##
## Each card is a probe for a *different* way the effect's target changes with
## world state. This test does not simulate the economy -- it asserts the content
## layer declares the right plumbing, so a card cannot silently regress into yet
## another flat number tweak:
##
##   V1 level    -> country scalar        V2 none    -> R1 neighbours
##   V3 output share -> R1                V4 resource specialisation -> R2
##   V5 stack count  -> terrain component V6 two conditions AND -> distance N
##
## It also guards the metric-id contract: metric_keys[] is indexed by metric id,
## so its length must match the native FAMILY_METRIC_COUNT and the first 37
## entries must never move (existing family effects read those ids).

const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")

## Metric ids this file depends on. Must match FamilyEffectMetricId in
## gdext/src/economy_runtime.h.
const METRIC_EXTRACTIVE_OUTPUT_SHARE := 38
const METRIC_DOMINANT_SECTOR_OUTPUT_SHARE := 42
const METRIC_DOMINANT_RESOURCE_ID := 43
const METRIC_DOMINANT_RESOURCE_STOCK_SHARE := 44
const STATE_STACK_COUNT := 4
const FAMILY_METRIC_COUNT := 50

const OP_METRIC_GTE := 2
const OP_STATE_GTE := 5
const OP_BOOL_AND := 6
const OP_CONST := 1
const OP_EMIT_COMMAND := 11

const SEL_NEIGHBORS_R1 := 6
const SEL_NEIGHBORS_R2 := 7
const SEL_SAME_TERRAIN_COMPONENT := 8
const SEL_DISTANCE_N := 11

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("ideology mechanism matrix: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_metric_key_contract()
	var content: Resource = IdeologyEffectCatalogScript.load_default()
	if content == null:
		_expect("load default ideology effect catalog", false)
		return
	_expect("default catalog validates", String(content.validate()).is_empty(),
		String(content.validate()))

	var by_key := {}
	for effect in content.effects:
		by_key[String(effect.definition_key)] = effect

	_expect("six mechanism cards present", by_key.size() == 6,
		"got %d: %s" % [by_key.size(), ", ".join(PackedStringArray(by_key.keys()))])

	for key in ["v1_granary_belt", "v2_forge_ring", "v3_vein_dominance",
			"v4_iron_throne", "v5_stacked_workshop", "v6_guild_monopoly"]:
		_expect("card %s exists" % key, by_key.has(key))

	# Every card must actually emit something; an effect with no command is a
	# no-op that would look "implemented" in the catalog and do nothing in play.
	for key in by_key:
		var effect: Resource = by_key[key]
		_expect("%s emits at least one command" % key, effect.commands.size() > 0)
		_expect("%s has a CONST+EMIT program" % key, _has_emit_program(effect))
		_expect("%s routes through ideology.effect.*" % key,
			String(effect.program_key()) == "ideology.effect.%s" % key)

	# V1: condition on level, target unchanged (country scalar).
	if by_key.has("v1_granary_belt"):
		var v1: Resource = by_key["v1_granary_belt"]
		_expect("V1 gates on STATE level", _has_condition(v1, OP_STATE_GTE, 0))
		_expect("V1 targets the country", int(v1.target_domain) == 3)

	# V2: no condition, target = R1.
	if by_key.has("v2_forge_ring"):
		var v2: Resource = by_key["v2_forge_ring"]
		_expect("V2 is unconditional", v2.conditions.is_empty())
		_expect("V2 selects R1", int(v2.target_selector_kind) == SEL_NEIGHBORS_R1)

	# V3: the output-share feedback loop. The condition MUST read an output
	# share, not the building-count share, or the loop cannot close.
	if by_key.has("v3_vein_dominance"):
		var v3: Resource = by_key["v3_vein_dominance"]
		_expect("V3 gates on extractive OUTPUT share",
			_has_condition(v3, OP_METRIC_GTE, METRIC_EXTRACTIVE_OUTPUT_SHARE))
		_expect("V3 does not gate on the building-count share",
			not _has_condition(v3, OP_METRIC_GTE, 27))
		_expect("V3 selects R1", int(v3.target_selector_kind) == SEL_NEIGHBORS_R1)
		_expect("V3 fan-out capped", _param0(v3) > 0)

	# V4: resource specialisation -> widened target.
	if by_key.has("v4_iron_throne"):
		var v4: Resource = by_key["v4_iron_throne"]
		_expect("V4 gates on resource stock share",
			_has_condition(v4, OP_METRIC_GTE, METRIC_DOMINANT_RESOURCE_STOCK_SHARE))
		_expect("V4 selects R2", int(v4.target_selector_kind) == SEL_NEIGHBORS_R2)

	# V5: stacking build. Needs a real stack policy, not a one-shot.
	if by_key.has("v5_stacked_workshop"):
		var v5: Resource = by_key["v5_stacked_workshop"]
		_expect("V5 gates on STATE_STACK_COUNT",
			_has_condition(v5, OP_STATE_GTE, STATE_STACK_COUNT))
		_expect("V5 uses a stacking policy", int(v5.stack_policy) != 0)
		_expect("V5 allows multiple stacks", int(v5.max_stacks) > 1)
		_expect("V5 selects terrain component",
			int(v5.target_selector_kind) == SEL_SAME_TERRAIN_COMPONENT)

	# V6: two conditions genuinely ANDed, target = hop limited.
	if by_key.has("v6_guild_monopoly"):
		var v6: Resource = by_key["v6_guild_monopoly"]
		_expect("V6 combines two conditions",
			v6.conditions.size() >= 3, "conditions=%d" % v6.conditions.size())
		_expect("V6 explicitly ANDs them", _has_condition(v6, OP_BOOL_AND, 0),
			"without BOOL_AND the postfix stack would only keep the last condition")
		_expect("V6 reads an output share",
			_has_condition(v6, OP_METRIC_GTE, METRIC_DOMINANT_SECTOR_OUTPUT_SHARE))
		_expect("V6 reads stack count",
			_has_condition(v6, OP_STATE_GTE, STATE_STACK_COUNT))
		_expect("V6 selects by hop distance",
			int(v6.target_selector_kind) == SEL_DISTANCE_N)
		_expect("V6 declares a hop count", v6.target_selector_param.size() >= 2
			and int(v6.target_selector_param[1]) > 0,
			"param1 carries the hop count for DISTANCE_N")

	# Every condition that reads a metric must stay inside the mask window, or
	# the publisher never writes it and the condition is permanently false.
	for key in by_key:
		for condition in by_key[key].conditions:
			if int(condition.op) in [OP_METRIC_GTE, 3, 4]:
				var metric_id := int(condition.arg0)
				_expect("%s metric id %d in range" % [key, metric_id],
					metric_id >= 0 and metric_id < 64,
					"metric_mask is a uint64")


func _test_metric_key_contract() -> void:
	# metric_keys lives on the compiled EffectCatalog, not on the builder.
	var catalog: Resource = EffectDomainCatalogScript.build()
	_expect("effect domain catalog builds", catalog != null)
	if catalog == null:
		return
	var keys: PackedStringArray = catalog.metric_keys
	_expect("metric_keys length matches native FAMILY_METRIC_COUNT",
		keys.size() == FAMILY_METRIC_COUNT,
		"gdscript=%d native=%d" % [keys.size(), FAMILY_METRIC_COUNT])
	if keys.size() != FAMILY_METRIC_COUNT:
		return
	# Ids 0..36 predate this milestone and are read by shipped family effects.
	_expect("legacy metric id 18 unchanged",
		String(keys[18]) == "family.dominant_sector_share_q16")
	_expect("legacy metric id 27 unchanged",
		String(keys[27]) == "cell.dominant_sector_share_q16")
	_expect("new output-share id 38",
		String(keys[METRIC_EXTRACTIVE_OUTPUT_SHARE]) ==
			"cell.sector_output_share.extractive_q16")
	_expect("new dominant output share id 42",
		String(keys[METRIC_DOMINANT_SECTOR_OUTPUT_SHARE]) ==
			"cell.dominant_sector_output_share_q16")
	_expect("new resource id row 43",
		String(keys[METRIC_DOMINANT_RESOURCE_ID]) == "cell.dominant_resource_id")
	_expect("new resource share row 44",
		String(keys[METRIC_DOMINANT_RESOURCE_STOCK_SHARE]) ==
			"cell.dominant_resource_stock_share_q16")
	# No duplicate keys: a duplicate means two ids collide and one is unreachable.
	var seen := {}
	for key in keys:
		_expect("metric key %s unique" % key, not seen.has(String(key)))
		seen[String(key)] = true


func _has_condition(effect: Resource, op: int, arg0: int) -> bool:
	for condition in effect.conditions:
		if int(condition.op) == op and int(condition.arg0) == arg0:
			return true
	return false


func _has_emit_program(effect: Resource) -> bool:
	var has_const := false
	var has_emit := false
	for instruction in effect.instructions:
		if int(instruction.op) == OP_CONST:
			has_const = true
		elif int(instruction.op) == OP_EMIT_COMMAND:
			has_emit = true
	return has_const and has_emit


func _param0(effect: Resource) -> int:
	if effect.target_selector_param.is_empty():
		return 0
	return int(effect.target_selector_param[0])


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		push_error("[FAIL] %s" % label)
	else:
		push_error("[FAIL] %s (%s)" % [label, detail])
