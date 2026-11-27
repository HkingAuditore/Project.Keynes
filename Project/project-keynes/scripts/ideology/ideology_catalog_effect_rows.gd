extends RefCounted

## Validates and packs effect, override and synergy rows.

const IdeologyEffectParameterScript = preload(
	"res://scripts/ideology/ideology_effect_parameter.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")
const PROGRAM_KEY_PREFIX := "ideology.effect."


## Display names for the build routes (体系) that route-tag synergies are keyed
## by. Ids are the contract; these strings are presentation only and falling
## back to the raw id is a supported outcome, so adding a route to the content
## never requires touching this table before it can be referenced.
const ROUTE_DISPLAY_NAMES := {
	"cropland": "田垄",
	"granary": "仓廪",
	"mining": "矿冶",
	"workshop": "工坊",
	"market": "市易",
	"thoroughfare": "通衢",
	"learning": "学识",
	"labor": "劳作",
	"livelihood": "生灵",
	"clan": "宗族",
	"era": "纪元",
	"fiscal": "度支",
	"season": "天时",
	"terrain": "山河",
}


static func _expand_override_rows(override: Resource, declared_programs: Dictionary,
		route_index: Dictionary, ordered_definitions: Array[Resource],
		selector_kind_by_program: Dictionary) -> Dictionary:
	var match_kind := int(override.match_kind)
	var match_text := String(override.match_value).strip_edges()
	if match_text.is_empty() and match_kind == \
			IdeologyEffectParameterScript.MatchKind.PROGRAM:
		match_text = String(override.target_definition_key).strip_edges()
	if match_kind == IdeologyEffectParameterScript.MatchKind.PROGRAM:
		var target_key := IdeologyEffectDefinitionScript.definition_key_of(
			StringName(match_text))
		if target_key.is_empty() or not declared_programs.has(target_key):
			return {"ok": false, "reason":
				"ideology_synergy_override_target_unknown:%s" % match_text}
		return {"ok": true, "rows": [{"match_kind": match_kind,
			"match_value": target_key}]}
	if match_kind == IdeologyEffectParameterScript.MatchKind.TAG:
		if match_text.begins_with(PROGRAM_KEY_PREFIX):
			match_text = match_text.trim_prefix(PROGRAM_KEY_PREFIX)
		return {"ok": true, "rows": [{"match_kind": match_kind,
			"match_value": match_text}]}
	if match_kind != IdeologyEffectParameterScript.MatchKind.ROUTE:
		return {"ok": false, "reason": "ideology_effect_parameter_match_kind_invalid"}
	if not route_index.has(match_text):
		return {"ok": false, "reason":
			"ideology_synergy_override_route_unknown:%s" % match_text}
	var rows: Array = []
	var seen: Dictionary = {}
	var rewrite_field := int(override.field)
	var source_kind := -1
	if rewrite_field == IdeologyEffectParameterScript.Field.SELECTOR_KIND:
		match int(override.value):
			IdeologyEffectDefinitionScript.TargetSelectorKind.NEIGHBORS_R1:
				source_kind = IdeologyEffectDefinitionScript.TargetSelectorKind.NEIGHBORS_R2
			IdeologyEffectDefinitionScript.TargetSelectorKind.NEIGHBORS_R2:
				source_kind = IdeologyEffectDefinitionScript.TargetSelectorKind.NEIGHBORS_R1
			IdeologyEffectDefinitionScript.TargetSelectorKind.TAG_SOURCE_R1:
				source_kind = IdeologyEffectDefinitionScript.TargetSelectorKind.TAG_SOURCE_R2
			IdeologyEffectDefinitionScript.TargetSelectorKind.TAG_SOURCE_R2:
				source_kind = IdeologyEffectDefinitionScript.TargetSelectorKind.TAG_SOURCE_R1
			_:
				return {"ok": false,
					"reason": "ideology_effect_parameter_selector_kind_invalid"}
	for dense_id in route_index[match_text]:
		var definition: Resource = ordered_definitions[dense_id]
		for level in definition.levels:
			for effect in level.persistent_effects:
				if effect == null or effect.definition_key == &"":
					continue
				var program_key := PROGRAM_KEY_PREFIX + String(effect.definition_key)
				if not declared_programs.has(program_key) or seen.has(program_key):
					continue
				if source_kind >= 0 and int(selector_kind_by_program.get(
						program_key, -1)) != source_kind:
					continue
				seen[program_key] = true
				rows.append({"match_kind":
					IdeologyEffectParameterScript.MatchKind.PROGRAM,
					"match_value": program_key})
	if rows.is_empty():
		return {"ok": false, "reason":
			"ideology_synergy_override_route_no_programs:%s" % match_text}
	return {"ok": true, "rows": rows}

static func _append_effect_rows(out: Dictionary, effects: Array[Resource], persistent: bool,
		declared_programs: Dictionary, tally: Dictionary) -> String:
	var prefix := "persistent" if persistent else "on_enter"
	for effect in effects:
		if effect == null or not effect is EffectCommandScript:
			return "ideology_effect_resource_invalid"
		if effect.command_key == &"" or effect.definition_key == &"":
			return "ideology_effect_invalid"
		# A row that names a declared program is a routing marker: the program
		# (compiled into EffectRuntime) owns conditions, cadence, target selector
		# and magnitude, so the row's own domain/opcode/selector are not used.
		# Emitting the row keeps level_persistent_offsets aligned.
		if declared_programs.has(PROGRAM_KEY_PREFIX + String(effect.definition_key)):
			tally["owned"] = int(tally["owned"]) + 1
			var bucket := "persistent" if persistent else "enter"
			tally[bucket] = int(tally[bucket]) + 1
			out["%s_actions" % prefix].append(effect.action)
			out["%s_domains" % prefix].append(effect.domain)
			out["%s_opcodes" % prefix].append(effect.opcode)
			out["%s_values_q16" % prefix].append(effect.value_q16)
			out["%s_duration_days" % prefix].append(effect.duration_days)
			out["%s_stacks" % prefix].append(effect.stacks)
			out["%s_command_keys" % prefix].append(String(effect.command_key))
			out["%s_definition_keys" % prefix].append(String(effect.definition_key))
			out["%s_payload_i0" % prefix].append(effect.payload_i0)
			out["%s_payload_i1" % prefix].append(effect.payload_i1)
			out["%s_payload_i2" % prefix].append(effect.payload_i2)
			out["%s_payload_i3" % prefix].append(effect.payload_i3)
			continue
		if effect.action < 1 or effect.action > 6 or effect.domain < 0 or effect.domain >= 32 \
				or effect.stacks <= 0 or effect.duration_days < -1 \
				or effect.target_resolver < 0 or effect.target_resolver > 2 \
				or effect.value_mode < 0 or effect.value_mode > 1:
			return "ideology_effect_invalid"
		if effect.target_resolver == 0 and effect.static_target == 0:
			return "ideology_effect_static_target_invalid"
		if effect.target_resolver != 1:
			return "ideology_effect_target_resolver_invalid"
		if persistent and (effect.action != 1 or effect.domain < 0 or effect.domain > 3 \
				or effect.opcode != 1):
			return "ideology_persistent_effect_not_reversible_modifier"
		if not persistent:
			match int(effect.action):
				1:
					if effect.domain < 0 or effect.domain > 3 or effect.opcode != 1:
						return "ideology_modifier_effect_opcode_invalid"
				2:
					if effect.domain != 1 or effect.opcode < 1 or effect.opcode > 14:
						return "ideology_country_effect_opcode_invalid"
				3:
					if effect.domain != 2 or effect.opcode < 1 or effect.opcode > 15:
						return "ideology_economy_effect_opcode_invalid"
				4:
					if effect.domain != 3 or effect.opcode <= 0:
						return "ideology_gameplay_effect_opcode_invalid"
				5:
					if effect.domain != 4 or effect.opcode <= 0:
						return "ideology_publish_event_opcode_invalid"
				6:
					if effect.domain != 6 or effect.opcode not in [1, 2, 3]:
						return "ideology_custom_domain_adapter_unregistered"
					if effect.opcode == 3 and (effect.value_q16 <= 0 \
							or effect.value_q16 > 65535):
						return "ideology_on_enter_free_draw_invalid"
				_:
					return "ideology_effect_action_invalid"
		out["%s_actions" % prefix].append(effect.action)
		out["%s_domains" % prefix].append(effect.domain)
		out["%s_opcodes" % prefix].append(effect.opcode)
		out["%s_values_q16" % prefix].append(effect.value_q16)
		out["%s_duration_days" % prefix].append(effect.duration_days)
		out["%s_stacks" % prefix].append(effect.stacks)
		out["%s_command_keys" % prefix].append(String(effect.command_key))
		out["%s_definition_keys" % prefix].append(String(effect.definition_key))
		out["%s_payload_i0" % prefix].append(effect.payload_i0)
		out["%s_payload_i1" % prefix].append(effect.payload_i1)
		out["%s_payload_i2" % prefix].append(effect.payload_i2)
		out["%s_payload_i3" % prefix].append(effect.payload_i3)
	out["level_%s_offsets" % prefix].append(out["%s_actions" % prefix].size())
	return ""

static func _append_synergy_effect_rows(out: Dictionary,
		effects: Array[Resource]) -> String:
	for effect in effects:
		if effect == null or not effect is EffectCommandScript:
			return "ideology_synergy_effect_resource_invalid"
		if effect.action != 1 or effect.domain < 0 or effect.domain > 3 \
				or effect.opcode != 1 or effect.stacks <= 0 \
				or effect.duration_days < -1 or effect.target_resolver != 1 \
				or effect.command_key == &"" or effect.definition_key == &"":
			return "ideology_synergy_effect_not_reversible_modifier"
		out.synergy_effect_actions.append(effect.action)
		out.synergy_effect_domains.append(effect.domain)
		out.synergy_effect_opcodes.append(effect.opcode)
		out.synergy_effect_values_q16.append(effect.value_q16)
		out.synergy_effect_duration_days.append(effect.duration_days)
		out.synergy_effect_stacks.append(effect.stacks)
		out.synergy_effect_command_keys.append(String(effect.command_key))
		out.synergy_effect_definition_keys.append(String(effect.definition_key))
		out.synergy_effect_payload_i0.append(effect.payload_i0)
		out.synergy_effect_payload_i1.append(effect.payload_i1)
		out.synergy_effect_payload_i2.append(effect.payload_i2)
		out.synergy_effect_payload_i3.append(effect.payload_i3)
	out.synergy_effect_offsets.append(out.synergy_effect_actions.size())
	return ""

## Expands a route-tag synergy selector into the concrete dense card ids it
## covers. Pure: it takes the already-built route index and returns either the
## member list or a rejection that names the route and the numbers involved.
##
## Split out of `compile_native_catalog` because every interesting case here is
## a boundary -- an unknown route, a tier taller than its route, an empty
## bucket -- and those cost a whole compiled catalog to stage inline while
## costing one line to stage here.
static func _expand_route_synergy_members(route_tag: String,
		route_index: Dictionary, min_count: int) -> Dictionary:
	var route_key := route_tag.strip_edges()
	if route_key.is_empty():
		return {"ok": false, "reason": "ideology_synergy_route_tag_empty"}
	if not route_index.has(route_key):
		return {"ok": false, "reason":
			"ideology_synergy_route_tag_unknown:%s" % route_key}
	var members: PackedInt32Array = route_index[route_key]
	# An empty bucket is a *different* failure from an unknown tag: the tag is
	# spelled right and n cards carry it -- there are just no cards yet. Kept
	# apart because the fix differs (author cards vs fix the id), and a shared
	# message would send the next reader to the wrong file.
	if members.is_empty():
		return {"ok": false, "reason":
			"ideology_synergy_route_tag_no_members:%s" % route_key}
	# A tier that can never open is worse than a missing tier: it reads as an
	# implemented bond in the UI and never fires.
	if min_count > members.size():
		return {"ok": false, "reason":
			"ideology_synergy_route_tag_min_count_exceeds_members:%s:%d>%d" % [
				route_key, min_count, members.size()]}
	return {"ok": true, "members": members, "route_tag": route_key}

## How many live Effect instances one program row can own at once.
##
## This is the multiplicand the concurrency budget was missing. Three tiers:
##
##  * Not a per-cell domain -> exactly one instance (a country/climate/resource
##    program is one instance per card no matter what its selector says).
##  * A per-cell domain with a single-target selector -> one instance.
##  * A per-cell domain with a fan-out selector -> the program's own cell cap,
##    or `SELECTOR_MAX_CELLS` when it leaves the cap at the runtime default.
##
## Deliberately an upper bound rather than a measurement: the point is to fail
## on a catalog that CAN exceed the budget, and a real map may legitimately be
## smaller. Under-counting here would be the same silent pass this change
## exists to remove.
static func _program_live_target_cap(program: Resource) -> int:
	const SINGLE_TARGET_KINDS := [0, 2, 3, 4, 5]
	const STACK_POLICY_ADD_STACK := 2
	# L2-8: an ADD_STACK program owns one instance PER LAYER, because each layer
	# carries its own duration. The budget has to count them: a 3-stack program
	# fans out 3x, not 1x, and the whole point of the concurrency check is that a
	# catalog which cannot fit is rejected at build time.
	var layers := 1
	if int(program.stack_policy) == STACK_POLICY_ADD_STACK:
		layers = maxi(1, mini(int(program.max_stacks), 64))
	if int(program.target_domain) != 2:
		return layers
	if int(program.target_selector_kind) in SINGLE_TARGET_KINDS:
		return layers
	var params: PackedInt32Array = program.target_selector_param
	var cells := IdeologyEffectDefinitionScript.SELECTOR_MAX_CELLS
	if params.size() > 0:
		var declared_cap := int(params[0])
		if declared_cap >= 1:
			cells = mini(declared_cap, IdeologyEffectDefinitionScript.SELECTOR_MAX_CELLS)
	return layers * cells
