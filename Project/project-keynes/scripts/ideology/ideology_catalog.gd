class_name IdeologyCatalog
extends Resource

const DEFAULT_PATH := "res://data/ideologies/default_ideology_catalog.tres"
const IdeologyDefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const IdeologyRequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")
const IdeologyProfileScript = preload("res://scripts/ideology/ideology_profile.gd")
const IdeologyClassStanceScript = preload("res://scripts/ideology/ideology_class_stance.gd")
const IdeologySynergyDefinitionScript = preload("res://scripts/ideology/ideology_synergy_definition.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")

const PROTOCOL_VERSION := 1

@export var profile: Resource
@export var definitions: Array[Resource] = []
@export var synergies: Array[Resource] = []

static func load_default() -> Resource:
	var loaded := ResourceLoader.load(DEFAULT_PATH, "Resource")
	return loaded

func compile_native_catalog(country_catalog: Dictionary,
		economy_catalog: Dictionary = {}) -> Dictionary:
	var effective_profile = profile if profile != null else IdeologyProfileScript.new()
	if not effective_profile is IdeologyProfileScript:
		return {"ok": false, "reason": "ideology_profile_invalid"}
	var technology_ids: PackedStringArray = country_catalog.get("technology_ids", PackedStringArray())
	var signal_ids: PackedStringArray = country_catalog.get("research_signal_ids", PackedStringArray())
	var technology_index := {}
	var signal_index := {}
	for i in technology_ids.size(): technology_index[String(technology_ids[i])] = i
	for i in signal_ids.size(): signal_index[String(signal_ids[i])] = i
	var political_class_ids: Array[String] = []
	for value in economy_catalog.get("profession_class_ids", PackedStringArray()):
		var class_id := String(value).strip_edges()
		if class_id.is_empty():
			class_id = "general"
		if not political_class_ids.has(class_id):
			political_class_ids.append(class_id)
	if political_class_ids.is_empty():
		political_class_ids.append("general")
	political_class_ids.sort()
	var political_class_index := {}
	for i in political_class_ids.size():
		political_class_index[political_class_ids[i]] = i
	var ordered: Array[Resource] = definitions.duplicate()
	ordered.sort_custom(func(a, b) -> bool:
		return String(a.id) < String(b.id) if a != null and b != null else a != null)
	var gates := {}
	for definition in ordered:
		if definition == null or not definition is IdeologyDefinitionScript:
			return {"ok": false, "reason": "ideology_definition_resource_invalid"}
		var validation: String = definition.validate()
		if not validation.is_empty(): return {"ok": false, "reason": validation}
		for requirement in definition.draw_requirements:
			if requirement.kind == IdeologyRequirementScript.Kind.GATE:
				gates[String(requirement.key)] = true
	var gate_keys: Array = gates.keys()
	gate_keys.sort()
	var gate_index := {}
	for i in gate_keys.size(): gate_index[String(gate_keys[i])] = i
	var exclusion_keys: Array[String] = []
	for definition in ordered:
		var exclusion := String(definition.exclusion_group).strip_edges()
		if not exclusion.is_empty() and not exclusion_keys.has(exclusion):
			exclusion_keys.append(exclusion)
	exclusion_keys.sort()
	var exclusion_index := {}
	for i in exclusion_keys.size():
		exclusion_index[exclusion_keys[i]] = i
	var out := {
		"protocol_version": PROTOCOL_VERSION,
		"ideology_capacity": effective_profile.ideology_capacity,
		"national_spirit_capacity": effective_profile.national_spirit_capacity,
		"offer_choice_count": effective_profile.offer_choice_count,
		"offer_cost_q16": effective_profile.offer_cost_q16,
		"max_commands_per_slice": effective_profile.max_commands_per_slice,
		"max_transition_commands": effective_profile.max_transition_commands,
		"max_transition_polls_per_slice": effective_profile.max_transition_polls_per_slice,
		"max_active_visits_per_slice": effective_profile.max_active_visits_per_slice,
		"opinion_owner_influence_weight": effective_profile.opinion_owner_influence_weight,
		"opinion_funds_per_influence": effective_profile.opinion_funds_per_influence,
		"political_class_ids": PackedStringArray(political_class_ids),
		"ideology_ids": PackedStringArray(), "acquisition_flags": PackedByteArray(),
		"rarity_weights": PackedInt32Array(), "ideology_slot_costs": PackedInt32Array(),
		"spirit_slot_costs": PackedInt32Array(), "national_spirit_min_levels": PackedInt32Array(),
		"level_offsets": PackedInt32Array([0]), "level_thresholds_q16": PackedInt64Array(),
		"level_daily_understanding_q16": PackedInt64Array(),
		"technology_requirement_offsets": PackedInt32Array([0]),
		"technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0]),
		"signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0]), "gate_requirements": PackedInt32Array(),
		"level_persistent_offsets": PackedInt32Array([0]),
		"persistent_actions": PackedInt32Array(), "persistent_domains": PackedInt32Array(),
		"persistent_opcodes": PackedInt32Array(), "persistent_values_q16": PackedInt64Array(),
		"persistent_duration_days": PackedInt32Array(), "persistent_stacks": PackedInt32Array(),
		"persistent_command_keys": PackedStringArray(), "persistent_definition_keys": PackedStringArray(),
		"persistent_payload_i0": PackedInt64Array(), "persistent_payload_i1": PackedInt64Array(),
		"persistent_payload_i2": PackedInt64Array(), "persistent_payload_i3": PackedInt64Array(),
		"level_on_enter_offsets": PackedInt32Array([0]),
		"on_enter_actions": PackedInt32Array(), "on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(), "on_enter_values_q16": PackedInt64Array(),
		"on_enter_duration_days": PackedInt32Array(), "on_enter_stacks": PackedInt32Array(),
		"on_enter_command_keys": PackedStringArray(), "on_enter_definition_keys": PackedStringArray(),
		"on_enter_payload_i0": PackedInt64Array(), "on_enter_payload_i1": PackedInt64Array(),
		"on_enter_payload_i2": PackedInt64Array(), "on_enter_payload_i3": PackedInt64Array(),
		"gate_keys": PackedStringArray(gate_keys),
		"stance_offsets": PackedInt32Array([0]),
		"stance_class_indices": PackedInt32Array(),
		"stance_adopt_q16": PackedInt32Array(),
		"stance_repeal_q16": PackedInt32Array(),
		"stance_promote_q16": PackedInt32Array(),
		"stance_adopt_min_q16": PackedInt32Array(),
		"stance_repeal_min_q16": PackedInt32Array(),
		"stance_promote_min_q16": PackedInt32Array(),
		"adopt_thresholds_q16": PackedInt32Array(),
		"repeal_thresholds_q16": PackedInt32Array(),
		"promote_thresholds_q16": PackedInt32Array(),
		"exclusion_group_ids": PackedInt32Array(),
		"synergy_ids": PackedStringArray(),
		"synergy_requirement_offsets": PackedInt32Array([0]),
		"synergy_requirement_ideology_ids": PackedInt32Array(),
		"synergy_requirement_min_levels": PackedInt32Array(),
		"synergy_requirement_location_masks": PackedByteArray(),
		"synergy_effect_offsets": PackedInt32Array([0]),
		"synergy_effect_actions": PackedInt32Array(),
		"synergy_effect_domains": PackedInt32Array(),
		"synergy_effect_opcodes": PackedInt32Array(),
		"synergy_effect_values_q16": PackedInt64Array(),
		"synergy_effect_duration_days": PackedInt32Array(),
		"synergy_effect_stacks": PackedInt32Array(),
		"synergy_effect_command_keys": PackedStringArray(),
		"synergy_effect_definition_keys": PackedStringArray(),
		"synergy_effect_payload_i0": PackedInt64Array(),
		"synergy_effect_payload_i1": PackedInt64Array(),
		"synergy_effect_payload_i2": PackedInt64Array(),
		"synergy_effect_payload_i3": PackedInt64Array(),
		"ideology_synergy_offsets": PackedInt32Array([0]),
		"ideology_synergy_ids": PackedInt32Array(),
	}
	var seen := {}
	for definition in ordered:
		var key := String(definition.id)
		if seen.has(key): return {"ok": false, "reason": "ideology_id_duplicate"}
		seen[key] = true
		out.ideology_ids.append(key)
		out.acquisition_flags.append(definition.acquisition_flags)
		out.rarity_weights.append(definition.rarity_weight)
		out.ideology_slot_costs.append(definition.ideology_slot_cost)
		out.spirit_slot_costs.append(definition.national_spirit_slot_cost)
		out.national_spirit_min_levels.append(definition.national_spirit_min_level)
		out.adopt_thresholds_q16.append(definition.adopt_threshold_q16)
		out.repeal_thresholds_q16.append(definition.repeal_threshold_q16)
		out.promote_thresholds_q16.append(definition.promote_threshold_q16)
		var exclusion := String(definition.exclusion_group).strip_edges()
		out.exclusion_group_ids.append(
			int(exclusion_index.get(exclusion, -1)) if not exclusion.is_empty() else -1)
		var ordered_stances: Array[Resource] = definition.class_stances.duplicate()
		ordered_stances.sort_custom(func(a, b) -> bool:
			return String(a.class_id) < String(b.class_id))
		for stance in ordered_stances:
			if stance == null or not stance is IdeologyClassStanceScript \
					or not political_class_index.has(String(stance.class_id)):
				return {"ok": false, "reason": "ideology_stance_class_unknown"}
			out.stance_class_indices.append(
				int(political_class_index[String(stance.class_id)]))
			out.stance_adopt_q16.append(stance.adopt_stance_q16)
			out.stance_repeal_q16.append(stance.repeal_stance_q16)
			out.stance_promote_q16.append(stance.promote_stance_q16)
			out.stance_adopt_min_q16.append(stance.adopt_min_support_q16)
			out.stance_repeal_min_q16.append(stance.repeal_min_support_q16)
			out.stance_promote_min_q16.append(stance.promote_min_support_q16)
		out.stance_offsets.append(out.stance_class_indices.size())
		for level in definition.levels:
			out.level_thresholds_q16.append(level.understanding_threshold_q16)
			out.level_daily_understanding_q16.append(level.daily_understanding_q16)
			var effect_error := _append_effect_rows(out, level.persistent_effects, true)
			if not effect_error.is_empty(): return {"ok": false, "reason": effect_error}
			effect_error = _append_effect_rows(out, level.on_enter_effects, false)
			if not effect_error.is_empty(): return {"ok": false, "reason": effect_error}
		out.level_offsets.append(out.level_thresholds_q16.size())
		for requirement in definition.draw_requirements:
			match requirement.kind:
				IdeologyRequirementScript.Kind.TECHNOLOGY:
					if not technology_index.has(String(requirement.key)):
						return {"ok": false, "reason": "ideology_requirement_technology_unknown"}
					out.technology_requirements.append(technology_index[String(requirement.key)])
				IdeologyRequirementScript.Kind.RESEARCH_SIGNAL:
					if not signal_index.has(String(requirement.key)):
						return {"ok": false, "reason": "ideology_requirement_signal_unknown"}
					out.signal_requirements.append(signal_index[String(requirement.key)])
				IdeologyRequirementScript.Kind.GATE:
					out.gate_requirements.append(gate_index[String(requirement.key)])
				_:
					return {"ok": false, "reason": "ideology_requirement_kind_invalid"}
		out.technology_requirement_offsets.append(out.technology_requirements.size())
		out.signal_requirement_offsets.append(out.signal_requirements.size())
		out.gate_requirement_offsets.append(out.gate_requirements.size())
	var ideology_index := {}
	for index in out.ideology_ids.size():
		ideology_index[String(out.ideology_ids[index])] = index
	var ordered_synergies: Array[Resource] = synergies.duplicate()
	ordered_synergies.sort_custom(func(a, b) -> bool:
		return String(a.id) < String(b.id) if a != null and b != null else a != null)
	var reverse: Array[Array] = []
	reverse.resize(out.ideology_ids.size())
	for index in reverse.size():
		reverse[index] = []
	for synergy in ordered_synergies:
		if synergy == null or not synergy is IdeologySynergyDefinitionScript:
			return {"ok": false, "reason": "ideology_synergy_resource_invalid"}
		var synergy_error: String = synergy.validate()
		if not synergy_error.is_empty():
			return {"ok": false, "reason": synergy_error}
		if out.synergy_ids.has(String(synergy.id)):
			return {"ok": false, "reason": "ideology_synergy_id_duplicate"}
		var synergy_id: int = out.synergy_ids.size()
		out.synergy_ids.append(String(synergy.id))
		for requirement in synergy.required_ideology_ids.size():
			var required_id := String(synergy.required_ideology_ids[requirement])
			if not ideology_index.has(required_id):
				return {"ok": false, "reason": "ideology_synergy_ideology_unknown"}
			var dense_id := int(ideology_index[required_id])
			out.synergy_requirement_ideology_ids.append(dense_id)
			out.synergy_requirement_min_levels.append(
				int(synergy.minimum_levels[requirement]))
			out.synergy_requirement_location_masks.append(
				int(synergy.location_masks[requirement]))
			reverse[dense_id].append(synergy_id)
		out.synergy_requirement_offsets.append(
			out.synergy_requirement_ideology_ids.size())
		synergy_error = _append_synergy_effect_rows(
			out, synergy.persistent_effects)
		if not synergy_error.is_empty():
			return {"ok": false, "reason": synergy_error}
	for ideology_id in reverse.size():
		(reverse[ideology_id] as Array).sort()
		for synergy_id in reverse[ideology_id]:
			out.ideology_synergy_ids.append(int(synergy_id))
		out.ideology_synergy_offsets.append(out.ideology_synergy_ids.size())
	var base_transition_commands := 0
	for level in range(out.level_persistent_offsets.size() - 1):
		var persistent_count := int(out.level_persistent_offsets[level + 1]) \
			- int(out.level_persistent_offsets[level])
		var enter_count := int(out.level_on_enter_offsets[level + 1]) \
			- int(out.level_on_enter_offsets[level])
		base_transition_commands = maxi(base_transition_commands,
			persistent_count * 2 + enter_count)
	var max_transition_commands := base_transition_commands
	for ideology_id in out.ideology_ids.size():
		var synergy_effect_count := 0
		for cursor in range(out.ideology_synergy_offsets[ideology_id],
				out.ideology_synergy_offsets[ideology_id + 1]):
			var synergy_id := int(out.ideology_synergy_ids[cursor])
			synergy_effect_count += int(out.synergy_effect_offsets[synergy_id + 1]) \
				- int(out.synergy_effect_offsets[synergy_id])
		max_transition_commands = maxi(max_transition_commands,
			base_transition_commands + synergy_effect_count)
	if max_transition_commands > effective_profile.max_transition_commands:
		return {"ok": false, "reason": "ideology_transition_command_limit_exceeded"}
	out.ok = true
	return out

func _append_effect_rows(out: Dictionary, effects: Array[Resource], persistent: bool) -> String:
	var prefix := "persistent" if persistent else "on_enter"
	for effect in effects:
		if effect == null or not effect is EffectCommandScript:
			return "ideology_effect_resource_invalid"
		if effect.action < 1 or effect.action > 6 or effect.domain < 0 or effect.domain >= 32 \
				or effect.stacks <= 0 or effect.duration_days < -1 \
				or effect.target_resolver < 0 or effect.target_resolver > 2 \
				or effect.value_mode < 0 or effect.value_mode > 1 \
				or effect.command_key == &"" or effect.definition_key == &"":
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
					if effect.domain != 6 or effect.opcode != 1:
						return "ideology_custom_domain_adapter_unregistered"
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

func _append_synergy_effect_rows(out: Dictionary,
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

func catalog_view(country_catalog: Dictionary = {},
		economy_catalog: Dictionary = {}) -> Dictionary:
	var compiled := compile_native_catalog(country_catalog, economy_catalog)
	if not bool(compiled.get("ok", false)): return compiled
	var rows: Array[Dictionary] = []
	for i in compiled.ideology_ids.size():
		var definition = null
		for candidate in definitions:
			if candidate != null and String(candidate.id) == String(compiled.ideology_ids[i]):
				definition = candidate
				break
		if definition == null:
			continue
		var level_thresholds := PackedInt64Array()
		for level in definition.levels:
			level_thresholds.append(level.understanding_threshold_q16)
		rows.append({"id": String(definition.id), "dense_id": i, "icon_key": String(definition.icon_key),
			"name_key": String(definition.name_key),
			"display_name": _display_name(definition),
			"detail_key": String(definition.detail_key),
			"rarity_weight": definition.rarity_weight, "ideology_slot_cost": definition.ideology_slot_cost,
			"national_spirit_slot_cost": definition.national_spirit_slot_cost,
			"acquisition_flags": definition.acquisition_flags,
			"min_spirit_level": definition.national_spirit_min_level,
			"level_thresholds_q16": level_thresholds,
			"adopt_threshold_q16": definition.adopt_threshold_q16,
			"repeal_threshold_q16": definition.repeal_threshold_q16,
			"promote_threshold_q16": definition.promote_threshold_q16,
			"exclusion_group": String(definition.exclusion_group)})
	var synergy_rows: Array[Dictionary] = []
	for i in compiled.synergy_ids.size():
		synergy_rows.append({
			"dense_id": i,
			"id": String(compiled.synergy_ids[i]),
		})
	return {"ok": true, "ideologies": rows, "synergies": synergy_rows,
		"political_class_ids": compiled.political_class_ids,
		"gate_keys": compiled.gate_keys}


func _display_name(definition) -> String:
	var name_key := String(definition.name_key)
	if not name_key.is_empty() and not name_key.contains("."):
		return name_key
	return String(definition.id)
