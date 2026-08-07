class_name IdeologyCatalog
extends Resource

const DEFAULT_PATH := "res://data/ideologies/default_ideology_catalog.tres"
const IdeologyDefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const IdeologyRequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")
const IdeologyProfileScript = preload("res://scripts/ideology/ideology_profile.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")

const PROTOCOL_VERSION := 1

@export var profile: Resource
@export var definitions: Array[Resource] = []

static func load_default() -> Resource:
	var loaded := ResourceLoader.load(DEFAULT_PATH, "Resource")
	return loaded

func compile_native_catalog(country_catalog: Dictionary) -> Dictionary:
	var effective_profile = profile if profile != null else IdeologyProfileScript.new()
	if not effective_profile is IdeologyProfileScript:
		return {"ok": false, "reason": "ideology_profile_invalid"}
	var technology_ids: PackedStringArray = country_catalog.get("technology_ids", PackedStringArray())
	var signal_ids: PackedStringArray = country_catalog.get("research_signal_ids", PackedStringArray())
	var technology_index := {}
	var signal_index := {}
	for i in technology_ids.size(): technology_index[String(technology_ids[i])] = i
	for i in signal_ids.size(): signal_index[String(signal_ids[i])] = i
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
	var out := {
		"protocol_version": PROTOCOL_VERSION,
		"ideology_capacity": effective_profile.ideology_capacity,
		"national_spirit_capacity": effective_profile.national_spirit_capacity,
		"offer_choice_count": effective_profile.offer_choice_count,
		"offer_cost_q16": effective_profile.offer_cost_q16,
		"max_commands_per_slice": effective_profile.max_commands_per_slice,
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

func catalog_view(country_catalog: Dictionary = {}) -> Dictionary:
	var compiled := compile_native_catalog(country_catalog)
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
		rows.append({"id": String(definition.id), "dense_id": i, "icon_key": String(definition.icon_key),
			"name_key": String(definition.name_key), "detail_key": String(definition.detail_key),
			"rarity_weight": definition.rarity_weight, "ideology_slot_cost": definition.ideology_slot_cost,
			"national_spirit_slot_cost": definition.national_spirit_slot_cost,
			"acquisition_flags": definition.acquisition_flags})
	return {"ok": true, "ideologies": rows, "gate_keys": compiled.gate_keys}
